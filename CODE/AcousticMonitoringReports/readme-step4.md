# Step 4: Final Comprehensive Report

**File:** `Step4_final_report.Rmd`
**Type:** R Markdown, knit to Word via `officedown::rdocx_document` (RStudio "Knit", or `rmarkdown::render()`)

## Purpose

Produces the full, publication-formatted NPS acoustic monitoring report: executive summary, methods, complete results (percentile levels, time-above thresholds, frequency content, off-site listening/SPLAT event analysis, noise source audibility), and a configurable set of appendices — with every figure and table auto-numbered based on which sections and appendices are actually included.

This is the terminal step in the pipeline — it reads everything Steps 1 (and optionally 2) produced and assembles it into a single Word document.

## Prerequisites

- Step 1 must have been run for this park, ideally for every season/year you want included in this report.
- `REPORTS/<PARK_CODE>/SitesMeta/SiteMeta.xlsx` must exist.
- `figureList.R` (in the same folder as this Rmd) — provides `run_logic()`, which computes figure numbering for the Site Photos, Geospatial Model, and Listening Center Detail appendices.
- `template.docx` (Word reference document) in the same folder, with the same custom paragraph styles listed in `README_Step3.md`, plus `sr Cover photo credits`.
- A `cover_image.png`, a site map (`<PARK_CODE>_SiteMap.png` or fallback `park_geographic_location.png`), and (if applicable) `listenerimage.png` / `listenerimage_with_splat.png` and `lnatequation.png`, all in `REPORTS/<PARK_CODE>/SitesMeta/`.
- If including the Geospatial Model appendix: a sibling `GSM_CSV/` folder with the same three CSVs as Step 3, plus `modeled_l50.png`, `modeled_l50_natural.png`, and `modeled_l50_impact.png` in `SitesMeta/`.
- If including the Trend Graphs appendix: `REPORTS/<PARK_CODE>/trends/` must exist (produced by Step 1 once 2+ season/year combos exist).

### Required R packages

`EnvStats, reshape2, ggplot2, ggthemes, pander, plyr, lubridate, readxl, tcltk, svDialogs, tcltk2, tidyverse, vtable, data.table, ggpubr, knitr, readr, sjmisc, janitor, dplyr, DT, tmap, scales, leaflet, shiny, rsconnect, english, kableExtra, statip, magrittr, flextable, officedown, officer, forstringr, ftExtra, glue`

## Knit parameters

| Parameter | Default | Purpose |
|---|---|---|
| `alpha_code` | `SAGU` | 4-letter park code — must match a code in the NPS units list |
| `offlisten` | `Yes` | Was Listening Center off-site listening analysis completed? |
| `splat` | `Yes` | Was SPLAT (Sound Pressure Level Annotation Tool) analysis completed? |
| `onlisten` | `No` | Was on-site listening completed? |
| `append1` | `Yes` | Include Site Photos appendix |
| `append2` | `Yes` | Include Geospatial Model appendix |
| `append3` | `Yes` | Include Listening Center Detailed Graphs appendix |
| `append4` | `No` | Include Acoustic Trend Graphs appendix (requires a `trends/` folder — see above) |
| `folder_scope` | `All available folders` | `"All available folders"` or `"Select specific folders (by order number)"` |
| `order_list` | *(blank)* | Comma-separated order numbers, only used with the "specific folders" scope |
| `table_grouping` | `Separate table per season/year` | See **Table Grouping** below |

## Table Grouping

For the Time Above, Executive Summary, and Percentile Levels tables specifically, when a park has accumulated multiple years of the same season, you can choose:

- **Separate table per season/year** (default) — one table per Season+Year combination, as in earlier report versions.
- **Combine years into one table per season** — collapses every folder sharing the same season (e.g. all "Summer" folders regardless of year) into a single table, with a `Year` column (placed immediately after Site Name) distinguishing rows, and the caption's year reference widening into a range (e.g. "2019 - 2023") when more than one year is present.

If a season only has one year of data, both modes produce identical output for that season. Note that the SPLAT Event Counts/Lengths table is **not** affected by this setting — it's always produced one table per site per folder.

## Appendices & auto-lettering

Each of the four appendices (Site Photos, Geospatial Model, Listening Center Detail, Trend Graphs) gets the next available letter in that fixed order, based on which are enabled — e.g. with only Site Photos and Trend Graphs enabled, you'd get "Appendix A: Site Photos" and "Appendix B: Acoustic Trend Graphs" (no gap for the disabled ones). This is computed once at the top of the document and referenced everywhere an appendix is mentioned in the narrative text (e.g. "see Appendix B").

The Trend Graphs appendix additionally requires actual matching trend PNGs to exist for the season(s) currently in scope (respecting `folder_scope`/`order_list`) — if `append4 = Yes` but no matching PNGs are found, the appendix is silently omitted with a console message explaining why, rather than rendering an empty section.

