# Datacenter Bingo

https://datacenterbingo.xyz: a 5×5 bingo card of Russia's largest
datacenters. A cell is crossed out once a drone strike, fire or outage
there is reported by a public source. Available in Ukrainian, English and
Russian.

This repo is the public site (Ruby/Sinatra). Content is managed from a
separate admin app that shares the database.

Data comes from open sources. It was collected and verified with the help
of Claude (Anthropic). Part of the list came from the
[hackyourmom datacenter map](https://hackyourmom.com/en/karta-data-czentriv-na-rasii/)
(data by Cat Eyes OSINT), and each entry was re-verified.

## Data

- **Incident feeds:** `/en/feed.xml` (RSS) and `/en/feed.json` (JSON Feed).
  Swap `en` for `ru` or `uk`.
- **Full dataset:** [`/data.json`](https://datacenterbingo.xyz/data.json),
  licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  Credit "Datacenter Bingo (datacenterbingo.xyz)"; the full attribution
  line is in the file.

## No unsolicited messages

datacenterbingo.xyz is never advertised by unsolicited email, SMS,
messenger, forum or social media messages. Neither we nor any third party
may promote the site this way. The site sends no email and has no mailing
list, newsletter or contact form, and it carries no ads, affiliate programs
or paid promotion.

If you received a message linking to this site, we did not send it. Please
report it via [asxp.io/contact](https://asxp.io/contact). The same policy
is on the site at [/en/policy](https://datacenterbingo.xyz/en/policy).

Development: `nix develop`, then `bin/test`. See `CLAUDE.md`.
