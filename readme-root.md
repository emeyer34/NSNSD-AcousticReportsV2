# NPS Acoustic Monitoring Report Pipeline

A four-step R/R Markdown pipeline for processing acoustic monitoring data (collected via NPS Natural Sounds and Night Skies Division protocols) into finished Word reports that are formatted to NPS Science Report Series standards, complete with site maps, summary tables, figures, and multi-year trend graphs.

The pipeline is designed around a single park's monitoring data at a time, accumulating additional seasons/years of data over repeated runs, and producing an increasingly complete set of reports and figures as more data comes in.

## Pipeline overview

| Step | Script | Purpose |
|---|---|---|
| 1 | `Step1_acoustic_parse_export.R` | Parses raw `METRICS_*.txt` files (produced by the Acoustic Monitoring Toolbox), exports per-season/year CSVs and PNG figures, builds/updates `SiteMeta.xlsx`, and (once 2+ seasons exist) builds multi-year trend graphs that can be optionally used. |
| 2 | `Step2_build_site_map.R` | Standalone script that builds a styled NPS-format site map (basemap imagery, park boundary, monitoring site markers/labels, legend, scale bar, locator inset) from `SiteMeta.xlsx`. This is an optional step and could be used as an alternative to a preferred program such as ArcGIS|
| 3 | `Step3_snapshot_report.Rmd` | A lighter-weight, pre-analysis "snapshot" report, knittable as soon as automatic sound level monitoring data exists — before off-site listening/SPLAT analysis is complete — using L~A90~ as a proxy for natural ambient sound level. |
| 4 | `Step4_final_report.Rmd` | The full, publication-formatted acoustic monitoring report: executive summary, methods, results (with all figures/tables auto-numbered), and optional appendices (site photos, geospatial model, listening center detail, multi-year trend graphs). |

Each step has its own detailed `README_StepN.md` in this repository — start there for setup, configuration, and troubleshooting specific to that step.

## Typical workflow

1. Run **Step 1** against a folder of `METRICS_*.txt` files for a park's completed monitoring season. This produces a `REPORTS/<PARK_CODE>/<order>_<Season>_<Year>/` folder full of CSVs and PNGs, and updates `REPORTS/<PARK_CODE>/SitesMeta/SiteMeta.xlsx` with that season's site metadata.
2. Fill in `Latitude`/`Longitude` (and optionally `Site Name`, `Vegetation`, `Wilderness`, `Elevation`) in `SiteMeta.xlsx` if Step 1 didn't already auto-fill them from a Deployment Locations export from the Acoustic Monitoring metadata database.
3. Run **Step 2** to generate `REPORTS/<PARK_CODE>/SitesMeta/<PARK_CODE>_SiteMap.png`, iterating on zoom/orientation/basemap until you're happy with it.
4. (Optional, and available before off-site listening/SPLAT analysis is complete) knit **Step 3** for a quick pre-analysis snapshot report using automatic sound level data alone.
5. Repeat Steps 1–3 for each additional season/year of data as it becomes available.
6. Once you have all the seasons you want to report on, and off-site listening/SPLAT analysis is complete, knit **Step 4** to produce the final Word report.

## Repository structure

```
├── README.md                          <- you are here
├── README_Step1.md
├── README_Step2.md
├── README_Step3.md
├── README_Step4.md
├── Step1_acoustic_parse_export.R
├── Step2_build_site_map.R
├── Step3_snapshot_report.Rmd
├── Step4_final_report.Rmd
├── figureList.R                       <- required by Step 4 (figure/appendix numbering helper)
├── readMetrics.r                      <- required by Step 1 (metrics file parser)
├── sourceid.rds                       <- required by Step 1 (sound source ID lookup table)
└── template.docx                      <- required by Steps 3 and 4 (Word reference document / styles)
```

## Output structure (produced by Steps 1 and 4, read by Steps 2–4)

