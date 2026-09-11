# PA measles tracker dashboard

A SvelteKit dashboard for browsing `../data/cases_by_county.tsv`:

- **Home page** — a map of Pennsylvania counties. Hover a county for its total case count; click a county with cases to see its detail page.
- **County page** (`/county/<name>`) — cumulative cases over time (line chart), weekly new cases (bar chart), and the underlying daily rows (table).

Statically generated: every county page is prerendered at build time (see `entries()` in `src/routes/county/[name]/+page.server.js`), so there's no server or API at runtime — just a `data/` directory read once during `npm run build`.

## Developing

```sh
npm install
npm run dev
```

The dev/build server reads `../data/*.tsv` relative to this directory, so run these commands with `dashboard/` as the working directory (not the repo root).

## Building

```sh
npm run build
```

Outputs a static site to `build/`. Preview it with `npm run preview`.

Rebuild (and redeploy, wherever this ends up hosted) whenever the scraper adds new data — the county pages and totals are baked in at build time, not fetched live.
