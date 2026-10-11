require_relative 'test_helper'

class BingoTest < Minitest::Test
  include Rack::Test::Methods

  # Minimal well-formed JPEG: SOI, start-of-scan, data, EOI.
  JPEG = ("\xFF\xD8\xFF\xDA".b + [8].pack('n') + "\1\2\3\4\5\6data\xFF\xD9".b).freeze

  def app = BingoWeb

  def setup
    skip 'TEST_DATABASE_URL not set' unless TestDb.available?
    DB.connection[:bingo_incidents].delete
    DB.connection[:bingo_datacenters].delete
    @dcs = (1..25).map do |n|
      Bingo::Datacenter.create(slug: "dc-#{n}", position: n, name_ru: "ЦОД #{n}", name_en: ("DC #{n}" if n == 1),
                               city_ru: 'Москва', city_en: 'Moscow', operator: 'Op', mw: n.to_s)
    end
  end

  def hit!(idx, kind: 'outage')
    Bingo::Incident.create(datacenter_id: @dcs[idx].id, occurred_on: Date.today, kind: kind,
                           title_ru: "Авария #{idx}", title_uk: "Аварія #{idx}")
  end

  def test_root_redirects_by_accept_language
    get '/', {}, 'HTTP_ACCEPT_LANGUAGE' => 'uk-UA,uk;q=0.9,en;q=0.8'
    assert_equal 302, last_response.status
    assert_match %r{/uk\z}, last_response.location
    get '/', {}, 'HTTP_ACCEPT_LANGUAGE' => 'de-DE'
    assert_match %r{/en\z}, last_response.location
  end

  def test_locales_render_with_ru_fallback
    get '/en'
    assert last_response.ok?
    assert_includes last_response.body, 'DC 1'     # localized
    assert_includes last_response.body, 'ЦОД 2'    # falls back to ru
    assert_includes last_response.body, 'Moscow'
    get '/uk'
    assert_includes last_response.body, 'Бінго'
    assert_includes last_response.body, '<a href="https://asxp.io">asxp.io</a>'
    get '/xx'
    assert_equal 404, last_response.status
  end

  def test_board_detects_lines
    (0..4).each { |i| hit!(i) }     # top row
    [6, 12, 18, 24].each { |i| hit!(i) } # + main diagonal (0 already hit)
    board = Bingo::Board.load
    assert_equal 2, board.wins.size
    get '/ru'
    assert_includes last_response.body, 'БИНГО ×2!'
    assert_includes last_response.body, 'Авария 24'
    get '/uk'
    assert_includes last_response.body, 'Аварія 24'
  end

  def test_no_banner_without_line
    hit!(0)
    get '/ru'
    refute_includes last_response.body, 'class="banner"'
    assert_includes last_response.body, 'Авария 0'
  end

  def test_operational_view_skips_construction_projects
    @dcs[0].update(status: 'building')
    Bingo::Datacenter.create(slug: 'dc-26', position: 26, name_ru: 'ЦОД 26', city_ru: 'Москва', operator: 'Op', mw: '1')
    all = Bingo::Board.load
    op  = Bingo::Board.load('operational')
    assert_includes all.cells.map(&:slug), 'dc-1'
    refute_includes op.cells.map(&:slug), 'dc-1'
    assert_equal 'dc-26', op.cells.last.slug          # reserve moves up to fill the card
    assert_equal 25, op.cells.size
  end

  def test_operational_view_recomputes_lines
    (1..4).each { |i| hit!(i) }                       # row 1 minus dc-1
    @dcs[0].update(status: 'building')
    Bingo::Datacenter.create(slug: 'dc-26', position: 26, name_ru: 'ЦОД 26', city_ru: 'Москва', operator: 'Op')
    assert_equal 0, Bingo::Board.load.wins.size        # dc-1 not hit
    hit!(5)                                           # dc-6 now sits at index 4 in operational view
    assert_equal 1, Bingo::Board.load('operational').wins.size
  end

  def test_default_view_is_operational_and_all_is_a_noindex_variant
    @dcs[0].update(status: 'building')
    get '/ru'
    assert last_response.ok?
    refute_includes last_response.body, 'ЦОД 1<'                     # construction project hidden by default
    assert_includes last_response.body, 'index, follow, max-image-preview'
    assert_includes last_response.body, '<a href="/ru" aria-current="page">'
    get '/ru?view=all'
    assert last_response.ok?
    assert_includes last_response.body, 'ЦОД 1<'
    assert_includes last_response.body, 'noindex, follow'
    assert_includes last_response.body, 'href="/en?view=all"'         # language links keep the view
    assert_includes last_response.body, '<a href="/ru?view=all" aria-current="page">'
    assert_includes last_response.body, 'rel="canonical" href="https://example.org/ru"'
    get '/ru?view=operational'                                        # old links still land on the default
    assert_includes last_response.body, 'index, follow, max-image-preview'
  end

  def test_capacity_type_and_planned_status
    @dcs[0].update(mw: '64', mw_type: 'design', status: 'planned')
    @dcs[1].update(mw: '17', mw_type: 'mva')
    get '/en?view=all'                                # planned sites only appear in the full list
    body = last_response.body
    assert_includes body, '64 MW · design'           # dialog
    assert_includes body, '#1 · 64 MW</div>'         # cell: no tag
    assert_includes body, '17 MVA'
    assert_includes body, '#2 · 17 MVA</div>'       # MVA replaces the unit in cells too
    assert_includes body, '>planned<'
    refute_includes Bingo::Board.load('operational').cells.map(&:slug), 'dc-1'
  end

  def test_provider_filter_keeps_a_5x5_card
    @dcs.first(3).each { |d| d.update(provider: 'yandex') }
    @dcs[3].update(provider: 'rtk')
    hit!(0)
    board = Bingo::Board.load('operational', providers: %w[yandex rtk])
    assert_equal %w[dc-1 dc-2 dc-3 dc-4], board.cells.map(&:slug)
    get '/ru?p[]=yandex&p[]=rtk&p[]=bogus'
    assert last_response.ok?
    body = last_response.body
    assert_equal 4, body.scan(/class="cell(?! empty)[ "]/).size       # the four selected datacenters
    assert_equal 21, body.scan('class="cell empty"').size
    assert_includes body, 'noindex, follow'
    assert_includes body, 'rel="canonical" href="https://example.org/ru"'
    assert_includes body, 'href="/en?p[]=yandex&amp;p[]=rtk"'           # language links keep the selection
    assert_includes body, 'name="p[]" value="yandex" checked'
    refute_includes body, 'ЦОД 5<'                                    # unselected provider
    get '/ru?p=yandex,rtk'                                            # comma form works too
    assert_equal 21, last_response.body.scan('class="cell empty"').size
  end

  def test_filtered_card_still_scores_lines
    @dcs.first(5).each { |d| d.update(provider: 'ixcellerate') }
    (0..4).each { |i| hit!(i) }
    assert_equal 1, Bingo::Board.load('operational', providers: ['ixcellerate']).wins.size
  end

  def test_footer_credits_in_every_language
    { 'ru' => 'с помощью Claude', 'en' => 'with the help of Claude', 'uk' => 'за допомогою Claude' }.each do |l, text|
      get "/#{l}"
      assert_includes last_response.body, text
      assert_includes last_response.body, '<a href="https://hackyourmom.com/en/karta-data-czentriv-na-rasii/" target="_blank" rel="noopener">hackyourmom</a>'
    end
    get "/en/dc/#{@dcs[0].slug}"
    assert_includes last_response.body, 'hackyourmom</a>'
  end

  def test_robots_and_sitemap_are_the_bingos_own
    get '/robots.txt'
    assert last_response.ok?
    assert_includes last_response.body, 'Sitemap: https://example.org/sitemap.xml'
    refute_includes last_response.body, 'asxp.io'
    get '/sitemap.xml'
    assert last_response.ok?
    %w[ru en uk].each { |l| assert_includes last_response.body, "<loc>https://example.org/#{l}</loc>" }
    %w[ru en uk].each { |l| assert_includes last_response.body, "<loc>https://example.org/#{l}/dc/dc-25</loc>" }
    assert_includes last_response.body, '<xhtml:link rel="alternate" hreflang="uk" href="https://example.org/uk/dc/dc-7"/>'
    assert_equal 3, last_response.body.scan('hreflang="x-default"').size # card URLs only
    assert_includes last_response.body, 'hreflang="x-default"'
    refute_includes last_response.body, 'changefreq'
    assert_match %r{</loc>\n    <lastmod>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ</lastmod>\n    <xhtml:link}, last_response.body
  end

  def test_trailing_slash_redirects
    get '/en/', view: 'all'
    assert_equal 301, last_response.status
    assert_equal 'http://example.org/en?view=all', last_response.location
  end

  def test_icons
    { '/favicon.svg' => 'image/svg+xml', '/favicon.ico' => 'image/x-icon',
      '/apple-touch-icon.png' => 'image/png' }.each do |path, type|
      get path
      assert last_response.ok?, path
      assert_equal type, last_response.content_type
    end
    get '/en'
    assert_includes last_response.body, '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
  end

  def test_hsts
    get '/en'
    assert_equal 'max-age=31536000', last_response.headers['strict-transport-security']
    assert_equal 'nosniff', last_response.headers['x-content-type-options']
  end

  def test_dc_page
    hit!(3)
    get '/en/dc/dc-4'
    assert last_response.ok?
    body = last_response.body
    assert_includes body, "<title>ЦОД 4 (Moscow) — Outage, #{Date.today.strftime('%d.%m.%Y')} | Datacenter Bingo</title>"
    assert_includes body, '<link rel="canonical" href="https://example.org/en/dc/dc-4">'
    assert_includes body, '<link rel="alternate" hreflang="uk" href="https://example.org/uk/dc/dc-4">'
    refute_includes body, 'x-default'
    assert_includes body, '<h1>ЦОД 4</h1>'
    assert_includes body, 'ЦОД 4 is a datacenter in Moscow operated by Op. Capacity: 4 MW.'
    assert_includes body, 'No. 4 by power'
    assert_includes body, 'href="/en/dc/dc-3" rel="prev"'
    assert_includes body, 'href="/en/dc/dc-5" rel="next"'
    assert_match(/<meta name="description" content="[^"]*Latest reported incident/, body)
    ld = JSON.parse(body[%r{<script type="application/ld\+json">(.*?)</script>}m, 1])
    place = ld['@graph'].find { |n| n['@type'] == 'Place' }
    assert_equal 'https://example.org/en/dc/dc-4', place['url']
    assert_equal 'Outage: Авария 3', place['event'][0]['name']
    crumbs = ld['@graph'].find { |n| n['@type'] == 'BreadcrumbList' }
    assert_equal 'https://example.org/en', crumbs['itemListElement'][0]['item']

    @dcs[3].update(mw_type: 'design')
    get '/en/dc/dc-4'
    assert_includes last_response.body, 'Capacity: 4 MW (design).'
    get '/uk/dc/dc-1'
    assert_includes last_response.body, '<title>ЦОД 1 (Москва) — інциденти ЦОДу | Бінго ЦОДів</title>'
    refute_includes last_response.body, 'rel="prev"'
  end

  def test_reserve_dc_has_a_page
    Bingo::Datacenter.create(slug: 'dc-26', position: 26, name_ru: 'ЦОД 26', city_ru: 'Тверь', operator: 'Op')
    get '/ru/dc/dc-26'
    assert last_response.ok?
    assert_includes last_response.body, 'href="/ru/dc/dc-25" rel="prev"'
    get '/sitemap.xml'
    assert_includes last_response.body, '<loc>https://example.org/ru/dc/dc-26</loc>'
  end

  def test_dc_page_unknown_and_trailing_slash
    get '/en/dc/nope'
    assert_equal 404, last_response.status
    get '/en/dc/dc-1/'
    assert_equal 301, last_response.status
    assert_equal 'http://example.org/en/dc/dc-1', last_response.location
  end

  def test_card_links_to_dc_pages
    hit!(0)
    get '/en'
    body = last_response.body
    assert_includes body, '<a href="/en/dc/dc-1" data-dlg="dlg-dc-1"'
    assert_includes body, '<a href="/en/dc/dc-2">Datacenter page →</a>'
    assert_includes body, '<div class="dc"><a href="/en/dc/dc-1">DC 1</a>'
  end

  def with_env(vars)
    old = vars.to_h { |k, _| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def test_indexnow_key_file
    get '/0123456789abcdef.txt'
    assert_equal 404, last_response.status
    with_env('INDEXNOW_KEY' => '0123456789abcdef') do
      get '/0123456789abcdef.txt'
      assert last_response.ok?
      assert_equal '0123456789abcdef', last_response.body
      get '/fedcba9876543210.txt'
      assert_equal 404, last_response.status
    end
  end

  def test_root_varies_on_language
    get '/'
    assert_equal 'Accept-Language', last_response.headers['Vary']
  end

  def test_seo_head
    hit!(3)
    @dcs[3].update(photo_key: 'bingo/dc-4-0123abcd.jpg', photo_variants: true)
    @dcs[0].update(info_url: 'https://example.com/dc-1')
    get '/en'
    body = last_response.body
    assert_includes body, '<title>Datacenter Bingo — strikes'
    assert_match %r{<h1>Datacenter <span>Bingo</span> <small>Drone strikes, fires and outages at Russia&#39;s 25 largest datacenters</small></h1>}, body
    assert_includes body, '1 of Russia&#39;s 25 largest'
    assert_includes body, '<meta property="og:image" content="https://example.org/p/dc-4-0123abcd-1200.webp">'
    assert_includes body, 'src="/p/dc-4-0123abcd-480.webp"'
    refute_includes body, 'og:image:width'
    @dcs[3].update(photo_og: true)
    get '/en'
    body = last_response.body
    assert_includes body, '<meta property="og:image" content="https://example.org/p/dc-4-0123abcd-og.jpg">'
    assert_includes body, '<meta property="og:image:width" content="1200">'
    assert_includes body, '<meta property="og:image:alt" content="ЦОД 4, Moscow">'
    assert_includes body, 'og:locale:alternate" content="uk_UA"'
    ld = JSON.parse(body[%r{<script type="application/ld\+json">(.*?)</script>}m, 1])
    list = ld['@graph'].find { |n| n['@type'] == 'ItemList' }
    assert_equal 25, list['itemListElement'].size
    assert_equal 'DC 1', list['itemListElement'][0]['item']['name']
    hit = list['itemListElement'][3]['item']
    assert_equal Date.today.iso8601, hit['event'][0]['startDate']
    assert_equal 'Outage: Авария 3', hit['event'][0]['name']
    refute list['itemListElement'][0]['item'].key?('event')
    assert_equal({ '@type' => 'CreativeWork', 'url' => 'https://example.com/dc-1' }, list['itemListElement'][0]['item']['subjectOf'])
    refute_includes body, 'sameAs'
    assert list['dateModified']
  end

  def test_photo_falls_back_to_original_without_variants
    @dcs[0].update(photo_key: 'bingo/dc-1-0123abcd.jpg', photo_variants: false)
    assert_equal 'dc-1-0123abcd.jpg', @dcs[0].photo_file(480)
    @dcs[0].update(photo_variants: true)
    assert_equal 'dc-1-0123abcd-480.webp', @dcs[0].photo_file(480)
    assert_equal 'dc-1-0123abcd.jpg', @dcs[0].photo_file
  end

  def test_photo_served_from_bucket
    Aws.config[:s3] = { stub_responses: { get_object: { body: JPEG } } }
    S3.instance_variable_set(:@client, nil)
    @dcs[0].update(photo_key: 'bingo/dc-1-0123abcd.jpg')
    get "/p/#{@dcs[0].photo_file}"
    assert last_response.ok?
    assert_equal 'image/jpeg', last_response.content_type
    assert_includes last_response.headers['cache-control'], 'immutable'
    get '/p/..%2Finvoices%2Fx.pdf'
    assert_equal 404, last_response.status
  ensure
    Aws.config[:s3] = { stub_responses: true }
    S3.instance_variable_set(:@client, nil)
  end

  def test_dc_about_text
    @dcs[1].update(about_en: "First <b>para</b>.\r\n\r\nSecond.")
    get '/en/dc/dc-2'
    assert_includes last_response.body, '<p class="facts">First &lt;b&gt;para&lt;/b&gt;.</p><p class="facts">Second.</p>'
    get '/ru/dc/dc-2'
    refute_includes last_response.body, 'Second.' # no fallback across languages
  end

  def test_static_files_not_served
    get '/style.css'
    assert_equal 404, last_response.status
  end

  def test_healthz
    get '/healthz'
    assert last_response.ok?
    assert_equal 'ok', last_response.body
  end

  def test_www_redirects_to_canonical_host
    ENV['BINGO_HOST'] = 'bingo.example'
    app = Rack::Builder.parse_file(File.join(__dir__, '..', 'config.ru'))
    res = Rack::MockRequest.new(app).get('http://www.bingo.example/en?view=all')
    assert_equal 301, res.status
    assert_equal 'https://bingo.example/en?view=all', res.location
  ensure
    ENV.delete('BINGO_HOST')
  end
end