```
REPORTS/
└── <PARK_CODE>/
    ├── <PARK_CODE>_season_order_lookup.csv    <- maps Season+Year -> Order number
    ├── SitesMeta/
    │   ├── SiteMeta.xlsx                      <- one row per site (Site, Dates, Lat/Long, etc.)
    │   ├── <PARK_CODE>_SiteMap.png             <- produced by Step 2
    │   ├── cover_image.png                     <- supplied manually
    │   ├── listenerimage.png / listenerimage_with_splat.png
    │   ├── lnatequation.png
    │   ├── modeled_l50*.png                    <- Geospatial Sound Model appendix figures
    │   └── ... other common reference images
    ├── trends/
    │   └── <Season>/
    │       └── <site>_trend_<Metric>.png       <- produced by Step 1 once 2+ years exist
    └── <order>_<Season>_<Year>/
        ├── ambfullsum_<season>.csv
        ├── executivesumtab_<season>.csv
        ├── timeabove_<season>.csv
        ├── impactlisteningarea_<season>.csv
        ├── analysisdays_<season>.csv
        ├── <site>_<season>_SPLvFREQ.png
        ├── <site>_<season>_DBAvHR.png
        ├── <site>_<season>_<src1>_<src2>PercentAud_top1.png / top2.png
        ├── SPLAT_<season>_EventCountsLengths_<site>.csv   <- if SPLAT data present
        ├── SPLAT_<season>_NoiseFreeInterval_<site>.csv    <- if SPLAT data present
        ├── <site>_<season>_NFI_timeseries.png             <- if SPLAT data present
        └── ... other per-site/season CSVs and PNGs
```

Both `Step3_snapshot_report.Rmd` and `Step4_final_report.Rmd` also read from a sibling `GSM_CSV/` folder (two levels up from the report, alongside `REPORTS/`) containing `LA50_existing_NPS.csv`, `LA50_natural_NPS.csv`, and `LA50_impact_NPS.csv` — NPS's Geospatial Sound Model outputs, used for the optional Geospatial Model section/appendix in each report.

## Requirements

- **R** (developed against a recent 4.x release)
- **RStudio** recommended (Steps 1 and 2 use `rstudioapi` where available for smoother file/folder dialogs, with `tcltk` fallbacks)
- **Pandoc**, bundled with RStudio, required for knitting Step 3/4 to Word
- Each step lists its own required R packages at the top of the script/Rmd — see the individual READMEs for the full list and any package-specific notes (e.g. `ggrepel` version requirements in Step 2).

## Known limitations across the pipeline

- Steps 1 and 2 are interactive (file-picker dialogs, zoom/accept prompts) and are written to be run from an interactive R session (e.g. RStudio "Source"), not via `Rscript` from the command line. Users will need to source from save to initiate script.
- Steps 3 and 4's Word-style application (table headers/cells/captions, image centering) depends on specific named styles existing in `template.docx` with those exact style IDs (e.g. `sr Table caption`, `sr Table header`, `sr Table cell`, `sr Figure caption`, `sr Normal`). If you're adapting this pipeline to a different template, expect to revisit those style references.
- Image insertion in Steps 3 and 4 assumes **PNG** input (the aspect-ratio-preserving image helper reads PNG-specific file header bytes) — other formats (e.g. JPEG cover images) would need a different dimension-reading approach.
- Step 3 and Step 4 currently duplicate a fair amount of logic (folder-scope filtering, day-count parsing, GSM narrative text, image-centering helpers) rather than sharing it via a common sourced file. This isn't a bug, but is worth knowing if you fix something in one report and expect it to propagate to the other automatically — it won't.

### Public domain

This project is in the worldwide [public domain](LICENSE.md):

> This project is in the public domain within the United States,
> and copyright and related rights in the work worldwide are waived through the
> [CC0 1.0 Universal public domain dedication](https://creativecommons.org/publicdomain/zero/1.0/).
>
> All contributions to this project will be released under the CC0 dedication.
> By submitting a pull request, you are agreeing to comply with this waiver of copyright interest.

