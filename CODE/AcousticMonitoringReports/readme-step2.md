# Step 2: Build Site Map

**Script:** `Step2_build_site_map.R`
**Type:** Interactive R script (run from RStudio "Source", not `Rscript`)

## Purpose

Standalone script that builds an NPS-style acoustic monitoring site map: basemap imagery, park boundary, monitoring site markers and labels, legend, scale bar, north arrow, and a locator inset — in either portrait or landscape orientation — and saves it as `<PARK_CODE>_SiteMap.png` next to your `SiteMeta.xlsx`.

It's independent of Step 1 (reads only `SiteMeta.xlsx`) and can be re-run any time you want to regenerate or tweak the map — e.g. after adding a new site, or just to try a different basemap style.

## Prerequisites

- A `SiteMeta.xlsx` file (produced by Step 1) with `Site`, `Latitude`, and `Longitude` columns filled in for at least one site.
- Internet access — this script fetches basemap tiles, the park boundary, and (optionally) roads/railroads/cities live from public services.

### Required R packages

```
sf, terra, maptiles, tidyterra, ggspatial, patchwork, ggplot2, openxlsx,
stringr, dplyr, jsonlite, tcltk, osmdata, callr, magrittr, tigris,
rnaturalearth, ggrepel
```

Optional: `shadowtext` (for a crisper text-halo effect on labels/markers; falls back to a manual multi-offset halo if not installed).

**`ggrepel` version note:** label-overlap avoidance (see below) works with any version, but the text-halo effect on repelled labels requires `ggrepel >= 0.9.0`. With an older version, labels will still avoid overlapping each other, just without the halo — update via `install.packages("ggrepel")` if you want it.

## Running it

Run the whole script (Source). It will:

1. Prompt you to select `SiteMeta.xlsx`
2. Try to infer the 4-letter park code from the folder path and ask you to confirm (or type it in if it can't guess)
3. Look up the park boundary from NPS's public boundary service; if that fails, optionally lets you supply a local boundary file, or falls back to a padded box around your site coordinates
4. Fetch a locator-inset context shape (the containing US state, or country if outside the US)
5. **Enter a draw/accept/redraw loop:** draws the map, then asks:
   - *Accept and save this map?* → saves and exits
   - *Zoom OUT to show more area?* → redraws with more padding
   - *Zoom IN to show less area?* → redraws with less padding
   - Declining all three quits without saving

Each redraw re-fetches basemap imagery (and roads/rail/cities, if enabled) for the new extent, so expect a short pause per iteration.

## Configuration

All configuration is at the top of the script (Section 0):

### Layout & basemap
| Option | Default | Purpose |
|---|---|---|
| `map_orientation` | `"landscape"` | `"landscape"` or `"portrait"` |
| `basemap_style` | `"topo"` | `"satellite"` (Esri World Imagery) or `"topo"` (Esri World Topo Map) |
| `show_cities` / `show_roads` / `show_railroads` | `FALSE` | Optional OpenStreetMap overlay layers |
| `city_min_population` | `1000` | Minimum population to label a city/town |
| `road_classes` | motorway/trunk/primary/secondary | OSM `highway=` values to include |
| `osm_timeout_secs` | `25` | Hard per-request timeout for OSM layers (each fails gracefully and is simply omitted, never blocks the map) |
| `osm_overpass_mirrors` | 3 public mirrors | Tried in order if one is slow/rate-limited |

### Site symbology
| Option | Default | Purpose |
|---|---|---|
| `site_symbol` | `"star"` | `"star"`, `"circle"`, `"triangle"`, `"square"`, or `"diamond"` |
| `site_symbol_color` / `site_symbol_size` | `"black"` / `5` | Marker appearance |
| `site_label_color` / `site_label_size` | `"white"` / `3.5` | Site name label appearance |
| `use_label_mask` / `label_mask_color` | `TRUE` / `"black"` | Halo behind labels for legibility over any basemap |
| `use_symbol_mask` / `symbol_mask_color` | `TRUE` / `"white"` | Halo behind markers |

### Site label overlap handling
| Option | Default | Purpose |
|---|---|---|
| `use_label_repel` | `TRUE` | Auto-avoid overlapping site-name labels (see below) |
| `label_repel_max_overlaps` | `Inf` | Never drop a label no matter how crowded the map is |
| `label_repel_force` / `label_repel_force_pull` | `1` / `1` | Repulsion strength vs. pull back toward the true site location |
| `label_repel_box_padding` / `label_repel_point_padding` | `0.3` / `0.3` | Minimum spacing enforced around labels/markers |
| `label_repel_min_segment_length` | `0.4` | Leader lines only drawn if a label moved more than this |
| `label_repel_nudge_y_frac` | `0.02` | Initial "label sits just above its marker" nudge, as a fraction of the current map's y-extent |
| `label_repel_seed` | `42` | Fixed so label layout doesn't shift between identical re-runs |

**Why this matters:** plain ggplot2's `check_overlap=TRUE` (the old behavior) doesn't reposition anything — it silently *drops* whichever label collides with one already drawn, with no visual indication anything went missing. `use_label_repel` switches to `ggrepel`, which nudges overlapping labels apart and draws a thin leader line back to the true site location whenever a label had to move. Only the label text moves — the marker symbol always stays exactly on the true coordinate. Set `label_repel_max_overlaps` lower than `Inf` only if you'd genuinely prefer to drop a few labels over a busier-looking map at an unusually dense site cluster.

### Legend, scale bar, north arrow, locator inset
| Option | Default | Purpose |
|---|---|---|
| `show_legend` / `legend_corner` | `TRUE` / `"bottomleft"` | Compact custom legend (built manually to support the text-based star symbol) |
| `scalebar_corner` | `"bottomright"` | Includes an auto-placed backing panel so it stays legible over any basemap |
| `north_arrow_corner` | `"topright"` | |
| `show_extent_inset` / `extent_inset_corner` / `extent_inset_size` | `TRUE` / `"topleft"` / `0.22` | Small "where is this" locator map (state/country outline + current extent box) |

### Map extent/centering
| Option | Default | Purpose |
|---|---|---|
| `extent_center_on` | `"boundary_and_sites"` | `"boundary_and_sites"`, `"sites"`, or `"boundary"` — see inline comments for multi-unit-park guidance (e.g. Saguaro's East/West districts) |

## What gets produced

`REPORTS/<PARK_CODE>/SitesMeta/<PARK_CODE>_SiteMap.png` — consumed by both Step 3 and Step 4's site-map figure.

## Known quirks / things to verify on your data

- This script is interactive by design (zoom loop, confirmation prompts) — not intended to be run non-interactively.
- The park boundary lookup tries several ArcGIS FeatureServer layers and field names in sequence and applies sanity checks (geometry size, valid centroid) to reject an obviously-wrong match — but it's still a best-effort heuristic against a third-party service, not a guaranteed-correct lookup. Always visually confirm the boundary looks right before accepting a map.
- OSM layers (roads/railroads/cities) depend on public Overpass API mirrors, which can be slow or rate-limited at busy times — if a layer silently doesn't appear, check the console messages; it likely means all three mirrors failed/timed out for that layer, and the map was still built without it (by design, this never blocks the whole map).

