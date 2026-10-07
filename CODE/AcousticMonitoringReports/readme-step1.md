# Step 1: Parse & Export Acoustic Metrics

**Script:** `Step1_acoustic_parse_export.R`
**Type:** Interactive R script (run from RStudio "Source", not `Rscript`)

## Purpose

Takes raw `METRICS_*.txt` files (produced by the Acoustic Monitoring Toolbox for one or more monitoring sites) and:

1. Lets you browse to a project folder and pick which metrics files to process
2. Fixes a known formatting bug in some metrics files (a missing tab before the `Lnat` column)
3. Detects which season(s), and which analysis types (Listening Center and/or SPLAT), each file contains
4. Maintains a persistent Season/Year → Order Number lookup per park, so report folders and figure/table numbering stay consistent across repeated runs. Order Number represents the sequence of deployment.
5. Exports one folder of CSVs and PNGs per Season+Year combination into `REPORTS/<PARK_CODE>/<order>_<Season>_<Year>/`, with hourly and frequency-content plot y-axes auto-scaled to each site's own data by default
6. Builds/updates a per-park `SiteMeta.xlsx` (site IDs, monitoring date ranges, and optionally auto-filled Latitude/Longitude)
7. Builds a "quick-review" PDF for each Season+Year folder — a captioned, client-ready preview of every table and figure produced for that folder, led by the SiteMeta table
8. Once 2+ Season+Year combinations exist for a park, builds multi-year trend graphs (trend graphs need review and are primarily for data exploration at this point)

This script is the foundation of the whole pipeline — Steps 2, 3, and 4 all read the folder structure and files it produces.

## Prerequisites

- **`readMetrics.r`** — you'll be prompted to browse to this file. Contains the low-level parser for each metrics-file section type.
- **`sourceid.rds`** — you'll be prompted to browse to this file. A lookup table mapping numeric sound source IDs to human-readable descriptions/categories.
- A project folder containing one or more `METRICS_*.txt` files, organized however you like (this step recursively scans for them). This allows flexibility in multiple data management strategies but created with current NSNSD data management practices in mind: PARK > Deployment file structure the user would navigate to the 'PARK' folder 
- A `MAPS_IMAGES/COMMON/` folder (two levels up from this script) containing shared reference PNGs to be copied into each park's `SitesMeta` folder.
- (Optional) An export from the NSNSD Deployment Locations report from the Acoustic Monitoring metadata database (CSV, XML, or MHTML — CSV strongly recommended) if you want Latitude/Longitude auto-filled in `SiteMeta.xlsx`.

### Required R packages

```
reshape2, ggplot2, ggthemes, plyr, lubridate, tidyverse, data.table, readr,
sjmisc, janitor, dplyr, scales, english, rlist, jsonlite, tcltk, openxlsx,
rvest, httr, xml2, png, gridExtra
```
Installed/loaded automatically on first run if missing. `rstudioapi` is used opportunistically (for cleaner file/folder dialogs) but isn't a hard requirement — the script falls back to `tcltk`/base R dialogs. `png` and `gridExtra` are used only by the quick-review PDF feature (image rendering and table layout, respectively).

## Running it

Open the script in RStudio and run the whole thing (Source), or select it in chunks if you want to inspect intermediate state. It will prompt you, in order, for:

1. `readMetrics.R` location
2. `sourceid.rds` location
3. The project folder containing your `METRICS_*.txt` files
4. Which of the metrics files found (a checklist) to include in this run
5. **If** any new Season/Year combinations are found: fills in a `<PARK_CODE>_season_order_lookup.csv` and opens it for you to assign Order numbers (e.g. "this park's first-ever deployment = 1"), then waits for you to save/close it before continuing
6. **If** `build_sitemeta` is enabled (default): the parent folder containing this park's NVSPL deployment folders (to auto-derive monitoring date ranges) — you can Cancel this if you don't have access to it right now
7. **If** `use_deployment_locations_lookup` is enabled (default): a Deployment Locations export file, to auto-fill Latitude/Longitude
8. `SiteMeta.xlsx` opens for you to review/fill in remaining fields (Site Name, Vegetation, Wilderness, Elevation, and Latitude/Longitude if not auto-filled) — save and close, then return to R and press Enter

After that, it runs unattended: one pass per Season+Year combination, writing all outputs and (if enabled) that folder's quick-review PDF, then (if applicable) building trend graphs.

