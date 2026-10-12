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
- Prod uses a read-only DB role `bingo` (SELECT on the two tables) and a
  MinIO user limited to `s3:GetObject` on `datacenterbingo-photos`. Both
  are provisioned by the `storage` repo (`init/`), from the same
  `BINGO_*` secrets set on both repos.

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

On push to `main`, `.forgejo/workflows/deploy.yaml` tests, builds with kaniko
to `$FJ_REGISTRY/$FJ_USER/datacenterbingo`, then over SSH writes
`/opt/datacenterbingo/{docker-compose.yml,.env}` and runs
`docker compose up -d`. The container is on the `traefik` and `storage`
networks, and the Traefik router `datacenterbingo` takes `BINGO_HOST` and
`www.`.

Secrets:

| Secret | Purpose |
|---|---|
| `FJ_REGISTRY`, `FJ_USER`, `FJ_TOKEN` | kaniko clone + push (`write:package`, `read:repository`); Forgejo reserves the `FORGEJO_` prefix |
| `DEPLOY_IP`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` | SSH to prod |
| `BINGO_DB_PASSWORD` | read-only Postgres role `bingo` |
| `BINGO_S3_ACCESS_KEY`, `BINGO_S3_SECRET_KEY` | read-only MinIO user |
| `INDEXNOW` | same key as asxpio's `INDEXNOW` (served here, pinged from there) |