## Report contents (in order)

1. Title/subtitle, cover image, author block
2. Abstract, Acknowledgements, List of Terms/Acronyms
3. Executive Summary — sound level examples table, Time Above tables, Executive Summary table (site/season noise source and ambient level summary)
4. Introduction (NSNSD background, soundscape planning authorities, focal park unit)
5. Study Area — site metadata table, site map figure
6. Methods — Automatic Monitoring, Monitoring Period, Calculation of Metrics, and (if applicable) Off-Site Listening/SPLAT/On-Site Listening methodology sections
7. Results — Frequency content figures, Time Above tables (main report copy), Percentile Levels tables and figures, Event Duration (top noise source figures, and if SPLAT was used, Event Counts/Lengths tables and Noise-Free Interval figures)
8. Conclusions, References
9. Appendices, in the order: Site Photos, Geospatial Model, Listening Center Detail, Trend Graphs (each only if enabled)

## What this pipeline stage fixed, and why it matters if you're extending it

This document accumulated a number of fixes worth knowing about if you're modifying it further:

- **Folder ordering**: `list.dirs()`/`list.files()` sort lexicographically, not numerically — without correction, a park with 10+ order-numbered season folders would have `"10_Fall_2021"` sort before `"2_Winter_2020"`. Fixed once via a numeric sort on `dirs` immediately after it's built, plus an `order_by_folder_num()` helper applied to any recursive multi-path file scan (which doesn't reliably inherit `dirs`'s order).
- **Executive Summary table graceful degradation**: a season/year folder with no Listening Center or SPLAT data legitimately has no `executivesumtab_*.csv` — this is valid, not an error. Such folders are silently excluded from the Executive Summary table and its narrative statistics (via `has_execsum`), while still appearing normally in Time Above and Percentile Levels tables.
- **Table captions and cell/header styling**: flextable's `set_caption(..., word_stylename=...)` does not reliably survive `officedown`'s render path inside a loop — all table captions in this document use `styled_block()` (a Pandoc custom-style fenced-div) instead. Similarly, flextable's `fontsize()`/`bold()`/`padding()` etc. apply direct formatting only, not a named Word style — every table's header/body explicitly sets `word_style = "sr Table header"` / `"sr Table cell"` via `officer::fp_par()`.
- **Image aspect ratio & centering**: `knitr::include_graphics()` with only `out.width` set gets its height from the chunk's `fig.height` default, independent of the image's actual shape, causing distortion. `include_graphics_ar()` reads each PNG's true pixel dimensions from its file header and emits Pandoc image markdown directly with explicit `width=`/`height=`/`fig-align="center"` attributes instead.
- **Column swap in Percentile Levels tables**: `ambfullsum_<season>.csv` is written by Step 1 with columns in the order `Time, SiteID, LA10, LA50, LAnat, LA90` — reading it straight through and labeling column 1 "Site Name" silently swapped Site Name and Time throughout the table. Fixed via an explicit column reorder before renaming.
- **Positional noise-source lookup bug**: the Top-1/Top-2 noise source figure loop used to look up each site's noise source by *position* in a list that only contained entries for sites with at least one detected noise source — a single no-noise site anywhere in the sequence would silently misalign every subsequent site's labeling. Fixed via an explicit `SiteID`-keyed lookup, with sites lacking any noise source skipped entirely (no plot, no "NA" in a filename).
- **`read.csv()` type inference**: a day-count value that happens to look like a plain number (no dash) gets auto-parsed as numeric on read-back regardless of `stringsAsFactors`, which broke `strsplit()`-based parsing for the (common) case where every site agreed on one day count. Fixed via explicit `colClasses` on the relevant `read.csv()` call.

## Known quirks / things to verify on your data

- Verify on a first real render: Word-style application for table captions/headers/cells, image centering via Pandoc's `fig-align` attribute (support for this specifically in the **docx** writer is less universally documented across Pandoc versions than for HTML/LaTeX), and the multi-year table-combining columns when a park has genuinely divergent top-3 noise sources across years (see next point).
- If different years of the same season have different "top 3" noise sources, `table_grouping = "Combine years into one table per season"` will show **all** distinct source columns that appeared across those years in the combined Executive Summary table (with `N/A` for any year/site where a given source wasn't in that year's top 3) — this is structurally correct but can make the table noticeably wider than usual for a park with variable dominant noise sources across seasons.
- `report_content_width_in` (used by the image-centering helper) assumes a 6.5in printable page width (US Letter, 1in margins). If `template.docx` uses different margins, images will still be correctly proportioned but may render at a slightly different absolute size than intended — adjust this one value to match your template.