## Handling files with the same name (multi-file-per-season exports)

Some workflows export one metrics file **per park+year** (e.g. `METRICS_2022_ANDE001.txt`, containing every season for that site/year); others export **one file per season** (e.g. two separate files for the same site+year, one per season, which can end up with identical or near-identical filenames depending on the export tool). This script supports both:

- The file year/site are parsed from the filename using a pattern that tolerates any number of underscores between `METRICS` and the year (e.g. both `METRICS_2022_SITE.txt` and `METRICS__2022_SITE.txt` work). Occasionally AMT will not append the year and in these cases the user will need at add the year between `METRICS` and `SITE`.
- If two selected files share an identical basename (common with the one-file-per-season export style, where files for different seasons can land in different folders but keep the same name), the file-selection checklist automatically appends each file's parent folder name to disambiguate them — e.g. `METRICS__2022_ANDE002.txt  [Summer_2022]` vs. `METRICS__2022_ANDE002.txt  [Winter_2022]` — so you can tell them apart and select them independently.

If a filename can't be parsed for a 4-digit year at all, you'll get a loud warning listing the offending file(s), and they'll be excluded from processing rather than silently disappearing.

## Configuration

All configuration is at the top of the script (Section 0):

| Option | Default | Purpose |
|---|---|---|
| `plottitle` | `TRUE` | Include titles on generated plots |
| `plotHRDBA` / `plotTRUNCDBA` / `plotFREQDBA` / `plotCONTOUR` | `TRUE` | Which base-graphics plot types to generate |
| `plotAUTO_Y` | `TRUE` | Auto-scale the y-axis of hourly (DBAvHR/DBTvHR) and frequency-content (SPLvFREQ) plots to each site/season's own data, instead of using fixed limits for every site. Recommended when comparing sites/parks with very different sound levels, since one fixed range can't comfortably fit both a quiet and a loud site. Set to `FALSE` to fall back to the fixed `yMaxHr`/`yMinHr`/`yMaxHz`/`yMinHz` limits below for every plot. |
| `autoscale_pad_frac` | `0.15` | Only used when `plotAUTO_Y` is `TRUE`. Padding added above/below each plot's actual data range, as a fraction of that range (minimum 1.5 dB), before rounding outward to the nearest multiple of 3. Increase for more breathing room around the data, decrease to crop tighter to it. |
| `yMaxHr`/`yMinHr`/`yMaxHz`/`yMinHz` | various | Fixed y-axis limits for hourly/frequency plots — only used when `plotAUTO_Y` is `FALSE` |
| `tabfix_scope` | `"day_night"` | Scope of the missing-tab-before-Lnat fix — `"any"` or `"day_night"` (only Day/Night rows) |
| `copy_common_images` | `TRUE` | Copy shared reference PNGs from `MAPS_IMAGES/COMMON/` into each park's `SitesMeta` folder |
| `build_sitemeta` | `TRUE` | Build/update `SiteMeta.xlsx` from NVSPL deployment folders |
| `prompt_open_sitemeta` | `TRUE` | Open `SiteMeta.xlsx` for manual review/editing before finishing |
| `use_deployment_locations_lookup` | `TRUE` | Attempt to auto-fill Lat/Long from a Deployment Locations export |
| `deployment_locations_source` | `"prompt"` | `"prompt"` (browse to a file) or `"atomsvc_live"` (experimental live OData fetch, falls back to `"prompt"` on failure) |
| `build_trends` | `TRUE` | Build multi-year trend graphs once enough data exists |
| `trend_min_combos` | `2` | Minimum Season+Year combinations required before trends are built |
| `trend_top_n_sources` | `5` | For event-count/length trends, how many top noise sources to plot |
| `build_quick_pdf` | `TRUE` | Build a captioned "quick-review" PDF for each Season+Year folder once its CSVs/PNGs are written |
| `quick_pdf_width` / `quick_pdf_height` | `11` / `8.5` | Page size (inches) for the quick-review PDF — defaults to landscape US Letter |
| `quick_pdf_table_fontsize` | `7` | Base font size for table pages in the quick-review PDF |
| `quick_pdf_max_rows_per_page` | `25` | Tables longer than this are split across multiple pages, each labeled with its row range, so nothing is silently cut off |

