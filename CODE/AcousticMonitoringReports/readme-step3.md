# Step 3: Snapshot Report

**File:** `Step3_snapshot_report.Rmd`
**Type:** R Markdown, knit to Word via `officedown::rdocx_document` (RStudio "Knit", or `rmarkdown::render()`)

## Purpose

A lighter-weight "snapshot" acoustic monitoring report, meant to be produced **before** the full analysis (off-site listening and/or SPLAT) is complete. It uses only automatic sound level meter data — which is available as soon as Step 1 has processed a season's `METRICS_*.txt` files — so it can be shared with a park early, with the understanding that the full comprehensive report (Step 4) will follow once listening analysis is done.

Because it has no sound-source-identification data to work with, it can't calculate the natural ambient sound level (L~Anat~) or present frequency-content-by-source figures the way Step 4 can. Instead, it uses **L~A90~ (the 10th percentile / "quietest" sound level)** as a documented proxy for background/natural conditions, per ANSI/ASA S3/SC1.100-2014.

## Relationship to Step 4

Step 3 and Step 4 are **independent documents** that both read from the same `REPORTS/<PARK_CODE>/` output structure produced by Step 1, and share a substantial amount of *logic* (folder-scope filtering, image aspect-ratio handling, day-count parsing, GSM narrative text, Word style application) — but that logic is currently **duplicated**, not shared via a common sourced file. A fix made in one report's copy of this logic will not automatically apply to the other's. Keep this in mind if you're maintaining both going forward.

Step 3 does **not** include: off-site listening/SPLAT sections, top-noise-source figures, noise-free interval figures, appendices (site photos, listening center detail, trend graphs), or the multi-year table-combining option Step 4 has. It also does not have a "was Listening Center/SPLAT completed" parameter, since by definition those analyses aren't done yet when this report is produced.

## Prerequisites

- Step 1 must have been run for this park (needs `REPORTS/<PARK_CODE>/<order>_<Season>_<Year>/` folders with at least `ambfullsum_*.csv` and `timeabove_*.csv`).
- `REPORTS/<PARK_CODE>/SitesMeta/SiteMeta.xlsx` must exist (also produced by Step 1).
- `template.docx` (Word reference document) in the same folder as this Rmd, with the custom paragraph styles referenced throughout (`sr Title`, `sr Subtitle`, `sr Heading 1/2`, `sr Normal`, `sr Table caption`, `sr Table header`, `sr Table cell`, `sr Figure caption`, `sr Image credit`, `sr Alternate text`, `sr Photo caption`, `sr List Bullet L1`, `sr Literature cited`, `sr Table note`).
- If including the Geospatial Model text (default: yes): a sibling `GSM_CSV/` folder (two levels up) with `LA50_existing_NPS.csv`, `LA50_natural_NPS.csv`, and `LA50_impact_NPS.csv`, containing a row for this park's `UNIT_CODE`.
- A `cover_image.png` placed manually in `REPORTS/<PARK_CODE>/SitesMeta/`.
- A site map — either `<PARK_CODE>_SiteMap.png` (from Step 2) or a fallback `park_geographic_location.png` — in the same `SitesMeta` folder.

### Required R packages

Same list as Step 4 (this report shares the same tooling): `EnvStats, reshape2, ggplot2, ggthemes, pander, plyr, lubridate, readxl, tcltk, svDialogs, tcltk2, tidyverse, vtable, data.table, ggpubr, knitr, readr, sjmisc, janitor, dplyr, DT, tmap, scales, leaflet, shiny, rsconnect, english, kableExtra, statip, magrittr, flextable, officedown, officer, forstringr, ftExtra, glue`.

## Knit parameters

| Parameter | Default | Purpose |
|---|---|---|
| `alpha_code` | `SAGU` | 4-letter park code — **must** match a code in the NPS units list |
| `geoinclude` | `Yes` | Include the Geospatial Model narrative section |
| `folder_scope` | `All available folders` | `"All available folders"` or `"Select specific folders (by order number)"` |
| `order_list` | *(blank)* | Comma-separated order numbers, only used if `folder_scope` is set to the "specific folders" option |

## Report contents

1. Title/subtitle, cover image, author block
2. Introduction, Study Area (site metadata table, site map figure)
3. Methods (Automatic Monitoring, Monitoring Period, Calculation of Metrics — including the L~A90~-as-proxy explanation, sound level examples table)
4. Preliminary Results: existing ambient (L~A50~) and L~A90~ ranges, per-folder percentile levels tables, per-folder time-above tables, frequency content figures, hourly percentile figures
5. Geospatial Model narrative (if `geoinclude = Yes` and data is available for this park)
6. Preliminary Conclusions (placeholder heading — intended for manual authoring)
7. References

Table and figure numbering is automatic, based on how many season/year folders are in scope (respecting `folder_scope`/`order_list`) — Table 1 and Table 2 are static (site metadata, sound level examples), with percentile-levels and time-above tables numbered from Table 3 onward.

## Known quirks / things to verify on your data

- **Percent audibility / noise source data is deliberately absent** from this report by design — this is not a bug, it's the whole point of a snapshot report existing separately from Step 4.
- The `days_summary` and `result_matrix` monitoring-period calculation in this file is a slightly different/independent implementation from the equivalent logic in Step 4 — both should produce the same style of output ("N days across S sites" or a range), but they are not the same code.

