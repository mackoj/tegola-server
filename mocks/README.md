# Mock mode

A development server that answers lookups from this folder and from made-up releases, without keys or network, so
the app can be tested against it (D-28).

```sh
scripts/run.sh --mock
```

The script sets `TEGOLA_MOCKS` to `mocks/catalogue.json`. Set it in `.env.local` to use another file. Mock mode
works only in development: a production server refuses `TEGOLA_MOCKS`. It replaces the real sources, and refuses
to start beside their settings (`scripts/run.sh --mock` leaves them out).

The mock providers sit behind the same router as the real ones, so the app gets what a real source would give it:
- the same ranking, merging and import buckets;
- caching (restart to clear it);
- `503` with `Retry-After` on failure;
- App Attest or the debug token on every lookup.

## What it answers

| Asked | Answer |
|---|---|
| A barcode in the catalogue | That release (a UPC-A also matches as its EAN-13) |
| Any other barcode | One made-up release |
| Words close to a catalogue title | Those releases, ranked |
| Any other words | Made-up releases. Most words get one (the import row is **matched**), some two editions (**ambiguous**), a few none (**unknown**) |
| A catalogue number alone | The catalogue's release with it, or nothing |
| A work id | The catalogue's releases of that work, or a made-up work's two editions |

Made-up releases are invented names ("Rocket Quest", "Velvet Horizons"), filled with the type file's fields (music
also gets a tracklist). They keep what the query asked for: the title, the artist or publisher, the year, the
subtype, the region. The same barcode or words always make the same release, on every run and every machine. Ids
look like `mock:<type>:gen:<slug>:<n>`. Every candidate's source is **Mock**.

## Scenarios: the app's other paths

| Barcode | Title | What happens |
|---|---|---|
| `0000000000000` | `unavailable` | `503`, `Retry-After: 30`: the source is down |
| `1111111111111` | `nothing` | No candidates: "no match" |
| `2222222222222` | `slow` | The normal answer, 4 s late |

Titles compare folded: case, accents and punctuation don't matter. A scenario applies to every type.

## The catalogue file

```json
{
  "latencyMs": 150,
  "releases": [
    {
      "type": "music", "id": "ok-computer-cd-gb", "work": "ok-computer",
      "title": "OK Computer", "subtitle": "Radiohead", "year": 1997, "subtype": "cd", "region": "GB",
      "barcodes": ["724385522925"],
      "fields": { "medium": "CD", "label": "Parlophone", "catalogNumber": "7243 8 55229 2 5" },
      "entries": { "tracklist": [{ "position": "1", "title": "Airbag", "duration": "4:44" }] }
    }
  ],
  "scenarios": [
    { "barcode": "0000000000000", "outcome": "unavailable", "retryAfter": 30 },
    { "title": "nothing", "outcome": "nothing" },
    { "title": "slow", "outcome": "slow", "delayMs": 4000 }
  ]
}
```

- **`latencyMs`** (0–5000, default 150): how long every answer takes, so the app's loading states show.
- **`type`**: a type id (`music`, `video-game`, `board-games`, `thing`, or any other the app has).
- **`id` and `work`**: slugs (a-z, 0-9, `-`, at most 60). The server's ids are `mock:<type>:<id>` and
  `mock:<type>:work:<work>`. Releases with the same `work` are one work's editions.
- **`subtitle`**: the spine's subtitle: the artist (music), the platform (video games), the publisher (board
  games), the maker (thing).
- **`subtype`** and **`region`**: as the type file has them (`cd`, `vinyl`, `n64`, `ps1`; `PAL`, `NTSC-U`, `GB`).
- **`barcodes`**: 6–32 letters, digits or `-`. Made-up codes here start with `20`: that's an in-store prefix that's
  never on a product.
- **`fields`**: the type file's keys, with strings or numbers. **`entries`**: list fields such as `tracklist`.
- **`scenarios`**: a `barcode` or a `title`, an `outcome` (`unavailable`, `nothing`, `slow`), and `retryAfter`
  (1–3600 s) or `delayMs` (0–20000).

A file that can't be read or breaks a rule stops the server at start-up, with where the problem is.
`MockCatalogueTests` checks this file the same way.
