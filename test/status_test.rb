require_relative 'test_helper'

class StatusTest < Minitest::Test
  include Rack::Test::Methods

  def app = BingoWeb

  NOW = Time.utc(2026, 10, 18, 12, 2)
  B   = Time.utc(2026, 10, 18, 12, 0) # newest bucket at NOW

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    @db = DB.connection
    %i[bingo_monitor_buckets bingo_monitor_samples bingo_monitor_targets bingo_incidents bingo_datacenters].each { |t| @db[t].delete }
    @up, @down, @part, @none = %w[up down part none].each_with_index.map do |s, i|
      Bingo::Datacenter.create(slug: "dc-#{s}", position: i + 1, name_ru: "ЦОД #{s}", city_ru: 'Москва',
                               operator: 'Op', status: 'operational')
    end
    [@up, @down, @part].each { |dc| @db[:bingo_monitor_targets].insert(datacenter_id: dc.id, host: "h-#{dc.slug}", port: 443, created_at: B) }
    @db[:bingo_monitor_targets].insert(datacenter_id: nil, host: 'ctl', port: 80, created_at: B)
  end

  def bucket(at, control_ok: 4, control_checks: 4)
    @db[:bingo_monitor_buckets].insert(bucket_at: at, rounds: 5, control_checks: control_checks, control_ok: control_ok)
  end

  def sample(dc, at, ok, checks = 5)
    @db[:bingo_monitor_samples].insert(datacenter_id: dc.id, bucket_at: at, checks: checks, ok: ok, rtt_ms_sum: ok * 40)
  end

  def two_buckets(base = B, **controls)
    [base - 300, base].each do |at|
      bucket(at, **controls)
      sample(@up, at, 5)
      sample(@down, at, 0)
      sample(@part, at, 2)
    end
  end

  def states(report) = report.sites.to_h { |s| [s.dc.slug, s.state] }

  def test_states_from_newest_buckets
    two_buckets
    r = Bingo::Status.load(NOW)
    assert_equal({ 'dc-up' => 'up', 'dc-down' => 'down', 'dc-part' => 'degraded' }, states(r))
    assert_equal ['dc-none'], r.unmonitored.map(&:slug)
    assert_equal 40, r.sites.first.rtt_ms
    assert_equal 'ok', r.state
  end

  def test_one_dark_bucket_after_a_good_one_is_not_yet_down
    bucket(B - 300); sample(@down, B - 300, 5)
    bucket(B);       sample(@down, B, 0)
    assert_equal 'degraded', states(Bingo::Status.load(NOW))['dc-down']
  end

  def test_lost_vantage_makes_everything_unknown
    two_buckets(control_ok: 1, control_checks: 4)
    r = Bingo::Status.load(NOW)
    assert_equal %w[unknown], states(r).values.uniq
    assert_equal 'vantage', r.state
    assert_nil r.sites.first.history.last, 'untrusted hour shows no data'
  end

  def test_stale_worker_makes_everything_unknown
    two_buckets
    r = Bingo::Status.load(NOW + 3600)
    assert_equal %w[unknown], states(r).values.uniq
    assert_equal 'stale', r.state
  end

  def test_status_page_and_json
    two_buckets(Time.at(Time.now.to_i / 300 * 300).utc) # pages use the real clock
    get '/ru/status'
    assert last_response.ok?
    assert_includes last_response.body, 'не отвечает'
    assert_includes last_response.body, 'ЦОД none' # unmonitored list
    get '/status.json'
    data = JSON.parse(last_response.body)
    assert_equal %w[dc-up dc-down dc-part], data['datacenters'].map { |d| d['slug'] }
    assert_equal ['dc-none'], data['unmonitored']
    get '/en/dc/dc-up'
    assert_includes last_response.body, 'Network reachability'
    get '/en/dc/dc-none'
    refute_includes last_response.body, 'Network reachability'
  end

  def test_status_page_before_any_round
    get '/en/status'
    assert last_response.ok?
    assert_includes last_response.body, 'No checks yet.'
  end
end
