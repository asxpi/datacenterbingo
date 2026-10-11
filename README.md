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

Development: `nix develop`, then `bin/test`. See `CLAUDE.md`.
