require 'logger'
require 'json'
require 'sinatra/base'
require 'erubi'

begin
  require 'dotenv'
  Dotenv.load unless ENV['RACK_ENV'] == 'test'
rescue LoadError
end

$root   = __dir__
$logger = Logger.new($stdout)
$env    = ENV.fetch('RACK_ENV', 'development')

require_relative 'lib/db'
if ENV['DATABASE_URL']
  DB.connect!
  require_relative 'lib/bingo'
else
  $logger.warn('DATABASE_URL not set — every page answers 503')
end

# Public datacenter bingo on BINGO_HOST. Read-only: no session, no CSRF.
# Content is managed from asxp.io/admin/bingo (asxpio repo), which shares the
# database and photo bucket.
class BingoWeb < Sinatra::Base
  SOURCE_URL = 'https://github.com/asxpi/datacenterbingo'.freeze
  LICENSE_URL = 'https://creativecommons.org/licenses/by/4.0/'.freeze
  FEED_SIZE = 50
  HOSTS = [ENV['BINGO_HOST'], ENV['BINGO_ALT_HOST']].compact.reject(&:empty?).freeze

  configure do
    set :root, $root
    set :erb, layout: :layout, escape_html: true
    set :static, false # icons have explicit routes below
    set :show_exceptions, $env == 'development'
    # HSTS (1 year, this host only); http:// already 308s at the edge.
    set :protection, use: %i[strict_transport]
    set :host_authorization,
        { permitted_hosts: $env == 'production' ? [*HOSTS, '127.0.0.1'] : [] } # 127.0.0.1: HEALTHCHECK
  end

  helpers do
    def t(key) = Bingo::T[@locale][key]
    def kind_label(kind) = Bingo::T[@locale][:kinds][kind] || Bingo::T[@locale][:kinds]['other']
    def kind_icon(kind) = Bingo::ICONS[kind] || Bingo::ICONS['other']
    def photo_path(dc, width = nil) = dc.photo_file(width) && "/p/#{dc.photo_file(width)}"
    # Path for a locale/view combination; the default view (operational)
    # keeps a bare URL, the full list is ?view=all.
    # Path for a locale/view/provider selection; the default (operational,
    # every provider) keeps a bare URL.
    def card_path(locale = @locale, view = @view, providers = @providers)
      q = []
      q << 'view=all' if view == 'all'
      Array(providers).each { |p| q << "p[]=#{Rack::Utils.escape(p)}" }
      q.empty? ? "/#{locale}" : "/#{locale}?#{q.join('&')}"
    end

    def selected_providers
      Array(params[:p]).flat_map { |v| v.to_s.split(',') }.select { |p| Bingo::PROVIDERS.key?(p) }.uniq
    end

    def dc_path(dc, locale = @locale) = "/#{locale}/dc/#{dc.slug}"

    def base_url = "https://#{ENV.fetch('BINGO_HOST', request.host)}"

    # WebSite + ItemList of the card's datacenters, for rich results.
    def json_ld(board, desc)
      url = "#{base_url}/#{@locale}"
      JSON.generate(
        '@context' => 'https://schema.org',
        '@graph' => [
          { '@type' => 'WebSite', '@id' => "#{base_url}/#website", 'url' => "#{base_url}/",
            'name' => t(:title), 'inLanguage' => Bingo::LOCALES,
            'publisher' => { '@type' => 'Person', 'name' => 'asxpi', 'url' => 'https://asxp.io' } },
          { '@type' => 'ItemList', 'url' => url, 'name' => t(:seo_title), 'description' => desc,
            'inLanguage' => @locale, 'numberOfItems' => board.cells.size,
            'dateModified' => board.updated_on&.utc&.iso8601,
            'itemListElement' => board.cells.each_with_index.map do |dc, i|
              { '@type' => 'ListItem', 'position' => i + 1, 'item' => ld_place(dc) }
            end }.compact
        ]
      ).gsub('</', '<\/')
    end

    # The info_url describes the datacenter (operator page, news), it isn't
    # the datacenter's own identity, so subjectOf rather than sameAs.
    # Incidents are Events at the place.
    def ld_place(dc)
      address = { '@type' => 'PostalAddress', 'addressLocality' => dc.l(:city, @locale), 'addressCountry' => 'RU' }
      url = "#{base_url}#{dc_path(dc)}"
      place = { '@type' => 'Place', '@id' => "#{url}#place", 'url' => url, 'name' => dc.l(:name, @locale), 'address' => address }
      place['image'] = "#{base_url}#{photo_path(dc, 1200)}" if dc.photo_key
      place['subjectOf'] = { '@type' => 'CreativeWork', 'url' => dc.info_url } if dc.info_url
      events = dc.incidents.map do |i|
        { '@type' => 'Event', 'name' => "#{kind_label(i.kind)}: #{i.l(:title, @locale)}",
          'startDate' => i.occurred_on.iso8601, 'url' => i.url,
          'location' => { '@type' => 'Place', 'name' => place['name'], 'address' => address } }.compact
      end
      place['event'] = events if events.any?
      place
    end

    # Datacenter page: the Place plus a breadcrumb back to the card.
    def dc_json_ld(dc)
      JSON.generate(
        '@context' => 'https://schema.org',
        '@graph' => [
          ld_place(dc),
          { '@type' => 'BreadcrumbList', 'itemListElement' => [
            { '@type' => 'ListItem', 'position' => 1, 'name' => t(:title), 'item' => "#{base_url}/#{@locale}" },
            { '@type' => 'ListItem', 'position' => 2, 'name' => dc.l(:name, @locale), 'item' => "#{base_url}#{dc_path(dc)}" }
          ] }
        ]
      ).gsub('</', '<\/')
    end

    # Plain-language facts for the datacenter page and its meta description.
    def dc_facts(dc)
      [format(t(:dc_intro), name: dc.l(:name, @locale), city: dc.l(:city, @locale), operator: dc.operator),
       (format(t(:dc_capacity), mw: mw_prose(dc)) if mw(dc)),
       { 'building' => t(:dc_building), 'planned' => t(:dc_planned) }[dc.status] || (dc.year && format(t(:dc_since), dc.year)),
       (format(t(:dc_rank), pos: op_rank(dc)) if op_rank(dc))].compact
    end

    def dc_latest(dc)
      i = dc.incidents.first or return t(:no_incidents)
      format(t(:dc_latest), date: fmt_date(i.occurred_on), title: i.l(:title, @locale))
    end

    # Cut at a word boundary to fit a search snippet.
    def snippet(text, max = 160)
      text.length <= max ? text : "#{text[0, max - 1][/\A.*(?=\s)/m] || text[0, max - 1]}…"
    end

    # Preview image: the most recent hit with a photo, else the first photo.
    def og_dc(board)
      board.incidents.map(&:datacenter).find(&:photo_key) || board.cells.find(&:photo_key)
    end
    def fmt_date(d) = d.strftime('%d.%m.%Y')

    # "64 MW", "64 MW · design", "17 MVA" (MVA is a unit, not a tag).
    def mw(dc, tag: true)
      return if dc.mw.to_s.strip.empty?
      return "#{dc.mw} #{t(:mva)}" if dc.mw_type == 'mva'
      tag &&= t(:mw_types)[dc.mw_type]
      ["#{dc.mw} #{t(:mw)}", tag || nil].compact.join(' · ')
    end

    # "63 MW (design)": the dialog's " · design" tag reads badly in a sentence.
    def mw_prose(dc)
      tag = dc.mw_type != 'mva' && t(:mw_types)[dc.mw_type]
      tag ? "#{mw(dc, tag: false)} (#{tag})" : mw(dc)
    end

    # Badge for anything not yet in service.
    def status_label(dc)
      { 'building' => t(:building), 'planned' => t(:planned) }[dc.status]
    end

    # Stable per incident across edits, so readers don't show duplicates.
    def incident_id(i) = "tag:#{ENV.fetch('BINGO_HOST', request.host)},2026:incident-#{i.id}"

    # Feed entry body: what happened, the datacenter facts, the source.
    def incident_html(i)
      h = Rack::Utils.method(:escape_html)
      parts = ["<p>#{h.(i.l(:title, @locale))}</p>", "<p>#{h.(dc_facts(i.datacenter).join(' '))}</p>"]
      parts << %(<p><a href="#{h.(i.url)}">#{h.(t(:source))}</a></p>) if i.url
      parts.join
    end

    def incident_headline(i)
      "#{kind_label(i.kind)}: #{i.datacenter.l(:name, @locale)} — #{i.l(:title, @locale)}"
    end

    def feed_incidents
      Bingo::Incident.order(Sequel.desc(:occurred_on), Sequel.desc(:id)).limit(FEED_SIZE)
                     .eager(datacenter: :incidents).all
    end

    def feed_time(i) = Time.utc(i.occurred_on.year, i.occurred_on.month, i.occurred_on.day)

    # Rank by power among operational datacenters only, the same order as the
    # default card; nil for sites not yet in service.
    def op_rank(dc)
      @op_ranks ||= Bingo::Datacenter.where(status: 'operational').order(:position, :id).select_map(:id)
                                     .each_with_index.to_h { |id, i| [id, i + 1] }
      @op_ranks[dc.id]
    end

    def probe_json(t)
      { host: t[:host], port: t[:port], label: t[:label], source_url: t[:source_url],
        answered: t[:last_ok], rtt_ms: t[:last_rtt_ms] }
    end

    # WebPage + Dataset (status.json), so the page reads as live open data.
    def status_ld(report)
      url = "#{base_url}/#{@locale}/status"
      JSON.generate(
        '@context' => 'https://schema.org',
        '@graph' => [
          { '@type' => 'WebPage', '@id' => url, 'url' => url, 'name' => t(:status_title), 'description' => @desc,
            'inLanguage' => @locale, 'dateModified' => report&.checked_at&.utc&.iso8601,
            'isPartOf' => { '@id' => "#{base_url}/#website" },
            'breadcrumb' => { '@type' => 'BreadcrumbList', 'itemListElement' => [
              { '@type' => 'ListItem', 'position' => 1, 'name' => t(:title), 'item' => "#{base_url}/#{@locale}" },
              { '@type' => 'ListItem', 'position' => 2, 'name' => t(:status_link), 'item' => url }
            ] } }.compact,
          { '@type' => 'Dataset', 'name' => t(:status_link), 'description' => t(:status_lead), 'url' => url,
            'license' => LICENSE_URL, 'isAccessibleForFree' => true, 'temporalCoverage' => 'P1D',
            'creator' => { '@type' => 'Person', 'name' => 'asxpi', 'url' => 'https://asxp.io' },
            'distribution' => [{ '@type' => 'DataDownload', 'encodingFormat' => 'application/json',
                                 'contentUrl' => "#{base_url}/status.json" }] }
        ]
      ).gsub('</', '<\/')
    end

    # Bar colour for an answered share (nil = no data).
    def avail_class(a)
      return '' if a.nil?
      a >= 0.8 ? 'up' : (a.zero? ? 'down' : 'degraded')
    end

    def status_report(only: nil) = Bingo::Status.available? ? Bingo::Status.load(only: only) : nil

    def status_json(report)
      { checked_at: report&.checked_at&.utc&.iso8601, monitor: report&.state,
        controls: report&.controls && { ok: report.controls[0], checked: report.controls[1] },
        datacenters: (report&.sites || []).map do |s|
          { slug: s.dc.slug, rank: s.dc.position, operational_rank: op_rank(s.dc), state: s.state,
            availability: s.availability&.round(3), rtt_ms: s.rtt_ms, hourly: s.history.map { |a| a&.round(3) },
            targets: s.targets.map { |t| probe_json(t) } }
        end,
        control_hosts: (report&.control_hosts || []).map { |t| probe_json(t) },
        unmonitored: (report&.unmonitored || []).map(&:slug) }
    end

    def preferred_locale
      langs = request.env['HTTP_ACCEPT_LANGUAGE'].to_s.downcase.scan(/([a-z]{2})(?:-[a-z]+)?(?:;q=([\d.]+))?/)
      langs.sort_by { |_, q| -(q || '1').to_f }.map(&:first).find { |l| Bingo::LOCALES.include?(l) } || 'en'
    end
  end

  get '/healthz' do
    halt 503, 'no database' unless defined?(Bingo::Datacenter)
    DB.connection.test_connection
    'ok'
  end

  before do
    halt 503, 'Bingo not configured (DATABASE_URL missing).' unless defined?(Bingo::Datacenter)
  end

  get '/' do
    headers 'Vary' => 'Accept-Language'
    redirect "/#{preferred_locale}", 302
  end

  get '/robots.txt' do
    content_type 'text/plain'
    "User-agent: *\nAllow: /\n\nSitemap: #{base_url}/sitemap.xml\n"
  end

  # The card and every datacenter page (reserve included), each with its
  # language alternates.
  get '/sitemap.xml' do
    content_type 'application/xml'
    cache_control :public, max_age: 3600
    dcs = Bingo::Datacenter.order(:position, :id).eager(:incidents).all
    @entries = [[->(l) { "/#{l}" }, Bingo::Board.load.updated_on, '/'],
                [->(l) { "/#{l}/status" }, nil, '/en/status']] +
               dcs.map { |dc| [->(l) { dc_path(dc, l) }, [dc.updated_at, *dc.incidents.map(&:updated_at)].compact.max] }
    erb :sitemap, layout: false
  end

  # One URL per page: /en/ is a duplicate of /en.
  get %r{/((?:ru|en|uk)(?:/dc/[a-z0-9-]+)?)/} do |path|
    qs = request.query_string
    redirect "/#{path}#{"?#{qs}" unless qs.empty?}", 301
  end

  get %r{/(ru|en|uk)} do |locale|
    @locale = locale
    @view   = params[:view] == 'all' ? 'all' : Bingo::VIEWS.first
    @providers = selected_providers
    @board  = Bingo::Board.load(@view, providers: @providers)
    @title  = t(:seo_title)
    @desc   = format(t(:seo_desc), hit: @board.hit.count(true), total: @board.cells.size)
    @noindex = !@board.operational_only? || @board.filtered? # variants of the bare page
    @path_for = ->(l) { "/#{l}" }
    @x_default = '/'
    @og = og_dc(@board)
    @ld = json_ld(@board, @desc)
    cache_control :public, max_age: 60
    erb :index
  end

  get %r{/(ru|en|uk)/dc/([a-z0-9-]+)} do |locale, slug|
    @locale = locale
    @dc = Bingo::Datacenter.where(slug: slug).eager(:incidents).first or halt 404
    @prev, @next = [-1, 1].map { |d| Bingo::Datacenter.first(position: @dc.position + d) }
    name, city = @dc.l(:name, locale), @dc.l(:city, locale)
    hit = @dc.incidents.first
    @title = hit ? format(t(:dc_title_hit), name: name, city: city, kind: kind_label(hit.kind), date: fmt_date(hit.occurred_on))
                 : format(t(:dc_title), name: name, city: city)
    @desc = snippet([*dc_facts(@dc).first(2), dc_latest(@dc)].join(' '))
    @path_for = ->(l) { dc_path(@dc, l) }
    @og = @dc if @dc.photo_key
    @ld = dc_json_ld(@dc)
    @status = status_report(only: @dc.id)&.sites&.first
    cache_control :public, max_age: 60
    erb :dc
  end

  # Reachability from asxpio's monitor; not incidents (see Bingo::Status).
  get %r{/(ru|en|uk)/status} do |locale|
    @locale = locale
    @report = status_report
    @title = t(:status_title)
    @desc = t(:status_desc)
    @path_for = ->(l) { "/#{l}/status" }
    @x_default = '/en/status'
    @ld = status_ld(@report)
    cache_control :public, max_age: 60
    erb :status
  end

  get '/status.json' do
    content_type 'application/json', charset: 'utf-8'
    headers 'Access-Control-Allow-Origin' => '*'
    cache_control :public, max_age: 60
    JSON.pretty_generate(status_json(status_report))
  end

  # Incident feeds per locale: RSS 2.0 and JSON Feed 1.1, newest first.
  get %r{/(ru|en|uk)/feed\.xml} do |locale|
    @locale = locale
    @incidents = feed_incidents
    content_type 'application/rss+xml', charset: 'utf-8'
    cache_control :public, max_age: 300
    erb :feed_rss, layout: false
  end

  get %r{/(ru|en|uk)/feed\.json} do |locale|
    @locale = locale
    content_type 'application/feed+json', charset: 'utf-8'
    headers 'Access-Control-Allow-Origin' => '*'
    cache_control :public, max_age: 300
    JSON.pretty_generate(
      version: 'https://jsonfeed.org/version/1.1',
      title: format(t(:feed_title), site: t(:title)),
      description: t(:tagline),
      home_page_url: "#{base_url}/#{locale}",
      feed_url: "#{base_url}/#{locale}/feed.json",
      language: locale,
      icon: "#{base_url}/apple-touch-icon.png",
      favicon: "#{base_url}/favicon.ico",
      authors: [{ name: 'asxpi', url: 'https://asxp.io' }],
      items: feed_incidents.map do |i|
        dc = i.datacenter
        { id: incident_id(i), url: "#{base_url}#{dc_path(dc)}", external_url: i.url,
          title: incident_headline(i), content_html: incident_html(i),
          image: (dc.photo_key && "#{base_url}#{photo_path(dc, 1200)}"),
          date_published: feed_time(i).iso8601, date_modified: i.updated_at&.utc&.iso8601,
          tags: [kind_label(i.kind), Bingo.provider_name(dc.provider, locale)].compact.uniq }.compact
      end
    )
  end

  # The whole dataset, every language, for reuse under CC BY 4.0.
  get '/data.json' do
    content_type 'application/json', charset: 'utf-8'
    headers 'Access-Control-Allow-Origin' => '*'
    cache_control :public, max_age: 300
    loc = ->(row, field) { Bingo::LOCALES.to_h { |l| [l, row.l(field, l)] } }
    dcs = Bingo::Datacenter.order(:position, :id).eager(:incidents).all
    JSON.pretty_generate(
      title: 'Datacenter Bingo dataset',
      description: "Russia's largest datacenters with publicly sourced incidents (strikes, fires, outages).",
      home_page_url: "#{base_url}/",
      license: 'CC-BY-4.0',
      license_url: LICENSE_URL,
      attribution: "Datacenter Bingo (#{base_url}/), collected and verified with the help of Claude (Anthropic); " \
                   'part of the list from the hackyourmom datacenter map (data by Cat Eyes OSINT), re-verified.',
      updated_at: Bingo::Board.load.updated_on&.utc&.iso8601,
      datacenters: dcs.map do |dc|
        { slug: dc.slug, rank: dc.position, operational_rank: op_rank(dc), name: loc.(dc, :name), city: loc.(dc, :city),
          operator: dc.operator, provider: dc.provider, status: dc.status,
          mw: dc.mw, mw_value: Bingo.mw_value(dc.mw), mw_type: dc.mw_type, year: dc.year,
          info_url: dc.info_url,
          pages: Bingo::LOCALES.to_h { |l| [l, "#{base_url}#{dc_path(dc, l)}"] },
          photo: dc.photo_key && { url: "#{base_url}#{photo_path(dc, 1200)}", credit: dc.photo_credit,
                                   source_url: dc.photo_source_url },
          incidents: dc.incidents.map do |i|
            { date: i.occurred_on.iso8601, kind: i.kind, title: loc.(i, :title), source_url: i.url }
          end }
      end
    )
  end

  # IndexNow key file: proves to the engines that pings come from us.
  get %r{/([A-Za-z0-9-]{8,128})\.txt} do |name|
    halt 404 unless name == Bingo::IndexNow.key
    content_type 'text/plain'
    name
  end

  # Icons from assets/. Search engines want
  # a crawlable favicon URL; a data: URI doesn't count.
  ICONS = { 'favicon.svg' => 'image/svg+xml', 'favicon.ico' => 'image/x-icon',
            'apple-touch-icon.png' => 'image/png' }.freeze

  get %r{/(favicon\.svg|favicon\.ico|apple-touch-icon\.png)} do |name|
    cache_control :public, max_age: 86_400
    send_file File.join(settings.root, 'assets', name), type: ICONS[name]
  end

  # Photos are immutable per key (a new upload gets a new key).
  get '/p/:file' do
    bytes, type = Bingo::Photo.read(params[:file])
    content_type type
    cache_control :public, :immutable, max_age: 31_536_000
    bytes
  rescue Bingo::Photo::Error, Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
    halt 404
  end

  not_found do
    'Not found'
  end
end
