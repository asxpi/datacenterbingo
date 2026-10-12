require 'sequel'
require 'json'
require_relative 's3'

# Datacenter bingo: a 5x5 card of the largest Russian datacenters; a cell is
# crossed out once a publicly sourced incident is recorded for it.
#
# Read side only. The tables live in the asxpio database and are written by
# the asxp.io admin (asxpio repo: lib/bingo.rb, lib/bingo_admin.rb, which also
# owns the migrations). Keep the models and Board here in step with it.
module Bingo
  LOCALES = %w[ru en uk].freeze
  KINDS   = %w[strike fire outage flood cooling other].freeze
  ICONS   = { 'strike' => '💥', 'fire' => '🔥', 'outage' => '⚡', 'flood' => '💧', 'cooling' => '🌡️', 'other' => '⚠️' }.freeze
  SIZE    = 5
  STATUSES = %w[operational building planned].freeze

  # Providers (companies) for the per-provider cards: slug => name per locale.
  PROVIDERS = {
    'yandex' => %w[Яндекс Yandex Яндекс], 'ixcellerate' => %w[IXcellerate] * 3,
    'rtk' => %w[РТК-ЦОД RTK-DC РТК-ЦОД], 'atomdata' => ['Атомдата (Росатом)', 'Atomdata (Rosatom)', 'Атомдата (Росатом)'],
    'datapro' => %w[DataPro] * 3, 'selectel' => %w[Selectel] * 3, 'mws' => ['MWS / МТС', 'MWS / MTS', 'MWS / МТС'],
    'keypoint' => ['Key Point'] * 3, '3data' => %w[3data] * 3, 'sber' => %w[Сбер Sber Сбер],
    'megafon' => %w[МегаФон MegaFon МегаФон], 'datahouse' => %w[DataHouse] * 3, 'oxygen' => %w[OXYGEN] * 3,
    'linx' => %w[Linx] * 3, 'cloudx' => ['Cloud X'] * 3, 'nkgroup' => ['NK Group'] * 3, 'goznak' => %w[Гознак Goznak Гознак],
    'dataspace' => %w[DataSpace] * 3, 'cloudru' => %w[Cloud.ru] * 3, 'x5' => ['X5 Group'] * 3, 'krok' => %w[КРОК CROC КРОК],
    'stack' => ['Stack Group'] * 3, 'beeline' => %w[Билайн Beeline Білайн]
  }.transform_values { |names| %w[ru en uk].zip(names).to_h }.freeze

  def self.provider_name(slug, locale) = PROVIDERS.dig(slug, locale) || slug

  # Every row, column and both diagonals, as 0-based cell indices.
  LINES = (
    (0...SIZE).map { |r| (0...SIZE).map { |c| r * SIZE + c } } +
    (0...SIZE).map { |c| (0...SIZE).map { |r| r * SIZE + c } } +
    [(0...SIZE).map { |i| i * SIZE + i }, (0...SIZE).map { |i| i * SIZE + SIZE - 1 - i }]
  ).freeze

  T = {
    'ru' => {
      seo_title: 'Бинго ЦОДов — атаки, пожары и аварии дата-центров России',
      seo_desc: '%{hit} из %{total} крупнейших дата-центров России уже зачёркнуты. Бинго-карточка ЦОДов IXcellerate, Яндекса, Ростелекома, Росатома и других: атаки БПЛА, пожары и отключения с источниками.',
      og_locale: 'ru_RU',
      title: 'Бинго ЦОДов', accent: 'ЦОДов', lead: 'Бинго',
      tagline: 'Атаки БПЛА, пожары и аварии в 25 крупнейших дата-центрах России',
      desc: 'Рейтинг по мощности. Клетка зачёркивается после публично подтверждённого инцидента.',
      crossed: 'Зачёркнуто', lines: 'линий', updated: 'обновлено',
      log: 'Журнал инцидентов', empty: 'Пока всё работает. Пока.',
      bingo: 'БИНГО!', bingo_n: 'БИНГО ×%d!', full: 'ПОЛНАЯ КАРТА. Интернета больше нет.',
      planned: 'планируется', mva: 'МВА',
      mw_types: { 'it' => 'ИТ', 'connected' => 'подв.', 'total' => 'общ.', 'design' => 'проект' },
      building: 'строится', mw: 'МВт', since: 'с %d г.', photo: 'Фото', source: 'Источник',
      close: 'Закрыть', no_incidents: 'Инцидентов не зафиксировано.',
      credits_ai: 'Информация собрана и проверена с помощью Claude (Anthropic).',
      credits_hym: 'Спасибо %{link} (данные Cat Eyes OSINT) за часть списка: каждая запись перепроверена по сайтам операторов и прессе.',
      source_code: 'Исходный код на GitHub',
      footer: 'Данные из открытых источников (2025–2026). Клетка зачёркивается только по публичному источнику.',
      kinds: { 'strike' => 'Атака БПЛА', 'fire' => 'Пожар', 'outage' => 'Отключение', 'flood' => 'Затопление', 'cooling' => 'Перегрев', 'other' => 'Инцидент' },
      letters: %w[Б И Н Г О],
      providers_label: 'Собрать карточку из провайдеров', providers_apply: 'Показать', providers_reset: 'Все провайдеры',
      view_all: 'Все', view_operational: 'Только действующие', view_label: 'Какие ЦОДы показывать',
      dc_title: '%{name} (%{city}) — инциденты ЦОДа | Бинго ЦОДов',
      dc_title_hit: '%{name} (%{city}) — %{kind}, %{date} | Бинго ЦОДов',
      dc_intro: '%{name} — дата-центр в городе %{city}, оператор — %{operator}.',
      dc_capacity: 'Мощность: %{mw}.', dc_building: 'Строится.', dc_planned: 'Планируется.',
      dc_since: 'Работает с %d года.',
      dc_rank: '№ %{pos} по мощности среди крупнейших дата-центров России.',
      dc_latest: 'Последний инцидент (%{date}): %{title}', incidents: 'Инциденты',
      back: '← К карточке', dc_page: 'Страница ЦОДа →'
    },
    'en' => {
      seo_title: 'Datacenter Bingo — strikes, fires and outages at Russian datacenters',
      seo_desc: '%{hit} of Russia\'s %{total} largest datacenters are already crossed out. A bingo card of IXcellerate, Yandex, Rostelecom, Rosatom and other datacenters: drone strikes, fires and outages, each with a source.',
      og_locale: 'en_US',
      title: 'Datacenter Bingo', accent: 'Bingo', lead: 'Datacenter',
      tagline: "Drone strikes, fires and outages at Russia's 25 largest datacenters",
      desc: "Ranked by power. A cell is crossed out after a publicly reported incident.",
      crossed: 'Crossed out', lines: 'lines', updated: 'updated',
      log: 'Incident log', empty: 'Everything is up. For now.',
      bingo: 'BINGO!', bingo_n: 'BINGO ×%d!', full: 'FULL CARD. There is no more internet.',
      planned: 'planned', mva: 'MVA',
      mw_types: { 'it' => 'IT', 'connected' => 'connected', 'total' => 'total', 'design' => 'design' },
      building: 'under construction', mw: 'MW', since: 'since %d', photo: 'Photo', source: 'Source',
      close: 'Close', no_incidents: 'No incidents recorded.',
      credits_ai: 'Information collected and verified with the help of Claude (Anthropic).',
      credits_hym: 'Thanks to %{link} (data by Cat Eyes OSINT) for part of the list; every entry was re-verified against operator sites and the press.',
      source_code: 'Source code on GitHub',
      footer: 'Open-source data (2025–2026). A cell is crossed out only with a public source.',
      kinds: { 'strike' => 'Drone strike', 'fire' => 'Fire', 'outage' => 'Outage', 'flood' => 'Flood', 'cooling' => 'Overheating', 'other' => 'Incident' },
      letters: %w[B I N G O],
      providers_label: 'Build a card from providers', providers_apply: 'Show', providers_reset: 'All providers',
      view_all: 'All', view_operational: 'Operational only', view_label: 'Which datacenters to show',
      dc_title: '%{name} (%{city}) — datacenter incidents | Datacenter Bingo',
      dc_title_hit: '%{name} (%{city}) — %{kind}, %{date} | Datacenter Bingo',
      dc_intro: '%{name} is a datacenter in %{city} operated by %{operator}.',
      dc_capacity: 'Capacity: %{mw}.', dc_building: 'Under construction.', dc_planned: 'Planned.',
      dc_since: 'In service since %d.',
      dc_rank: "No. %{pos} by power among Russia's largest datacenters.",
      dc_latest: 'Latest reported incident (%{date}): %{title}', incidents: 'Incidents',
      back: '← Back to the card', dc_page: 'Datacenter page →'
    },
    'uk' => {
      seo_title: 'Бінго ЦОДів — атаки, пожежі та аварії дата-центрів Росії',
      seo_desc: '%{hit} з %{total} найбільших дата-центрів Росії вже закреслено. Бінго-картка ЦОДів IXcellerate, Яндекса, Ростелекому, Росатому та інших: атаки БПЛА, пожежі й відключення з джерелами.',
      og_locale: 'uk_UA',
      title: 'Бінго ЦОДів', accent: 'ЦОДів', lead: 'Бінго',
      tagline: 'Атаки БПЛА, пожежі та аварії у 25 найбільших дата-центрах Росії',
      desc: 'Рейтинг за потужністю. Клітинка закреслюється після публічно підтвердженого інциденту.',
      crossed: 'Закреслено', lines: 'ліній', updated: 'оновлено',
      log: 'Журнал інцидентів', empty: 'Поки що все працює. Поки що.',
      bingo: 'БІНГО!', bingo_n: 'БІНГО ×%d!', full: 'ПОВНА КАРТКА. Інтернету більше немає.',
      planned: 'планується', mva: 'МВА',
      mw_types: { 'it' => 'ІТ', 'connected' => 'підв.', 'total' => 'заг.', 'design' => 'проєкт' },
      building: 'будується', mw: 'МВт', since: 'з %d р.', photo: 'Фото', source: 'Джерело',
      close: 'Закрити', no_incidents: 'Інцидентів не зафіксовано.',
      credits_ai: 'Інформацію зібрано й перевірено за допомогою Claude (Anthropic).',
      credits_hym: 'Дякуємо %{link} (дані Cat Eyes OSINT) за частину списку: кожен запис перевірено за сайтами операторів і пресою.',
      source_code: 'Вихідний код на GitHub',
      footer: 'Дані з відкритих джерел (2025–2026). Клітинка закреслюється лише за публічним джерелом.',
      kinds: { 'strike' => 'Атака БПЛА', 'fire' => 'Пожежа', 'outage' => 'Відключення', 'flood' => 'Затоплення', 'cooling' => 'Перегрів', 'other' => 'Інцидент' },
      letters: %w[Б І Н Г О],
      providers_label: 'Зібрати картку з провайдерів', providers_apply: 'Показати', providers_reset: 'Усі провайдери',
      view_all: 'Усі', view_operational: 'Лише діючі', view_label: 'Які ЦОДи показувати',
      dc_title: '%{name} (%{city}) — інциденти ЦОДу | Бінго ЦОДів',
      dc_title_hit: '%{name} (%{city}) — %{kind}, %{date} | Бінго ЦОДів',
      dc_intro: '%{name} — дата-центр у місті %{city}, оператор — %{operator}.',
      dc_capacity: 'Потужність: %{mw}.', dc_building: 'Будується.', dc_planned: 'Планується.',
      dc_since: 'Працює з %d року.',
      dc_rank: '№ %{pos} за потужністю серед найбільших дата-центрів Росії.',
      dc_latest: 'Останній інцидент (%{date}): %{title}', incidents: 'Інциденти',
      back: '← До картки', dc_page: 'Сторінка ЦОДу →'
    }
  }.freeze

  # Localized column with fallback to ru.
  module Localized
    def l(field, locale)
      v = self[:"#{field}_#{locale}"].to_s.strip
      v.empty? ? self[:"#{field}_ru"] : v
    end
  end

  class Datacenter < Sequel::Model(:bingo_datacenters)
    include Localized
    one_to_many :incidents, class: 'Bingo::Incident', key: :datacenter_id, order: Sequel.desc(:occurred_on)

    def before_create
      self.created_at ||= Time.now.utc
      super
    end

    def before_save
      self.updated_at = Time.now.utc
      super
    end

    def operational? = status == 'operational'
    def planned?     = status == 'planned'

    def building?
      status == 'building'
    end

    # width: a resized variant (480, 1200) (falls back to the original until the
    # variants exist), nil for the original.
    def photo_file(width = nil)
      return unless photo_key
      key = width && photo_variants ? Photo.variant_key(photo_key, width) : photo_key
      key.delete_prefix(Photo::PREFIX)
    end

    # Paragraphs of the datacenter page's prose in exactly this locale.
    def about(locale)
      self[:"about_#{locale}"].to_s.strip.split(/\n\s*\n/).map(&:strip)
    end

    # 1200x630 JPEG for og:image (every preview client renders it); the
    # webp dialog variant until it exists.
    def og_file
      return photo_file(1200) unless photo_key && photo_og
      Photo.og_key(photo_key).delete_prefix(Photo::PREFIX)
    end
  end

  class Incident < Sequel::Model(:bingo_incidents)
    include Localized
    many_to_one :datacenter, class: 'Bingo::Datacenter'

    def before_create
      self.created_at ||= Time.now.utc
      super
    end

    def before_save
      self.updated_at = Time.now.utc
      super
    end
  end

  # Board state for rendering: ordered cells, hits and completed lines.
  VIEWS = %w[operational all].freeze # first is the default (bare URL)

  # The card is always 5×5: the first SIZE*SIZE datacenters by position,
  # optionally only operational ones and/or only the chosen providers. A
  # selection with fewer datacenters leaves the remaining cells empty.
  Board = Struct.new(:cells, :hit, :wins, :incidents, :updated_on, :view, :providers) do
    def self.load(view = 'all', providers: nil)
      scope = Datacenter.order(:position, :id)
      scope = scope.where(status: 'operational') if view == 'operational'
      scope = scope.where(provider: providers) if providers&.any?
      cells = scope.limit(SIZE * SIZE).eager(:incidents).all
      hit   = cells.map { |dc| dc.incidents.any? }
      wins  = LINES.select { |line| line.all? { |i| hit[i] } }
      incidents = cells.flat_map(&:incidents).sort_by { |i| [i.occurred_on, i.id] }.reverse
      updated = [Datacenter.max(:updated_at), Incident.max(:updated_at)].compact.max
      new(cells, hit, wins, incidents, updated, view, providers)
    end

    def filtered? = providers&.any? || false

    # [[slug, total, crossed]] for every provider with datacenters in this view.
    def self.providers(view)
      scope = Datacenter.exclude(provider: nil)
      scope = scope.where(status: 'operational') if view == 'operational'
      scope.eager(:incidents).all.group_by(&:provider)
           .map { |slug, dcs| [slug, dcs.size, dcs.count { |d| d.incidents.any? }] }
           .sort_by { |slug, n, x| [-x, -n, slug] }
    end

    def operational_only? = view == 'operational'

    def win_cells
      @win_cells ||= wins.flatten.to_set
    end
  end

  # Photos live in the asxpio MinIO bucket under bingo/ (uploaded and resized
  # by the asxp.io admin) and are proxied here, so the bucket stays private.
  module Photo
    PREFIX  = 'bingo/'.freeze
    OG_SIZE = [1200, 630].freeze # og:image, cropped to the 1.91:1 card
    FILE_RE = /\A[a-z0-9-]+-[0-9a-f]{8}(?:-(?:480|1200|og))?\.(jpg|png|webp)\z/
    TYPES   = { 'jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp' }.freeze

    class Error < StandardError; end

    module_function

    def variant_key(key, width)
      key.sub(/\.\w+\z/, "-#{width}.webp")
    end

    def og_key(key)
      key.sub(/\.\w+\z/, '-og.jpg')
    end

    def read(file)
      raise Error, 'bad name' unless file =~ FILE_RE
      [S3.get(PREFIX + file), TYPES[Regexp.last_match(1)]]
    end
  end

  # IndexNow pings are sent by the asxp.io admin; this site only serves the
  # key file at /<key>.txt to prove they come from us.
  module IndexNow
    module_function

    def key = ENV['INDEXNOW_KEY'].to_s[/\A[A-Za-z0-9-]{8,128}\z/]
  end
end