## What gets produced

Per Season+Year folder (`REPORTS/<PARK_CODE>/<order>_<Season>_<Year>/`):

- `ambfullsum_<season>.csv` — day/night percentile sound levels per site
- `impactlisteningarea_<season>.csv` — noise impact (dB) and Listening Area Reduction (%), only if Listening Center or SPLAT data exists for that folder
- `timeabove_<season>.csv` — percent time above 35/45/52/60 dB thresholds, full range and ANS-weighted
- `executivesumtab_<season>.csv` — combined summary table (only if Listening Center or SPLAT data exists)
- `analysisdays_<season>.csv` — number of days analyzed by Listening Center / SPLAT, extracted directly from each metrics file's own header line (used by Step 4's Methods section text)
- Per-site PNGs: frequency content, hourly percentile levels, contour plots, top-1/top-2 noise source bar charts, all-source detail/category bar charts
- If SPLAT data present: per-site event counts/lengths CSVs, noise-free interval CSVs, and noise-free interval time series PNGs (showing median and mean NFI by hour)
- **If `build_quick_pdf` is enabled:** `<PARK_CODE>_<order>_<Season>_<Year>.pdf` — a single PDF leading with the SiteMeta table, then every CSV in the folder rendered as a numbered, captioned table and every PNG as a numbered, captioned figure. Captions are adapted from the Step 3 snapshot report's own table/figure language, so this reads like a lightweight preview of that report rather than a bare file listing. Intended as a quick, no-text-review-needed deliverable you can hand to a client between getting raw data back and producing a full Step 3 or Step 4 report.

Once 2+ Season+Year combos exist: `REPORTS/<PARK_CODE>/trends/<Season>/<site>_trend_<Metric>.png` for ambient levels, time-above thresholds, impact/listening area reduction, noise-free interval, and top-source event counts/lengths.

Also updates: `REPORTS/<PARK_CODE>/<PARK_CODE>_season_order_lookup.csv` and `REPORTS/<PARK_CODE>/SitesMeta/SiteMeta.xlsx`.

## Known quirks / things to verify on your data

- **Top-1/top-2 noise source plots are skipped (not generated with an "NA" filename) for any site with zero detected noise-category sources** — this is intentional, not a bug, but worth knowing if you notice a site missing these two PNGs while other sites have them.
- The noise-free interval plots show **median (50th percentile) and mean only** — earlier versions also plotted 90th/10th percentile lines; this was intentionally simplified.
- `readMetrics.r`'s `$n` (sample count) field returns `NA` for `LLDetail`/`LLCat` metric types, since its extraction regex expects an `"hr"` suffix that those sections' headers don't have (they use `"days"` instead). This is currently harmless — that field isn't used downstream in this script — but is worth knowing if you build something new against `readMetrics()` that relies on it for those two types.
- `sec_to_mmss()` (used for the noise-free interval plot's y-axis) is defined independently in this script and again in `Step4_final_report.Rmd`. They aren't shared code, just the same small conversion needed in two places — a fix to one won't propagate to the other.
- **Auto-scaled y-axes (`plotAUTO_Y`) mean the same metric can appear on a different axis range from one plot to the next** — this is the point (it keeps a quiet site from being crushed into a few pixels by a loud site's range), but it also means you can no longer visually compare two plots' steepness/magnitude at a glance just by eyeballing their shapes side by side if their axis ranges differ. Set `plotAUTO_Y <- FALSE` if you need a consistent axis across a specific set of sites for direct visual comparison.
- **The quick-review PDF is the least-verified feature in this script** — its page layout relies on `grid` viewport math (for scaling tables/images to fit the page and reserving space for wrapped captions) that hasn't been exhaustively tested against every possible table shape or caption length. Build one quick-review PDF and look through it before relying on it for an actual client deliverable. In particular, check that very long captions haven't crowded the table/figure below them, and that very wide tables haven't been scaled down to the point of being hard to read.
- The quick-review PDF's SiteMeta table is pulled from the park's shared `SiteMeta.xlsx` (not something computed per folder), so it will be **identical across every Season+Year folder's PDF for a given park** — this is intentional, so each PDF is self-contained, but means updates to `SiteMeta.xlsx` (e.g. filling in Latitude/Longitude later) won't retroactively update PDFs already built before that edit; rerun the folder(s) you want refreshed.
