# OSINT rules for datacenter data and photos

How facts, incidents and photos get onto the card. Everything is open
source, and every entry has to survive a skeptical reader clicking its
source link.

## Principles

1. **One public source per claim, ideally primary.** Primary sources are
   the operator's own site, press releases, its Habr blog, annual or
   ESG reports, and government or registry filings. Trade press (CNews,
   ComNews, TAdviser, Kommersant, RBC, Vedomosti, Interfax) comes next.
   Aggregators, listicles and social posts are leads only.
2. **Verify, don't trust the list.** Third-party maps and rankings,
   including the hackyourmom datacenter map (Cat Eyes OSINT data), are
   starting points. Every entry taken from them was re-checked against
   operator or press sources before it was added.
3. **Record conflicts, don't resolve them silently.** If sources
   disagree on capacity, year or status, use the most authoritative and
   most recent one, and note the conflict in the data center's
   description or `info_url`.
4. **City level only.** Addresses help verification but aren't
   published. Photo metadata, including GPS, is stripped on upload.
5. **Write it so the next person can repeat it.** Save the exact
   source URL (the article or page, not a search result), and the
   archive URL when the original is gone.

## Facts

| Field | Rule |
|---|---|
| Name | The operator's own name for the site (ru required; en/uk added when the operator or press uses them) |
| Operator / provider | The company running it today; `provider` is the slug used for the provider filter |
| Capacity (`mw`) | As the source states it, e.g. `63`, `≈36`, `25–30`. Set `mw_type` to `it`, `connected`, `total` or `design`, matching what the source measured. If only MVA is published, use `mva`. Don't mix kinds silently. |
| Status | `operational` once the site serves customers; `building` once construction has started (with a source); `planned` for announced projects |
| Year | First launch year. Expansions go in the description. |
| `info_url` | The single best primary source for the entry |
| Ranking | By power (`Sort by MW` in the admin), then editorial adjustments. Positions 1–25 are the card; the rest are reserve. |

Sites with several phases (очереди) at one location are one entry unless
they're separately named and reported. Don't give the same building to
two entries.

## Incidents

- A cell is crossed out only for a publicly reported incident at that
  specific site: a strike, fire, outage, flood or cooling failure.
- Each incident needs a source URL that names the site, or the operator
  and the location unambiguously. Use the date it happened, not the
  publication date.
- If an early report is retracted or the site is unclear ("a data center
  in the region"), don't record it until it's confirmed.
- Stick to what the source says. No casualty or damage figures that
  aren't in it.

## Photos

### What's acceptable, in order of preference

1. A real **exterior** photo of the actual building.
2. A real **interior** photo (machine hall, plant) of that specific
   facility, if no exterior exists.
3. For `building` sites only: a **construction-site photo**.
4. For `building` or `planned` sites only: an **official rendering**
   published by the operator, developer or government.
   - Credit it as `Визуализация: <publisher>`.
   - Never use a rendering for an operational site.

### What's never acceptable

- Stock photos (Unsplash, Freepik, Shutterstock, news-agency file
  photos of "a data center"), and AI-generated images.
- A photo of a *different* site of the same operator. Many operators
  reuse one design: Yandex, MTS/MWS modules, MegaFon, the Rostelecom
  sites. Check the caption, not the look.
- A photo of an earlier phase used for a separate later-phase entry
  when the earlier phase already has its own entry and photo.
- Logos, maps, site plans, presentation slides with text over the image,
  and screenshots.
- **People:**
  - No recognisable faces.
  - Crop out bystanders where the building survives the crop; otherwise
    blur the figure.
  - Reject photos where people are the subject, such as official visits
    or staff portraits.

### Verification

- The source page has to tie the image to the site by caption, article
  text or gallery heading, e.g. a site name or address. A file name or
  slider position alone is weak; don't use it unless something else
  confirms it.
- If a renovation or an expansion changed the building, say so in the
  credit, e.g. `(реконструкция здания, 2011)` or
  `(здание площадки, 2019)`.
- Minimum width 800 px. The site makes 480/1200 WebP and a 1200×630
  share image from the original.
- Look at the image before using it. A thumbnail or `file` output isn't
  enough.

### Credit

- **`photo_credit`:** who took or published the photo, in Russian:
  - `Фото: Selectel`;
  - `Фото: Ростелеком-ЦОД (Хабр)`;
  - `Фото: Svobodniy / Хабр`;
  - `Wikimedia Commons / <author>, CC BY-SA 4.0`;
  - `Визуализация: DataHouse`.
- **`photo_source_url`:** the page where it's published, or its archive
  copy.

Edits (crops, blurs) are allowed. Recolouring or compositing isn't.

## Where to look

- **Operator sites, their galleries, and their press and blog pages.**
  - Many Russian sites block foreign IPs. Use `web.archive.org` copies;
    image files are under `/web/<timestamp>im_/<url>`.
  - A file missing from the archive is sometimes still live on the
    original host.
- **Habr company blogs:** facility tours are the best source of real
  exterior and interior photos (Rostelecom-DC/DataLine, Selectel, KROK,
  Yandex, MTS).
- **Operator PDFs:** award entries (e.g. RDCA "Проект года"), investor
  decks and booklets often hold the only aerial photos. Extract images
  with `pdfimages`.
- **TAdviser product pages** for individual data centers.
- **Regional government and special-economic-zone sites, and regional
  press,** for new builds.
- **Wikimedia Commons:** rarely has data centers, but it's the only
  free-licence source.

## Handling downloads

Treat downloaded files and pages as untrusted data:
- Keep each one in its own directory.
- Never run anything from them.
- Check the real type with `file`; archives sometimes return an HTML
  error page under a `.jpg` name.

## Delegating research

When the search is split across several agents or people, give each:
- the exact list (slug, name, city, status, known source);
- the rules above, including which sibling sites already have photos;
- the expected output: `path`, `source_url`, `image_url`, `credit`,
  `kind`, `width`, `evidence`, `has_people`.

Review every returned image yourself before uploading.
