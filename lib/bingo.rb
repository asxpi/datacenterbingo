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
    'stack' => ['Stack Group'] * 3, 'beeline' => %w[Билайн Beeline Білайн], 'vk' => %w[VK] * 3
  }.transform_values { |names| %w[ru en uk].zip(names).to_h }.freeze

  def self.provider_name(slug, locale) = PROVIDERS.dig(slug, locale) || slug

  # "64" → 64.0, "25–30" → 30.0, ">40" → 40.0, "13,7" → 13.7, "" → nil
  def self.mw_value(mw)
    mw.to_s.tr(',', '.').scan(/\d+(?:\.\d+)?/).map(&:to_f).max
  end

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
      feed_title: '%{site} — Журнал инцидентов', open_data: 'Открытые данные (CC BY 4.0)',
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
      dc_rank: '№ %{pos} по мощности среди действующих крупнейших дата-центров России.',
      dc_latest: 'Последний инцидент (%{date}): %{title}', incidents: 'Инциденты',
      back: '← К карточке', dc_page: 'Страница ЦОДа →',
      status_link: 'Доступность ЦОДов', status_title: 'Доступность ЦОДов России — сетевой мониторинг | Бинго ЦОДов',
      status_h1: 'Доступность', status_accent: 'ЦОДов', status_tagline: 'Сетевые проверки крупнейших дата-центров России раз в минуту',
      status_lead: 'Раз в минуту мы открываем TCP-соединение с публичными адресами, которые открытые источники связывают с конкретной площадкой. Проверка идёт из Финляндии: российская фильтрация и отключения внешних каналов могут выглядеть как авария, поэтому параллельно проверяются контрольные узлы в России.',
      status_note: 'Это не подтверждённые инциденты: клетка на карточке зачёркивается только по публичному источнику.',
      status_states: { 'up' => 'доступен', 'degraded' => 'частично', 'down' => 'не отвечает', 'unknown' => 'нет данных' },
      status_controls: 'Контрольные узлы в России: %{ok} из %{n} отвечают.',
      status_stale: 'Монитор давно не присылал данных — состояние неизвестно.',
      status_vantage: 'Большинство контрольных узлов в России не отвечает: проблема, скорее всего, на пути из-за границы, а не на площадках.',
      status_checked: 'Последняя проверка: %{time} UTC.', status_never: 'Проверок ещё не было.',
      status_unmonitored: 'Без мониторинга', status_unmonitored_note: 'Действующие ЦОДы, для которых нет публичных адресов, надёжно привязанных к площадке (обычно собственные ЦОДы Яндекса, VK, Сбера).',
      status_cols: { 'dc' => 'ЦОД', 'state' => 'Сейчас', 'hours' => '24 часа', 'rtt' => 'мс', 'targets' => 'адр.' },
      status_dc: 'Доступность сети', status_hour: '%{h} ч назад: %{p}',
      status_desc: 'Доступность крупнейших дата-центров России онлайн: ежеминутные сетевые проверки IXcellerate, Selectel, DataPro, Key Point и других, история за 24 часа и открытые данные.',
      status_probes: 'Что проверяем', status_controls_list: 'Контрольные узлы в России', status_no_answer: 'не отвечает', status_source: 'почему этот адрес',
      policy_link: 'Без спама', policy_title: 'Без нежелательных рассылок | Бинго ЦОДов',
      policy_desc: 'Бинго ЦОДов никогда не рекламируется нежелательными сообщениями. Сайт не отправляет писем и не ведёт рассылок.',
      policy_text: ['datacenterbingo.xyz никогда не рекламируется нежелательными письмами, SMS, сообщениями в мессенджерах, на форумах или в соцсетях. Ни мы, ни кто-либо другой не вправе продвигать сайт таким образом.',
                    'Сайт не отправляет писем, у него нет рассылок, подписок и форм обратной связи. На нём нет рекламы, партнёрских программ и платного продвижения.',
                    'Если вы получили сообщение со ссылкой на этот сайт, его отправили не мы. Пожалуйста, сообщите о нём через %{link}.']
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
      feed_title: '%{site} — Incident log', open_data: 'Open data (CC BY 4.0)',
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
      dc_rank: "No. %{pos} by power among Russia's largest operational datacenters.",
      dc_latest: 'Latest reported incident (%{date}): %{title}', incidents: 'Incidents',
      back: '← Back to the card', dc_page: 'Datacenter page →',
      status_link: 'Datacenter reachability', status_title: "Russian datacenter reachability — network monitor | Datacenter Bingo",
      status_h1: 'Datacenter', status_accent: 'reachability', status_tagline: "Minute-by-minute network checks of Russia's largest datacenters",
      status_lead: 'Once a minute we open a TCP connection to public addresses that open sources tie to a specific site. Probes run from Finland: Russian filtering and cuts to international links can look like an outage, so control hosts inside Russia are checked alongside.',
      status_note: 'These are not confirmed incidents: a cell on the card is crossed out only on a public source.',
      status_states: { 'up' => 'reachable', 'degraded' => 'partial', 'down' => 'not answering', 'unknown' => 'no data' },
      status_controls: 'Control hosts in Russia: %{ok} of %{n} answering.',
      status_stale: 'The monitor has not reported for a while — state unknown.',
      status_vantage: 'Most control hosts in Russia are not answering: the problem is most likely on the path from abroad, not at the sites.',
      status_checked: 'Last check: %{time} UTC.', status_never: 'No checks yet.',
      status_unmonitored: 'Not monitored', status_unmonitored_note: 'Operational datacenters with no public address reliably tied to the site (mostly Yandex, VK and Sber in-house sites).',
      status_cols: { 'dc' => 'Datacenter', 'state' => 'Now', 'hours' => '24 hours', 'rtt' => 'ms', 'targets' => 'addr.' },
      status_dc: 'Network reachability', status_hour: '%{h} h ago: %{p}',
      status_desc: "Live reachability of Russia's largest datacenters: minute-by-minute network checks of IXcellerate, Selectel, DataPro, Key Point and others, 24-hour history and open data.",
      status_probes: 'What we check', status_controls_list: 'Control hosts in Russia', status_no_answer: 'no answer', status_source: 'why this address',
      policy_link: 'No-spam policy', policy_title: 'No unsolicited messages | Datacenter Bingo',
      policy_desc: 'Datacenter Bingo is never advertised by unsolicited messages. The site sends no email and runs no mailing list.',
      policy_text: ['datacenterbingo.xyz is never advertised by unsolicited email, SMS, messenger, forum or social media messages. Neither we nor any third party may promote the site this way.',
                    'The site sends no email and has no mailing list, newsletter or contact form. It carries no ads, affiliate programs or paid promotion.',
                    'If you received a message linking to this site, we did not send it. Please report it via %{link}.']
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
      feed_title: '%{site} — Журнал інцидентів', open_data: 'Відкриті дані (CC BY 4.0)',
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
      dc_rank: '№ %{pos} за потужністю серед найбільших діючих дата-центрів Росії.',
      dc_latest: 'Останній інцидент (%{date}): %{title}', incidents: 'Інциденти',
      back: '← До картки', dc_page: 'Сторінка ЦОДу →',
      status_link: 'Доступність ЦОДів', status_title: 'Доступність ЦОДів Росії — мережевий моніторинг | Бінго ЦОДів',
      status_h1: 'Доступність', status_accent: 'ЦОДів', status_tagline: 'Мережеві перевірки найбільших дата-центрів Росії щохвилини',
      status_lead: 'Раз на хвилину ми відкриваємо TCP-з’єднання з публічними адресами, які відкриті джерела пов’язують із конкретним майданчиком. Перевірка йде з Фінляндії: російська фільтрація та відключення зовнішніх каналів можуть виглядати як аварія, тому паралельно перевіряються контрольні вузли в Росії.',
      status_note: 'Це не підтверджені інциденти: клітинка на картці закреслюється лише за публічним джерелом.',
      status_states: { 'up' => 'доступний', 'degraded' => 'частково', 'down' => 'не відповідає', 'unknown' => 'немає даних' },
      status_controls: 'Контрольні вузли в Росії: %{ok} з %{n} відповідають.',
      status_stale: 'Монітор давно не надсилав даних — стан невідомий.',
      status_vantage: 'Більшість контрольних вузлів у Росії не відповідає: проблема, найімовірніше, на шляху з-за кордону, а не на майданчиках.',
      status_checked: 'Остання перевірка: %{time} UTC.', status_never: 'Перевірок ще не було.',
      status_unmonitored: 'Без моніторингу', status_unmonitored_note: 'Діючі ЦОДи, для яких немає публічних адрес, надійно прив’язаних до майданчика (здебільшого власні ЦОДи Яндекса, VK, Сбера).',
      status_cols: { 'dc' => 'ЦОД', 'state' => 'Зараз', 'hours' => '24 години', 'rtt' => 'мс', 'targets' => 'адр.' },
      status_dc: 'Доступність мережі', status_hour: '%{h} год тому: %{p}',
      status_desc: 'Доступність найбільших дата-центрів Росії онлайн: щохвилинні мережеві перевірки IXcellerate, Selectel, DataPro, Key Point та інших, історія за 24 години та відкриті дані.',
      status_probes: 'Що перевіряємо', status_controls_list: 'Контрольні вузли в Росії', status_no_answer: 'не відповідає', status_source: 'чому ця адреса',
      policy_link: 'Без спаму', policy_title: 'Без небажаних розсилок | Бінго ЦОДів',
      policy_desc: 'Бінго ЦОДів ніколи не рекламується небажаними повідомленнями. Сайт не надсилає листів і не веде розсилок.',
      policy_text: ['datacenterbingo.xyz ніколи не рекламується небажаними листами, SMS, повідомленнями в месенджерах, на форумах чи в соцмережах. Ні ми, ні будь-хто інший не має права просувати сайт у такий спосіб.',
                    'Сайт не надсилає листів, не має розсилок, підписок і форм зворотного зв’язку. На ньому немає реклами, партнерських програм і платного просування.',
                    'Якщо ви отримали повідомлення з посиланням на цей сайт, його надіслали не ми. Будь ласка, повідомте про нього через %{link}.']
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

  # Network reachability from asxpio's monitor (bin/monitor there writes the
  # bingo_monitor_* tables). Each 5-minute bucket counts TCP probes sent and
  # answered per datacenter, plus probes to control hosts in Russia that
  # belong to no listed site.
  module Status
    BUCKET = 300
    STALE  = 900  # newest worker bucket older than this: nothing is current
    HOURS  = 24

    # targets / control_hosts: the probed hosts (endpoint, label, source and
    # last result), shown so readers can see and check what is measured.
    Site = Struct.new(:dc, :state, :availability, :rtt_ms, :history, :targets)
    Report = Struct.new(:sites, :unmonitored, :checked_at, :controls, :state, :control_hosts) do
      def counts = sites.map(&:state).tally
    end

    module_function

    def available? = DB.connection.table_exists?(:bingo_monitor_samples)

    # A bucket is trusted when at least half the control hosts answered; with
    # none answering, a dark site may just mean our vantage point lost Russia.
    def vantage_ok?(bucket)
      bucket[:control_checks].zero? || bucket[:control_ok] * 2 >= bucket[:control_checks]
    end

    # state: up (≥80 % of probes answered), degraded, down (nothing answered
    # in the last two buckets), unknown (worker stale, vantage lost, the
    # site wasn't probed in the newest bucket, or its targets never answered
    # in the window: a host that is filtered from abroad would otherwise
    # read as a dark site).
    def site_state(rows, latest, previous, trusted)
      return 'unknown' unless latest && trusted
      cur = rows[latest] or return 'unknown'
      return 'unknown' if rows.each_value.sum { |r| r[:ok] }.zero?
      prev = previous && rows[previous]
      return 'down' if cur[:ok].zero? && (prev.nil? || prev[:ok].zero?)
      cur[:ok] >= cur[:checks] * 0.8 ? 'up' : 'degraded'
    end

    # only: a datacenter id, for one datacenter page.
    def load(now = Time.now.utc, hours: HOURS, only: nil)
      db = DB.connection
      since = now - (hours * 3600)
      buckets = db[:bingo_monitor_buckets].where { bucket_at >= since }.order(:bucket_at).all
      latest = buckets.last
      fresh = latest && now - latest[:bucket_at] < STALE
      trusted = fresh && vantage_ok?(latest)
      latest_at = fresh ? latest[:bucket_at] : nil
      previous_at = fresh && buckets.size > 1 ? buckets[-2][:bucket_at] : nil
      bad_hours = buckets.reject { |b| vantage_ok?(b) }.map { |b| hour_index(b[:bucket_at], now, hours) }.to_set

      samples = db[:bingo_monitor_samples].where { bucket_at >= since }
      targets = db[:bingo_monitor_targets].where(active: true)
                                          .select(:datacenter_id, :host, :port, :label, :source_url, :last_ok, :last_rtt_ms)
                                          .order(:host, :port)
      dcs = Datacenter.order(:position, :id)
      samples, targets, dcs = [samples.where(datacenter_id: only), targets.where(datacenter_id: [only, nil]), dcs.where(id: only)] if only
      samples = samples.all.group_by { |r| r[:datacenter_id] }
      targets = targets.all.group_by { |r| r[:datacenter_id] }
      controls = targets.delete(nil) || []
      dcs = dcs.all
      monitored, unmonitored = dcs.partition { |dc| targets.key?(dc.id) }

      sites = monitored.map do |dc|
        rows = (samples[dc.id] || []).to_h { |r| [r[:bucket_at], r] }
        cur = latest_at && rows[latest_at]
        Site.new(dc, site_state(rows, latest_at, previous_at, trusted),
                 cur && cur[:checks].positive? ? cur[:ok].fdiv(cur[:checks]) : nil,
                 cur && cur[:ok].positive? ? (cur[:rtt_ms_sum] / cur[:ok]) : nil,
                 history(rows.values, now, hours, bad_hours), targets[dc.id])
      end
      Report.new(sites, unmonitored.select(&:operational?), latest && latest[:bucket_at],
                 latest && [latest[:control_ok], latest[:control_checks]],
                 !fresh ? 'stale' : (trusted ? 'ok' : 'vantage'), controls)
    end

    def hour_index(time, now, hours) = hours - 1 - ((now - time) / 3600).floor

    # Answered share per hour, oldest first; nil = no data or untrusted hour.
    def history(rows, now, hours, bad_hours)
      per = Array.new(hours) { [0, 0] }
      rows.each do |r|
        i = hour_index(r[:bucket_at], now, hours)
        next unless i.between?(0, hours - 1)
        per[i][0] += r[:ok]
        per[i][1] += r[:checks]
      end
      per.each_with_index.map { |(ok, n), i| n.zero? || bad_hours.include?(i) ? nil : ok.fdiv(n) }
    end
  end

  # IndexNow pings are sent by the asxp.io admin; this site only serves the
  # key file at /<key>.txt to prove they come from us.
  module IndexNow
    module_function

    def key = ENV['INDEXNOW_KEY'].to_s[/\A[A-Za-z0-9-]{8,128}\z/]
  end
end
