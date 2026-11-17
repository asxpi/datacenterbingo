# datacenterbingo

Public site for datacenterbingo.xyz: a 5×5 bingo card of Russia's largest
datacenters, crossed out on publicly sourced incidents. Ruby/Sinatra,
read-only. Primary repo `git.czsk.it/asxpi/datacenterbingo` (Forgejo, CI and
deploy); `github.com/asxpi/datacenterbingo` is a push mirror.

## Shared with asxpio

Content is edited in the asxp.io admin (`/admin/bingo`, repo `asxpio`:
`lib/bingo.rb`, `lib/bingo_admin.rb`). Both apps use the same Postgres tables
(`bingo_datacenters`, `bingo_incidents`) and the photos under `bingo/` in the
`datacenterbingo-photos` bucket (asxpio's admin uploads them there).

- **asxpio owns the schema.** Migrations live there. After it adds a
  bingo migration, refresh `test/schema.sql` (instructions in its header)
  and update the models here.
- `lib/bingo.rb` here is the read side of asxpio's: models, `Board`,
  `PROVIDERS`, the `T` UI strings, and photo/IndexNow key reading. The
  admin side (writes, photo upload and resizing, IndexNow pings, ranking,
  seeding, `guess_provider`) stays in asxpio. Keep shared parts in step:
  `PROVIDERS`, `Board`, and model methods.
- Prod uses a read-only DB role `bingo` (SELECT on the two tables) and an
  S3 key (Garage) that can only read `datacenterbingo-photos`. Both
  are provisioned by the `storage` repo (`init/`), from the same
  `BINGO_*` secrets set on both repos.

## Research

Before adding or changing datacenters, incidents or photos, follow
`OSINT.md`. It covers sources, verification, photo rules (no people, and
renderings only for unbuilt sites) and credit format.

## Layout

- `app.rb`: `BingoWeb`. Routes: `/` (redirect by Accept-Language), `/ru|en|uk`
  (card; `?view=all`, `?p[]=provider`), `/:locale/dc/:slug`, `/sitemap.xml`,
  `/robots.txt`, `/p/:file` (photo proxy, immutable), `/<indexnow-key>.txt`,
  icons, `/healthz`.
- Feeds: `/:locale/feed.xml` (RSS 2.0) and `/:locale/feed.json` (JSON Feed
  1.1), the latest 50 incidents, newest first. Item IDs are
  `tag:<host>,2026:incident-<id>`, so they stay stable when an incident is
  edited. Pages advertise both via `<link rel="alternate">` and in the
  footer.
- `/data.json`: every datacenter with names in all locales, specs, pages,
  photo credit and incidents with sources. Licensed CC BY 4.0, with the
  attribution inside the file. Feeds and dataset send
  `Access-Control-Allow-Origin: *`.
- Reachability: `/:locale/status` and `/status.json` (`Bingo::Status`),
  plus a block on monitored datacenter pages. They read the
  `bingo_monitor_*` tables that asxpio's `bin/monitor` writes (TCP probes
  from Finland, 5-minute buckets, control hosts in Russia). States: up,
  degraded, down (nothing answered for two buckets), unknown (worker stale,
  or under half the controls answering). Not incidents: never cross out a
  cell from this alone.
- `/:locale/policy`: the no-unsolicited-messages policy, also in
  `README.md`. Blocklists (SURBL) require a published one to delist; keep
  both copies in step.
- `config.ru`: `www.` → `BINGO_HOST` 301.
- `views/`: `layout.erb` (CSS and SEO head), `index.erb` (card, provider
  filter, dialogs), `dc.erb`, partials. `assets/`: icons.
- Card rules: always 5×5. The bare locale URL is the operational card
  (indexed). `?view=all` and provider-filtered URLs are noindex, with
  canonical pointing to the bare page.

## Dev and tests

`nix develop`, then `bin/test`. That provisions an ephemeral Postgres and
loads `test/schema.sql`. Run `cp .env.example .env` for a local server
(`rackup`), pointing it at a DB that has the bingo tables.

## Deploy

`flake.nix` builds the app (`packages.default`: bundlerEnv from
`Gemfile.lock` and `gemset.nix`) and runs it (`nixosModules.default`,
`services.datacenterbingo`: Puma as a hardened systemd service) on
asxpio-services; Traefik on asxpio-ops routes `datacenterbingo.xyz` and
`www.` there. A push to `main` is picked up by Renovate in asxpi/iac (flake
input `datacenterbingo`) within about 15 minutes and deployed by comin; CI
here only tests (`.forgejo/workflows/ci.yaml`: tests, `bin/check-gemset`,
the package build).

After changing `Gemfile.lock`: `nix run nixpkgs#bundix` to refresh
`gemset.nix` (CI fails until they match). Puma starts through the
bundlerEnv's binstub with `BUNDLE_FORCE_RUBY_PLATFORM` (the lock lists
precompiled gems for other platforms; Nix builds the source gems).

Settings and secrets live in iac (`nixos/hosts/asxpio-services/apps.nix`,
sops key `datacenterbingo/env`: `DATABASE_URL` for the read-only role
`bingo`, the read-only S3 key in Garage's format, `INDEXNOW_KEY`, the same
key as asxpio's). This repository holds no deploy secrets.
