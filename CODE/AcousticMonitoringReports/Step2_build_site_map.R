#########################################################################
#
#  Step2_AcousticSiteMap.R
#
#  Standalone script: builds an NPS-style acoustic monitoring site map.
#
#    1) Prompts you to select a SiteMeta.xlsx file (Site/Latitude/Longitude)
#    2) Looks up the park boundary from NPS's public boundary service by
#       park code (auto-detected from the SiteMeta.xlsx path, or typed in)
#    3) Falls back to a padded box around your site coordinates if the
#       boundary lookup fails for any reason - the map still gets built
#    4) Draws basemap imagery (satellite or topo) + optional roads/
#       railroads/cities + boundary + site markers/labels + legend,
#       styled like the standard NPS acoustic monitoring map template,
#       in portrait or landscape orientation
#    5) Lets you accept, zoom in, or zoom out via simple y/n prompts,
#       redrawing each time, until you're happy with the extent
#    6) Saves <park_code>_SiteMap.png next to the SiteMeta.xlsx file
#
#  This script is independent of Step2_AcousticReport_ParseExport.R and
#  can be re-run any time you want to regenerate or tweak the map.
#
#########################################################################

## ---------------------------------------------------------------------
## 0. CONFIG
## ---------------------------------------------------------------------

map_orientation <- "landscape"   # "landscape" or "portrait"

## "satellite" -> Esri World Imagery (aerial photo, matches original templates)
## "topo"      -> Esri World Topo Map (contour lines, roads, shaded relief)
basemap_style <- "topo"

show_cities  <- FALSE   # label nearby towns/cities (via OpenStreetMap)
show_roads   <- FALSE   # draw major roads (via OpenStreetMap)
show_railroads <- FALSE # draw railroads (via OpenStreetMap)

city_min_population <- 1000   # only label places with at least this population (avoids tiny hamlets cluttering the map)
road_classes <- c("motorway", "trunk", "primary", "secondary")  # OSM highway= values to include; add "tertiary" for more detail

osm_timeout_secs <- 25   # hard timeout per OSM (Overpass API) request - if exceeded, that layer is skipped rather than hanging
osm_overpass_mirrors <- c(
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.openstreetmap.ru/api/interpreter"
)  # tried in order; if one is rate-limited/slow, the next is tried before giving up on that layer

## -- Site symbology ------------------------------------------------------
## "star", "circle", "triangle", "square", or "diamond"
site_symbol <- "star"
site_symbol_color <- "black"   # fill color of the marker (for star: the star's own color)
site_symbol_size  <- 5         # roughly comparable in visual weight across symbol types

site_label_color <- "white"
site_label_size  <- 3.5

## Mask/halo: a contrasting outline drawn behind labels/symbols so they
## stay legible regardless of what's underneath them on the basemap
## (satellite imagery in particular can be light or dark in unpredictable
## places). Set to FALSE to disable and get plain text/markers.
use_label_mask  <- TRUE
label_mask_color <- "black"

use_symbol_mask  <- TRUE
symbol_mask_color <- "white"

## -- Site label overlap handling ------------------------------------------
## Site NAME labels can end up overlapping when monitoring sites sit close
## together - a frequent occurrence at parks with several nearby
## deployments. Plain ggplot2's check_overlap=TRUE (the previous
## behavior) does not reposition anything: it SILENTLY DROPS whichever
## label collides with one already drawn, in whatever order the data
## happens to be in, giving no visual indication a label went missing.
##
## use_label_repel = TRUE switches the SITE NAME text (not the marker
## symbol - the star/point always stays exactly on the true coordinate;
## only its accompanying label is free to move) to ggrepel, which
## automatically nudges overlapping labels apart and draws a thin leader
## line back to the true site location whenever a label had to move to
## avoid a collision. Falls back to the original static/check_overlap
## placement if ggrepel isn't installed or this is set to FALSE.
use_label_repel <- TRUE

## Maximum overlaps ggrepel will tolerate before EXCLUDING a label
## entirely - its own separate safety valve, distinct from the old
## check_overlap behavior. Inf means a label is never dropped no matter
## how crowded the map gets, which is appropriate for the site counts
## typical of NPS acoustic monitoring deployments (usually well under a
## few dozen per park). Lower this only if an unusually dense site
## cluster makes you prefer dropping a few labels over a busier map.
label_repel_max_overlaps <- Inf

label_repel_force <- 1        # repulsion strength between overlapping labels
label_repel_force_pull <- 1   # attraction strength pulling a label back toward its own site
label_repel_box_padding <- 0.3    # (lines) minimum gap enforced around each label's text
label_repel_point_padding <- 0.3  # (lines) minimum gap enforced around each site's marker

## Leader lines connect a label back to its site whenever the label had
## to move more than this distance (in "lines", same units as the
## box/point padding above) to avoid a collision. Segments shorter than
## this are omitted entirely, so labels that didn't need to move don't
## get a distracting line for a barely-there nudge.
label_repel_min_segment_length <- 0.4
label_repel_segment_color <- NULL  # NULL -> falls back to label_mask_color below
label_repel_segment_alpha <- 0.8

## Initial nudge (as a FRACTION of the map's current y-extent, so it
## scales sensibly whether you're zoomed in tight or all the way out)
## applied before ggrepel's repulsion takes over - keeps the default
## "label sits just above its marker" look for sites with no conflicts,
## similar in spirit to the previous vjust=-1.2 static placement.
label_repel_nudge_y_frac <- 0.02

## NULL lets ggrepel use its own built-in default halo thickness for the
## bg.color effect below; set a number (ggrepel's own bg.r units) to
## override it.
label_repel_bg_r <- NULL

## Fixed so the label layout doesn't shift between an unrelated re-run of
## the script at the same settings - ggrepel's placement search has a
## randomized component internally.
label_repel_seed <- 42

show_legend <- TRUE
legend_corner <- "bottomleft"   # "topleft", "topright", "bottomleft", "bottomright"
legend_bg_color <- "white"
legend_border_color <- "black"
legend_text_color <- "black"

scalebar_corner <- "bottomright"   # "topleft", "topright", "bottomleft", "bottomright"
scalebar_text_color <- "black"
scalebar_bg_color <- NA

north_arrow_corner <- "topright"   # "topleft", "topright", "bottomleft", "bottomright"

show_extent_inset <- TRUE   # small locator map showing where the main map sits within the state/region
extent_inset_corner <- "topleft"   # pick a corner not already used by legend/scalebar/north arrow
extent_inset_size <- 0.22          # width as a fraction of the map panel (height follows the inset's own aspect ratio)
extent_inset_bg_color <- "white"
extent_inset_border_color <- "black"
extent_inset_fill_color <- "grey85"      # fill for the state/region context shape
extent_inset_box_color <- "red"          # color of the rectangle showing current map extent
extent_inset_label_color <- "black"      # color of the state/country name text on the inset

## What determines the map's center/extent (independent of what still gets
## DRAWN - the boundary is always drawn if available, regardless of this
## setting). Useful for multi-unit parks (e.g. Saguaro's East/West
## districts) where the full boundary's centroid falls far from where your
## actual monitoring sites are.
##   "boundary_and_sites" - (default) frame to fit both the full boundary
##                          and all sites. Can push sites off-center for
##                          multi-unit parks if monitoring only happens in
##                          one unit.
##   "sites"              - frame to fit only the site locations, with
##                          generous padding. The boundary still draws
##                          wherever it falls, even if partially or fully
##                          outside the frame.
##   "boundary"            - frame to fit only the boundary polygon,
##                          ignoring site locations for framing purposes
##                          (sites still draw, but may fall outside frame
##                          if they're outside the boundary).
extent_center_on <- "boundary_and_sites"

## ---------------------------------------------------------------------
## 1. PACKAGES
## ---------------------------------------------------------------------

packages <- c("sf", "terra", "maptiles", "tidyterra", "ggspatial", "patchwork",
              "ggplot2", "openxlsx", "stringr", "dplyr", "jsonlite", "tcltk",
              "osmdata", "callr", "magrittr", "tigris", "rnaturalearth", "ggrepel")

lapply(packages, function(pkg) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
})

## Optional - enables crisp halo/mask text (geom_shadowtext). Falls back to
## a manual multi-offset halo effect if this isn't available, so it's not
## a hard requirement.
have_shadowtext <- requireNamespace("shadowtext", quietly = TRUE)
if (!have_shadowtext) {
  message("Package 'shadowtext' not found - label masks will use a manual fallback effect. ",
          "Install with install.packages('shadowtext') for crisper text halos.")
}

## ggrepel is used specifically for the site NAME label layer (see
## use_label_repel above) - required for that feature, but the rest of
## the script (including the star-glyph marker halo via shadowtext) does
## not depend on it. bg.color/bg.r (the halo effect for repelled text)
## requires ggrepel >= 0.9.0; older installs still get overlap-avoidance,
## just without the halo.
have_ggrepel <- requireNamespace("ggrepel", quietly = TRUE)
have_ggrepel_bg <- have_ggrepel && tryCatch(utils::packageVersion("ggrepel") >= "0.9.0", error = function(e) FALSE)
if (use_label_repel && !have_ggrepel) {
  warning("Package 'ggrepel' not found but use_label_repel is TRUE - install.packages('ggrepel') for automatic label-overlap handling. Falling back to plain (possibly overlap-dropped) label placement for this run.")
  use_label_repel <- FALSE
}
if (use_label_repel && use_label_mask && have_ggrepel && !have_ggrepel_bg) {
  message("Installed 'ggrepel' version is older than 0.9.0 - text halo (bg.color) is not supported by that version. ",
          "Labels will still auto-avoid overlapping each other, just without the halo effect. Run install.packages('ggrepel') to update and regain it.")
}

## ---------------------------------------------------------------------
## 2. HELPERS: popups, safe save, park name lookup, OSM layers, symbology
## ---------------------------------------------------------------------

notify <- function(message_text, title = "Acoustic Site Map") {
  message("\n[", title, "] ", message_text)
  shown <- FALSE
  if (requireNamespace("tcltk", quietly = TRUE)) {
    shown <- tryCatch({
      tcltk::tkmessageBox(title = title, message = message_text, type = "ok", icon = "info")
      TRUE
    }, error = function(e) FALSE)
  }
  if (!shown && .Platform$OS.type == "windows") {
    tryCatch(utils::winDialog(type = "ok", message_text), error = function(e) NULL)
  }
  invisible(NULL)
}

ask_yes_no <- function(prompt_text) {
  repeat {
    cat(prompt_text, " [y/n]: ", sep = "")
    resp <- tolower(trimws(readline()))
    if (resp %in% c("y", "yes")) return(TRUE)
    if (resp %in% c("n", "no")) return(FALSE)
    cat("Please type y or n.\n")
  }
}

safe_ggsave <- function(path, plot, ...) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tryCatch(
    ggsave(path, plot = plot, ...),
    error = function(e) {
      warning(sprintf("Could not save plot to:\n  %s\nReason: %s", path, conditionMessage(e)), call. = FALSE)
    }
  )
}

get_park_name <- function(unit_code) {
  npsunits <- tryCatch(
    jsonlite::fromJSON("https://irmaservices.nps.gov/Unit/v2/api/?format=json"),
    error = function(e) NULL
  )
  if (is.null(npsunits)) return(unit_code)
  hit <- npsunits[npsunits$UnitCode == unit_code, ]
  if (nrow(hit) == 0) return(unit_code)
  hit$FullName[1]
}

## -- Symbol lookup: pch shape codes for point-based markers. Star is
## handled separately as text (unicode star glyph), since pch has no true
## filled 5-point star.
symbol_pch_lookup <- c(circle = 21, triangle = 24, square = 22, diamond = 23)

site_symbol <- tolower(site_symbol)
if (!site_symbol %in% c("star", names(symbol_pch_lookup))) {
  warning("site_symbol '", site_symbol, "' not recognized - defaulting to 'star'.")
  site_symbol <- "star"
}

## -- Halo-text helper: draws a text label multiple times with small pixel
## offsets in the mask color, then once more in the main color on top -
## a manual approximation of a text stroke/halo, used when the
## 'shadowtext' package isn't available. Used for the star-glyph MARKER
## (always fixed at its true coordinate) and as the fallback site-label
## renderer when use_label_repel is FALSE/unavailable - see
## add_site_labels() below for the normal (repelling) site-label path.
add_halo_text <- function(plot, data, x, y, label_col, color, mask_color, size, use_mask, ...) {
  if (use_mask && have_shadowtext) {
    plot + shadowtext::geom_shadowtext(
      data = data, aes(x = .data[[x]], y = .data[[y]], label = .data[[label_col]]),
      color = color, bg.color = mask_color, size = size, ...
    )
  } else if (use_mask) {
    offsets <- expand.grid(dx = c(-1, 0, 1), dy = c(-1, 0, 1))
    offsets <- offsets[!(offsets$dx == 0 & offsets$dy == 0), ]
    px <- size * 0.03  # small offset scaled roughly to text size
    for (i in seq_len(nrow(offsets))) {
      plot <- plot + geom_text(
        data = data,
        aes(x = .data[[x]] + offsets$dx[i] * px, y = .data[[y]] + offsets$dy[i] * px, label = .data[[label_col]]),
        color = mask_color, size = size, ...
      )
    }
    plot + geom_text(data = data, aes(x = .data[[x]], y = .data[[y]], label = .data[[label_col]]),
                     color = color, size = size, ...)
  } else {
    plot + geom_text(data = data, aes(x = .data[[x]], y = .data[[y]], label = .data[[label_col]]),
                     color = color, size = size, ...)
  }
}

## -- Site marker layer: adds either a haloed star (text) or a haloed
## point shape (pch 21-24, which support separate border/fill colors -
## the "border" doubles as the mask/halo here). Always drawn EXACTLY at
## each site's true coordinate, regardless of how the accompanying NAME
## label (see add_site_labels() below) ends up being positioned.
add_site_markers <- function(plot, data, x, y, color, mask_color, size, use_mask, symbol) {
  if (symbol == "star") {
    plot <- add_halo_text(plot, data, x, y, label_col = "star_glyph",
                          color = color, mask_color = mask_color, size = size,
                          use_mask = use_mask, fontface = "plain")
  } else {
    pch <- symbol_pch_lookup[[symbol]]
    plot <- plot + geom_point(
      data = data, aes(x = .data[[x]], y = .data[[y]]),
      shape = pch, size = size, fill = color,
      color = if (use_mask) mask_color else color,
      stroke = if (use_mask) 1.2 else 0.5
    )
  }
  plot
}

## -- Site NAME label layer: places each site's name using ggrepel so
## overlapping labels automatically nudge apart, with a thin leader line
## connecting a label back to its actual site whenever it had to move
## meaningfully to avoid a collision. This is what actually fixes labels
## silently disappearing when two sites sit close together - unlike
## plain ggplot2's check_overlap=TRUE (still used as the fallback path
## here), no label is ever dropped unless it exceeds
## label_repel_max_overlaps (default Inf = never).
##
## Only the label TEXT is repelled - the marker symbol drawn via
## add_site_markers() above always stays on the true coordinate.
## y_range_native is the current draw's native-CRS y-extent (recomputed
## every redraw, since it changes with zoom level), used to scale the
## initial nudge sensibly regardless of how zoomed in/out the map is.
add_site_labels <- function(plot, data, x, y, label_col, color, mask_color, size,
                            use_mask, y_range_native) {
  if (use_label_repel) {
    repel_args <- list(
      data = data,
      mapping = aes(x = .data[[x]], y = .data[[y]], label = .data[[label_col]]),
      color = color, size = size, fontface = "bold",
      nudge_y = y_range_native * label_repel_nudge_y_frac,
      force = label_repel_force, force_pull = label_repel_force_pull,
      box.padding = label_repel_box_padding, point.padding = label_repel_point_padding,
      max.overlaps = label_repel_max_overlaps,
      min.segment.length = label_repel_min_segment_length,
      segment.color = if (!is.null(label_repel_segment_color)) label_repel_segment_color else mask_color,
      segment.alpha = label_repel_segment_alpha,
      seed = label_repel_seed
    )
    if (use_mask && have_ggrepel_bg) {
      repel_args$bg.color <- mask_color
      if (!is.null(label_repel_bg_r)) repel_args$bg.r <- label_repel_bg_r
    }
    plot <- plot + do.call(ggrepel::geom_text_repel, repel_args)
  } else {
    plot <- add_halo_text(plot, data, x, y, label_col = label_col,
                          color = color, mask_color = mask_color, size = size,
                          use_mask = use_mask, fontface = "bold", vjust = -1.2, check_overlap = TRUE)
  }
  plot
}

## -- Compact legend box, meant to be placed as a corner INSET on top of
## the map (via patchwork::inset_element()) rather than a full-width bar -
## gives full manual control over how each symbol type (including the
## text-based star) is represented, which native ggplot legends can't do
## cleanly for a mix of geom types.
build_legend_panel <- function(boundary_available, symbol, symbol_color, mask_color,
                               use_mask, roads_shown, rail_shown, cities_shown,
                               bg_color, border_color, text_color) {
  items <- list()
  if (boundary_available) items <- c(items, list(list(type = "line", color = "green3", label = "Park Boundary")))
  items <- c(items, list(list(type = "symbol", label = "Monitoring Site")))
  if (roads_shown)  items <- c(items, list(list(type = "line", color = "gold", label = "Major Road")))
  if (rail_shown)   items <- c(items, list(list(type = "line", color = "white", linetype = "dashed", label = "Railroad")))
  if (cities_shown) items <- c(items, list(list(type = "point", color = "black", fillcolor = "white", label = "City/Town")))
  
  n <- length(items)
  if (n == 0) return(NULL)
  
  ## Vertical stack, top to bottom, drawn within a fixed 0-1 x 0-1 panel
  ## so it can be dropped in at any size via inset_element() without
  ## needing to know pixel dimensions ahead of time.
  row_h <- 1 / (n + 1)
  p <- ggplot() + xlim(0, 1) + ylim(0, 1) + theme_void() +
    theme(plot.background = element_rect(fill = bg_color, color = border_color, linewidth = 1),
          plot.margin = margin(6, 8, 6, 8))
  
  for (k in seq_len(n)) {
    it <- items[[k]]
    ypos <- 1 - (k - 0.5) * row_h
    swatch_x <- 0.16
    
    if (it$type == "line") {
      p <- p + annotate("segment", x = 0.04, xend = 0.28, y = ypos, yend = ypos,
                        color = it$color, linewidth = 1.2,
                        linetype = if (!is.null(it$linetype)) it$linetype else "solid")
    } else if (it$type == "point") {
      p <- p + annotate("point", x = swatch_x, y = ypos, shape = 21, size = 3,
                        color = it$color, fill = it$fillcolor, stroke = 1)
    } else if (it$type == "symbol") {
      if (symbol == "star") {
        p <- p + annotate("text", x = swatch_x, y = ypos, label = "\u2605", size = 5, color = symbol_color)
      } else {
        p <- p + annotate("point", x = swatch_x, y = ypos, shape = symbol_pch_lookup[[symbol]], size = 3,
                          color = if (use_mask) mask_color else symbol_color, fill = symbol_color, stroke = 1)
      }
    }
    p <- p + annotate("text", x = 0.36, y = ypos, label = it$label, hjust = 0,
                      color = text_color, size = 3.3)
  }
  p
}

## Maps a named corner to inset_element() left/right/bottom/top fractions
## (of the parent map panel). Legend width/height scale a little with the
## number of items so short legends don't leave excess empty box space.
legend_corner_coords <- function(corner, n_items) {
  w <- min(0.30, 0.14 + 0.02 * n_items)
  h <- min(0.28, 0.06 + 0.045 * n_items)
  corner_inset_coords(corner, w, h)
}

## Maps a named corner to ggspatial's two-letter location code ("tl","tr",
## "bl","br"), used by both annotation_scale() and annotation_north_arrow().
corner_to_ggspatial_loc <- function(corner) {
  switch(corner,
         "topleft" = "tl", "topright" = "tr", "bottomleft" = "bl", "bottomright" = "br",
         "br"  # default
  )
}

## Computes a backing-panel rectangle (in native map coordinates) tucked
## into the given corner of the padded extent, sized as a fraction of the
## extent - used behind the scale bar so its text/ticks stay legible
## regardless of what's underneath on the basemap.
corner_backing_rect <- function(corner, bb, w_frac = 0.30, h_frac = 0.07, margin_frac = 0.005) {
  xr <- bb["xmax"] - bb["xmin"]
  yr <- bb["ymax"] - bb["ymin"]
  m_x <- margin_frac * xr
  m_y <- margin_frac * yr
  w <- w_frac * xr
  h <- h_frac * yr
  switch(corner,
         "topleft"     = data.frame(xmin = bb["xmin"] + m_x, xmax = bb["xmin"] + m_x + w,
                                    ymin = bb["ymax"] - m_y - h, ymax = bb["ymax"] - m_y),
         "topright"    = data.frame(xmin = bb["xmax"] - m_x - w, xmax = bb["xmax"] - m_x,
                                    ymin = bb["ymax"] - m_y - h, ymax = bb["ymax"] - m_y),
         "bottomleft"  = data.frame(xmin = bb["xmin"] + m_x, xmax = bb["xmin"] + m_x + w,
                                    ymin = bb["ymin"] + m_y, ymax = bb["ymin"] + m_y + h),
         "bottomright" = data.frame(xmin = bb["xmax"] - m_x - w, xmax = bb["xmax"] - m_x,
                                    ymin = bb["ymin"] + m_y, ymax = bb["ymin"] + m_y + h),
         data.frame(xmin = bb["xmax"] - m_x - w, xmax = bb["xmax"] - m_x,
                    ymin = bb["ymin"] + m_y, ymax = bb["ymin"] + m_y + h)  # default: bottomright
  )
}

## Generic corner -> inset_element() left/right/bottom/top fractions (of
## the parent map panel), given a desired width and height fraction. Used
## by both the legend and the extent-locator inset.
corner_inset_coords <- function(corner, w, h, margin = 0.02) {
  switch(corner,
         "topleft"     = c(left = margin, bottom = 1 - h - margin, right = margin + w, top = 1 - margin),
         "topright"    = c(left = 1 - w - margin, bottom = 1 - h - margin, right = 1 - margin, top = 1 - margin),
         "bottomleft"  = c(left = margin, bottom = margin, right = margin + w, top = margin + h),
         "bottomright" = c(left = 1 - w - margin, bottom = margin, right = 1 - margin, top = margin + h),
         c(left = margin, bottom = margin, right = margin + w, top = margin + h)  # default: bottomleft
  )
}

## -- Extent locator inset: fetches a wider-context boundary (US state
## containing the park, via tigris; falls back to the country boundary,
## via rnaturalearth, if that fails or the park isn't in a US state) ONCE
## per script run - the context doesn't change as you zoom, only the
## extent box drawn within it does, so this is deliberately not re-fetched
## inside the redraw loop.
get_locator_context <- function(park_centroid_ll) {
  ctx <- tryCatch({
    states_sf <- tigris::states(cb = TRUE, progress_bar = FALSE)
    states_sf <- sf::st_transform(states_sf, 4326)
    hit <- states_sf[sf::st_intersects(park_centroid_ll, states_sf, sparse = FALSE)[1, ], ]
    if (nrow(hit) == 1) {
      message("Locator inset: using state boundary for ", hit$NAME[1])
      return(list(geom = hit, label = hit$NAME[1]))
    }
    NULL
  }, error = function(e) {
    message("Could not fetch US state boundary for locator inset (", conditionMessage(e), ") - trying country boundary.")
    NULL
  })
  if (!is.null(ctx)) return(ctx)
  
  tryCatch({
    world_sf <- rnaturalearth::ne_countries(scale = "medium", returnclass = "sf")
    hit <- world_sf[sf::st_intersects(park_centroid_ll, world_sf, sparse = FALSE)[1, ], ]
    if (nrow(hit) == 1) {
      message("Locator inset: using country boundary for ", hit$name[1])
      return(list(geom = hit, label = hit$name[1]))
    }
    NULL
  }, error = function(e) {
    message("Could not fetch country boundary for locator inset either (", conditionMessage(e), ") - locator inset will be skipped.")
    NULL
  })
}

## Builds the small locator ggplot: context shape (state/country) in a
## flat fill color, with a rectangle showing the current main-map extent,
## a dot for the park's own location, and a text label naming the state/
## country being shown. Deliberately plain/schematic - no basemap tiles -
## this is a "where is this on the map" aid, not a second detailed map.
build_extent_inset <- function(context, extent_bbox_ll, park_centroid_ll,
                               bg_color, border_color, fill_color, box_color,
                               label_color = NULL) {
  if (is.null(context)) return(NULL)
  
  if (is.null(label_color)) label_color <- border_color
  
  ctx_geom <- sf::st_geometry(context$geom)
  ctx_bb <- sf::st_bbox(ctx_geom)
  box_df <- data.frame(
    xmin = extent_bbox_ll["xmin"], xmax = extent_bbox_ll["xmax"],
    ymin = extent_bbox_ll["ymin"], ymax = extent_bbox_ll["ymax"]
  )
  ctr_coords <- sf::st_coordinates(park_centroid_ll)
  
  ## Label placed just inside the top of the context shape's own bounding
  ## box, so it reads clearly regardless of where the extent box happens
  ## to fall within the state/country outline.
  label_x <- (ctx_bb["xmin"] + ctx_bb["xmax"]) / 2
  label_y <- ctx_bb["ymax"] - 0.06 * (ctx_bb["ymax"] - ctx_bb["ymin"])
  
  ggplot() +
    geom_sf(data = ctx_geom, fill = fill_color, color = border_color, linewidth = 0.4) +
    annotate("rect", xmin = box_df$xmin, xmax = box_df$xmax, ymin = box_df$ymin, ymax = box_df$ymax,
             color = box_color, fill = NA, linewidth = 0.9) +
    annotate("text", x = label_x, y = label_y, label = context$label,
             color = label_color, size = 3, fontface = "bold") +
    coord_sf(expand = TRUE) +
    theme_void() +
    theme(plot.background = element_rect(fill = bg_color, color = border_color, linewidth = 1),
          plot.margin = margin(3, 3, 3, 3))
}

## -- OpenStreetMap layer fetchers (via osmdata / Overpass API) -------------
## Each returns NULL (with a message) on any failure - roads/rail/cities
## are optional decoration and should never block the map from being built.
##
## Each fetch runs in an isolated background process (via callr) with a
## hard wall-clock timeout, since osmdata's HTTP client can otherwise
## retry with an uninterruptible exponential backoff on server errors.
## Several public Overpass mirrors are tried in sequence in case one is
## slow or rate-limited.

run_osm_query_with_timeout <- function(query_fun, ..., timeout_secs, mirrors) {
  for (mirror in mirrors) {
    message("  Trying Overpass server: ", mirror, " (timeout ", timeout_secs, "s) ...")
    result <- tryCatch(
      callr::r(
        func = query_fun,
        args = c(list(overpass_url = mirror), list(...)),
        timeout = timeout_secs,
        package = TRUE
      ),
      error = function(e) {
        message("    Failed/timed out on this server (", conditionMessage(e), ") - trying next mirror if available.")
        NULL
      }
    )
    if (!is.null(result)) return(result)
  }
  NULL
}

.osm_fetch_roads <- function(overpass_url, bbox_ll, classes) {
  library(osmdata); library(sf); library(magrittr)
  osmdata::set_overpass_url(overpass_url)
  q <- osmdata::opq(bbox = bbox_ll, timeout = 25) %>%
    osmdata::add_osm_feature(key = "highway", value = classes)
  res <- osmdata::osmdata_sf(q)
  lines <- res$osm_lines
  if (is.null(lines) || nrow(lines) == 0) return(NULL)
  lines
}

.osm_fetch_railroads <- function(overpass_url, bbox_ll) {
  library(osmdata); library(sf); library(magrittr)
  osmdata::set_overpass_url(overpass_url)
  q <- osmdata::opq(bbox = bbox_ll, timeout = 25) %>%
    osmdata::add_osm_feature(key = "railway", value = "rail")
  res <- osmdata::osmdata_sf(q)
  lines <- res$osm_lines
  if (is.null(lines) || nrow(lines) == 0) return(NULL)
  lines
}

.osm_fetch_cities <- function(overpass_url, bbox_ll, min_pop) {
  library(osmdata); library(sf); library(magrittr)
  osmdata::set_overpass_url(overpass_url)
  q <- osmdata::opq(bbox = bbox_ll, timeout = 25) %>%
    osmdata::add_osm_feature(key = "place", value = c("city", "town", "village"))
  res <- osmdata::osmdata_sf(q)
  pts <- res$osm_points
  if (is.null(pts) || nrow(pts) == 0) return(NULL)
  if (!"population" %in% names(pts)) pts$population <- NA
  pts$population_num <- suppressWarnings(as.numeric(pts$population))
  pts <- pts[is.na(pts$population_num) | pts$population_num >= min_pop, ]
  pts <- pts[!is.na(pts$name), ]
  if (nrow(pts) == 0) return(NULL)
  pts
}

get_osm_roads <- function(bbox_ll, classes) {
  res <- tryCatch(
    run_osm_query_with_timeout(.osm_fetch_roads, bbox_ll = bbox_ll, classes = classes,
                               timeout_secs = osm_timeout_secs, mirrors = osm_overpass_mirrors),
    error = function(e) { message("Roads fetch failed unexpectedly (", conditionMessage(e), ")."); NULL }
  )
  if (is.null(res)) message("Could not fetch roads from OpenStreetMap (all servers failed or timed out) - skipping roads layer.")
  res
}

get_osm_railroads <- function(bbox_ll) {
  res <- tryCatch(
    run_osm_query_with_timeout(.osm_fetch_railroads, bbox_ll = bbox_ll,
                               timeout_secs = osm_timeout_secs, mirrors = osm_overpass_mirrors),
    error = function(e) { message("Railroads fetch failed unexpectedly (", conditionMessage(e), ")."); NULL }
  )
  if (is.null(res)) message("Could not fetch railroads from OpenStreetMap (all servers failed or timed out) - skipping railroads layer.")
  res
}

get_osm_cities <- function(bbox_ll, min_pop) {
  res <- tryCatch(
    run_osm_query_with_timeout(.osm_fetch_cities, bbox_ll = bbox_ll, min_pop = min_pop,
                               timeout_secs = osm_timeout_secs, mirrors = osm_overpass_mirrors),
    error = function(e) { message("Cities fetch failed unexpectedly (", conditionMessage(e), ")."); NULL }
  )
  if (is.null(res)) message("Could not fetch cities/towns from OpenStreetMap (all servers failed or timed out) - skipping cities layer.")
  res
}

## ---------------------------------------------------------------------
## 3. VALIDATE CONFIG
## ---------------------------------------------------------------------

map_orientation <- tolower(map_orientation)
if (!map_orientation %in% c("landscape", "portrait")) {
  warning("map_orientation should be 'landscape' or 'portrait' - defaulting to 'landscape'.")
  map_orientation <- "landscape"
}

basemap_style <- tolower(basemap_style)
provider_lookup <- c(satellite = "Esri.WorldImagery", topo = "Esri.WorldTopoMap")
if (!basemap_style %in% names(provider_lookup)) {
  warning("basemap_style should be 'satellite' or 'topo' - defaulting to 'satellite'.")
  basemap_style <- "satellite"
}
basemap_provider <- provider_lookup[[basemap_style]]

## Fraction of total image height occupied by the map panel itself (vs.
## title bar + caption). Used both in the patchwork layout below AND in
## the target aspect-ratio math, so the map panel's rendered width
## actually lines up with the title bar's width rather than being
## letterboxed within its allotted space.
title_height_frac   <- 0.08
map_height_frac     <- 0.85
caption_height_frac <- 0.07
stopifnot(abs(title_height_frac + map_height_frac + caption_height_frac - 1) < 1e-9)

## ---------------------------------------------------------------------
## 4. SELECT SiteMeta.xlsx
## ---------------------------------------------------------------------

notify(paste0(
  "A file browser is about to open.\n\n",
  "Please select the SiteMeta.xlsx file for the park you want to map ",
  "(it should have Site, Latitude, and Longitude columns filled in)."
), title = "Select SiteMeta.xlsx")

sitemeta_path <- file.choose()
sitesmeta_dir <- dirname(sitemeta_path)

meta <- tryCatch(openxlsx::read.xlsx(sitemeta_path), error = function(e) NULL)

if (is.null(meta) || !all(c("Site", "Latitude", "Longitude") %in% names(meta))) {
  stop("Could not read Site/Latitude/Longitude columns from: ", sitemeta_path)
}

sites_geo <- meta[!is.na(meta$Latitude) & !is.na(meta$Longitude), ]
missing_coords <- setdiff(meta$Site, sites_geo$Site)
if (length(missing_coords) > 0) {
  message("Skipping site(s) with no Lat/Long in SiteMeta.xlsx: ", paste(missing_coords, collapse = ", "))
}
if (nrow(sites_geo) == 0) {
  stop("No sites with Latitude/Longitude filled in - fill those in and re-run.")
}
sites_geo$star_glyph <- "\u2605"  # used only when site_symbol == "star"

## ---------------------------------------------------------------------
## 5. DETERMINE PARK CODE
## ---------------------------------------------------------------------

inferred_code <- basename(dirname(sitesmeta_dir))
looks_like_code <- grepl("^[A-Za-z0-9]{4}$", inferred_code)

if (looks_like_code) {
  use_inferred <- ask_yes_no(sprintf("Detected park code '%s' from the folder path. Is that correct?", inferred_code))
  park_code <- if (use_inferred) toupper(inferred_code) else NA_character_
} else {
  park_code <- NA_character_
}

if (is.na(park_code)) {
  cat("Enter the 4-letter park code (e.g. CRMO): ")
  park_code <- toupper(trimws(readline()))
}

if (!grepl("^[A-Za-z0-9]{4}$", park_code)) {
  warning("Park code '", park_code, "' doesn't look like a standard 4-character code - proceeding anyway.")
}

parkname <- get_park_name(park_code)
message("Using park: ", parkname, " (", park_code, ")")

## ---------------------------------------------------------------------
## 6. FETCH PARK BOUNDARY
## ---------------------------------------------------------------------

get_park_boundary <- function(pcode) {
  service_url <- "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/NPS_Land_Resources_Division_Boundary_and_Tract_Data_Service/FeatureServer"
  candidate_layers <- c(2, 0, 1, 3, 4)
  candidate_fields <- c("UNIT_CODE", "PARKCODE", "Unit_Code", "ALPHACODE", "UNITCODE", "CODE")
  
  for (lyr in candidate_layers) {
    layer_url <- paste0(service_url, "/", lyr)
    for (fld in candidate_fields) {
      q <- sprintf("%s/query?where=UPPER(%s)='%s'&outFields=*&f=geojson",
                   layer_url, fld, toupper(pcode))
      bnd <- tryCatch(sf::st_read(q, quiet = TRUE), error = function(e) NULL)
      if (is.null(bnd) || nrow(bnd) == 0) next
      
      bnd <- tryCatch(sf::st_make_valid(bnd), error = function(e) bnd)
      bnd <- bnd[!sf::st_is_empty(bnd), ]
      if (nrow(bnd) == 0) next
      
      bnd_ll <- tryCatch(sf::st_transform(bnd, 4326), error = function(e) NULL)
      if (is.null(bnd_ll)) next
      
      bb <- tryCatch(sf::st_bbox(bnd_ll), error = function(e) NULL)
      if (is.null(bb) || any(!is.finite(bb))) next
      if ((bb["ymax"] - bb["ymin"]) > 5 || (bb["xmax"] - bb["xmin"]) > 5) {
        message(sprintf("  Layer %d, field %s: matched geometry looks too large to be a single park - skipping.", lyr, fld))
        next
      }
      ctr_check <- tryCatch(sf::st_coordinates(sf::st_centroid(sf::st_union(bnd_ll))), error = function(e) NULL)
      if (is.null(ctr_check) || any(!is.finite(ctr_check)) || abs(ctr_check[1,"Y"]) > 90) next
      
      message(sprintf("  Boundary found: layer %d, field %s", lyr, fld))
      return(bnd_ll)
    }
  }
  NULL
}

message("Looking up park boundary for: ", park_code, " ...")
boundary <- tryCatch(get_park_boundary(park_code), error = function(e) {
  message("Boundary lookup failed unexpectedly (", conditionMessage(e), ") - will use site bounding box instead.")
  NULL
})

if (is.null(boundary)) {
  message("No boundary found online for ", park_code, ".")
  use_local <- ask_yes_no("Do you have a local boundary file (.shp/.geojson) you'd like to use instead?")
  if (use_local) {
    notify("A file browser is about to open.\n\nSelect your local park boundary file.", title = "Select boundary file")
    bnd_path <- tryCatch(file.choose(), error = function(e) NA_character_)
    if (!is.na(bnd_path)) {
      boundary <- tryCatch(sf::st_read(bnd_path, quiet = TRUE), error = function(e) {
        message("Could not read that file (", conditionMessage(e), ") - will use site bounding box instead.")
        NULL
      })
    }
  }
}

boundary_available <- !is.null(boundary) && nrow(boundary) > 0
if (boundary_available) {
  message("Using park boundary polygon for the map.")
} else {
  message("Proceeding without a boundary polygon - map extent will be based on site locations only.")
}

## -- Locator inset context (state/country outline), fetched once since it
## doesn't depend on zoom level - only the extent box drawn within it does.
locator_context <- NULL
if (show_extent_inset) {
  message("Fetching locator context (state/country boundary) for extent inset ...")
  park_centroid_for_locator <- sf::st_centroid(sf::st_union(
    if (boundary_available) sf::st_transform(boundary, 4326) else sf::st_transform(sf::st_as_sf(sites_geo, coords = c("Longitude","Latitude"), crs = 4326), 4326)
  ))
  locator_context <- tryCatch(get_locator_context(park_centroid_for_locator), error = function(e) {
    message("Locator inset context fetch failed unexpectedly (", conditionMessage(e), ") - inset will be skipped.")
    NULL
  })
  if (is.null(locator_context)) message("No locator context available - extent inset will be skipped for this run.")
}

## ---------------------------------------------------------------------
## 7. BUILD GEOMETRY: sites, projection (for extent/padding math only),
##    aspect ratio based on chosen orientation AND the map panel's actual
##    height fraction (so it lines up edge-to-edge with the title bar)
## ---------------------------------------------------------------------

site_pts <- sf::st_as_sf(sites_geo, coords = c("Longitude", "Latitude"), crs = 4326)

## Validate extent_center_on and fall back sensibly if a mode requiring
## the boundary was chosen but no boundary is actually available.
extent_center_on <- tolower(extent_center_on)
if (!extent_center_on %in% c("boundary_and_sites", "sites", "boundary")) {
  warning("extent_center_on should be 'boundary_and_sites', 'sites', or 'boundary' - defaulting to 'boundary_and_sites'.")
  extent_center_on <- "boundary_and_sites"
}
if (extent_center_on == "boundary" && !boundary_available) {
  message("extent_center_on = 'boundary' but no boundary is available - falling back to 'sites' for framing.")
  extent_center_on <- "sites"
}

## anchor_geom determines the map's CENTER and EXTENT (via its bounding
## box, below). It does NOT determine what gets drawn - boundary_native
## and sites_native are built and rendered independently of this choice,
## so the boundary still appears in the frame wherever it happens to fall.
anchor_geom <- switch(extent_center_on,
                      "sites"    = sf::st_union(site_pts),
                      "boundary" = sf::st_union(boundary),
                      sf::st_union(sf::st_union(if (boundary_available) boundary else site_pts), sf::st_union(site_pts))  # "boundary_and_sites"
)

ctr <- sf::st_coordinates(sf::st_centroid(anchor_geom))
ctr_lat <- max(min(ctr[1, "Y"], 89), -89)
ctr_lon <- ((ctr[1, "X"] + 180) %% 360) - 180

bbox0 <- sf::st_bbox(anchor_geom)
lat_rng <- if (all(is.finite(bbox0))) max(bbox0["ymax"] - bbox0["ymin"], 0.01) else 0.5
lat_rng <- min(lat_rng, 10)

lat_1 <- max(min(ctr_lat - lat_rng / 6, 89), -89)
lat_2 <- max(min(ctr_lat + lat_rng / 6, 89), -89)

aea_crs <- sprintf("+proj=aea +lat_1=%f +lat_2=%f +lat_0=%f +lon_0=%f +datum=NAD83 +units=m +no_defs",
                   lat_1, lat_2, ctr_lat, ctr_lon)

boundary_aea <- if (boundary_available) sf::st_transform(boundary, aea_crs) else NULL
sites_aea <- sf::st_transform(site_pts, aea_crs)

## extent_aea drives the actual padded bounding box used for the map
## frame in the draw loop below - built from the SAME anchor as above,
## not necessarily the union of boundary+sites, so a "sites"-only choice
## really does center tightly on the sites regardless of boundary extent.
extent_aea <- switch(extent_center_on,
                     "sites"    = sf::st_union(sites_aea),
                     "boundary" = sf::st_union(boundary_aea),
                     sf::st_union(sf::st_union(boundary_aea), sf::st_union(sites_aea))  # "boundary_and_sites"
)

## Full saved-image width:height, then corrected for the fact that the
## map panel only occupies map_height_frac of the total height - so the
## panel's OWN aspect ratio (what coord_sf actually needs to match) is
## wider/taller than the full-image ratio by that same factor.
save_w <- if (map_orientation == "landscape") 10 else 7.5
save_h <- if (map_orientation == "landscape") 7.5 else 10
target_ratio <- save_w / (save_h * map_height_frac)

## ---------------------------------------------------------------------
## 8. DRAW / ACCEPT / REDRAW LOOP
## ---------------------------------------------------------------------

pad_frac <- if (extent_center_on == "sites") 0.6 else if (boundary_available) 0.25 else 0.6
pad_step <- 0.2
accepted <- FALSE

extra_layers_desc <- character(0)
if (show_roads) extra_layers_desc <- c(extra_layers_desc, "roads")
if (show_railroads) extra_layers_desc <- c(extra_layers_desc, "railroads")
if (show_cities) extra_layers_desc <- c(extra_layers_desc, "cities/towns")

notify(paste0(
  "The map will be drawn now (", map_orientation, " orientation, ", basemap_style, " basemap, ",
  site_symbol, " markers",
  if (length(extra_layers_desc) > 0) paste0(", with ", paste(extra_layers_desc, collapse = ", ")) else "",
  if (show_extent_inset && !is.null(locator_context)) paste0(", locator inset (", locator_context$label, ")") else "",
  ").\n\n",
  "After each draw, you'll be asked:\n\n",
  "  - Accept and save this map? (y/n)\n",
  "  - If no: zoom OUT to show more area? (y/n)\n",
  "  - If no to that: zoom IN to show less area? (y/n)\n",
  "  - If no to that: quit without saving\n\n",
  "It will keep redrawing until you accept or quit."
), title = "How this works")

while (!accepted) {
  
  bb <- sf::st_bbox(extent_aea)
  if (any(!is.finite(bb))) stop("Computed extent bounding box is invalid (non-finite values) - cannot continue.")
  
  xr0 <- max(bb["xmax"] - bb["xmin"], 100)
  yr0 <- max(bb["ymax"] - bb["ymin"], 100)
  
  xr <- xr0 * (1 + 2 * pad_frac)
  yr <- yr0 * (1 + 2 * pad_frac)
  current_ratio <- xr / yr
  if (current_ratio < target_ratio) {
    xr <- yr * target_ratio
  } else {
    yr <- xr / target_ratio
  }
  
  cx <- (bb["xmin"] + bb["xmax"]) / 2
  cy <- (bb["ymin"] + bb["ymax"]) / 2
  
  bb_pad <- sf::st_bbox(c(
    xmin = unname(cx - xr / 2), xmax = unname(cx + xr / 2),
    ymin = unname(cy - yr / 2), ymax = unname(cy + yr / 2)
  ), crs = sf::st_crs(aea_crs))
  
  message("Debug - padded extent (AEA meters): ", paste(round(bb_pad, 1), collapse = ", "))
  
  bb_pad_ll_sfc <- tryCatch(sf::st_transform(sf::st_as_sfc(bb_pad), 4326), error = function(e) {
    stop("Failed to transform map extent to lat/long for basemap lookup: ", conditionMessage(e))
  })
  bb_pad_ll <- sf::st_bbox(bb_pad_ll_sfc)
  message("Debug - padded extent (lat/long): ", paste(round(bb_pad_ll, 4), collapse = ", "))
  if (any(!is.finite(bb_pad_ll))) stop("Padded extent transformed to invalid lat/long values - cannot continue.")
  
  message("Fetching basemap imagery (", basemap_style, ") ...")
  basemap <- tryCatch(
    maptiles::get_tiles(bb_pad_ll_sfc, provider = basemap_provider, crop = TRUE, project = FALSE),
    error = function(e) {
      message("Basemap fetch failed at maptiles::get_tiles(): ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(basemap)) stop("Could not fetch basemap imagery - check your internet connection and try again.")
  
  native_crs <- terra::crs(basemap)
  
  boundary_native <- if (boundary_available) tryCatch(sf::st_transform(boundary, native_crs), error = function(e) NULL) else NULL
  sites_native <- tryCatch(sf::st_transform(site_pts, native_crs), error = function(e) NULL)
  if (is.null(sites_native)) stop("Failed to reproject site points to match basemap imagery CRS.")
  
  bb_pad_native <- tryCatch(sf::st_bbox(sf::st_transform(bb_pad_ll_sfc, native_crs)),
                            error = function(e) stop("Failed to reproject map extent to match basemap imagery CRS: ", conditionMessage(e)))
  
  roads_native <- NULL
  if (show_roads) {
    message("Fetching roads from OpenStreetMap ...")
    roads_ll <- get_osm_roads(bb_pad_ll, road_classes)
    if (!is.null(roads_ll)) roads_native <- tryCatch(sf::st_transform(roads_ll, native_crs), error = function(e) NULL)
  }
  
  rail_native <- NULL
  if (show_railroads) {
    message("Fetching railroads from OpenStreetMap ...")
    rail_ll <- get_osm_railroads(bb_pad_ll)
    if (!is.null(rail_ll)) rail_native <- tryCatch(sf::st_transform(rail_ll, native_crs), error = function(e) NULL)
  }
  
  cities_native <- NULL
  if (show_cities) {
    message("Fetching cities/towns from OpenStreetMap ...")
    cities_ll <- get_osm_cities(bb_pad_ll, city_min_population)
    if (!is.null(cities_ll)) cities_native <- tryCatch(sf::st_transform(cities_ll, native_crs), error = function(e) NULL)
  }
  
  ## -- Build the map, layer by layer ---------------------------------------
  map_plot <- ggplot() +
    tidyterra::geom_spatraster_rgb(data = basemap, maxcell = 5e6)
  
  if (!is.null(roads_native)) {
    map_plot <- map_plot + geom_sf(data = roads_native, color = "gold", linewidth = 0.5)
  }
  if (!is.null(rail_native)) {
    map_plot <- map_plot + geom_sf(data = rail_native, color = "white", linewidth = 0.5, linetype = "dashed")
  }
  if (!is.null(boundary_native)) {
    map_plot <- map_plot + geom_sf(data = boundary_native, fill = NA, color = "green3", linewidth = 1)
  }
  if (!is.null(cities_native)) {
    city_coords <- sf::st_coordinates(cities_native)
    cities_df <- cbind(sf::st_drop_geometry(cities_native), x = city_coords[,1], y = city_coords[,2])
    map_plot <- map_plot +
      geom_point(data = cities_df, aes(x = x, y = y), color = "white", fill = "black", shape = 21, size = 2) +
      geom_text(data = cities_df, aes(x = x, y = y, label = name),
                vjust = -0.8, size = 3, color = "white", fontface = "italic", check_overlap = TRUE)
  }
  
  site_coords <- sf::st_coordinates(sites_native)
  sites_df <- cbind(sf::st_drop_geometry(sites_native), x = site_coords[,1], y = site_coords[,2])
  
  map_plot <- add_site_markers(map_plot, sites_df, "x", "y",
                               color = site_symbol_color, mask_color = symbol_mask_color,
                               size = site_symbol_size, use_mask = use_symbol_mask, symbol = site_symbol)
  
  ## Site NAME labels - see add_site_labels() definition above for how
  ## overlap handling works. y_range_native is recomputed every redraw
  ## (it changes with zoom level) so the initial nudge before ggrepel's
  ## repulsion kicks in scales sensibly at any zoom.
  yr_native <- bb_pad_native["ymax"] - bb_pad_native["ymin"]
  map_plot <- add_site_labels(map_plot, sites_df, "x", "y", label_col = "Site",
                              color = site_label_color, mask_color = label_mask_color,
                              size = site_label_size, use_mask = use_label_mask,
                              y_range_native = yr_native)
  
  map_plot <- map_plot +
    coord_sf(xlim = c(bb_pad_native["xmin"], bb_pad_native["xmax"]),
             ylim = c(bb_pad_native["ymin"], bb_pad_native["ymax"]), expand = FALSE) +
    theme_void() +
    theme(legend.position = "none", plot.margin = margin(0,0,0,0),
          plot.background = element_rect(fill = "black", color = NA))
  
  ## Small backing panel behind the scale bar so its text/ticks stay
  ## legible regardless of what's underneath on the basemap (satellite
  ## imagery especially can be light or dark unpredictably at that corner).
  sb_rect <- corner_backing_rect(scalebar_corner, bb_pad_native)
  map_plot <- map_plot + annotate("rect", xmin = sb_rect$xmin, xmax = sb_rect$xmax,
                                  ymin = sb_rect$ymin, ymax = sb_rect$ymax,
                                  fill = scalebar_bg_color, alpha = 0.75)
  
  map_plot <- tryCatch({
    map_plot + ggspatial::annotation_scale(
      location = corner_to_ggspatial_loc(scalebar_corner), style = "ticks",
      line_col = scalebar_text_color, text_col = scalebar_text_color,
      height = unit(0.3, "cm"), text_cex = 1, unit_category = "metric",
      pad_x = unit(0.35, "cm"), pad_y = unit(0.3, "cm")
    )
  }, error = function(e) {
    message("Could not add scale bar (", conditionMessage(e), ") - continuing without it.")
    map_plot
  })
  
  map_plot <- tryCatch({
    map_plot + ggspatial::annotation_north_arrow(location = corner_to_ggspatial_loc(north_arrow_corner),
                                                 which_north = "true",
                                                 style = ggspatial::north_arrow_minimal(text_col = "black"))
  }, error = function(e) {
    message("Could not add north arrow (", conditionMessage(e), ") - continuing without it.")
    map_plot
  })
  
  title_plot <- ggplot() + xlim(0,1) + ylim(0,1) + theme_void() +
    theme(plot.margin = margin(0,0,0,0), plot.background = element_rect(fill = "black", color = NA)) +
    geom_rect(aes(xmin=0,xmax=1,ymin=0,ymax=1), fill = "black") +
    annotate("text", x=0.02, y=0.65, hjust=0, size=6, fontface="bold", color="white",
             label = parkname) +
    annotate("text", x=0.02, y=0.25, hjust=0, size=4.3, fontface="italic", color="white",
             label = "Acoustic Monitoring Sites") +
    annotate("text", x=0.98, y=0.75, hjust=1, size=4, fontface="bold", color="white",
             label = "National Park Service") +
    annotate("text", x=0.98, y=0.45, hjust=1, size=3.2, color="white",
             label = "U.S. Department of the Interior") +
    annotate("text", x=0.98, y=0.20, hjust=1, size=3.2, color="white",
             label = "Natural Resource Stewardship and Science")
  
  caption_plot <- ggplot() + xlim(0,1) + ylim(0,1) + theme_void() +
    theme(plot.margin = margin(0,0,0,0), plot.background = element_rect(fill = "black", color = NA)) +
    annotate("text", x=0.02, y=0.5, hjust=0, size=3, color = "white",
             label = paste0("NPS Natural Sounds & Night Skies Division  ", format(Sys.Date(), "%Y%m%d")))
  
  legend_panel <- if (show_legend) {
    build_legend_panel(boundary_available, site_symbol, site_symbol_color, symbol_mask_color,
                       use_symbol_mask, !is.null(roads_native), !is.null(rail_native), !is.null(cities_native),
                       bg_color = legend_bg_color, border_color = legend_border_color, text_color = legend_text_color)
  } else NULL
  
  if (!is.null(legend_panel)) {
    n_legend_items <- 1 + boundary_available + !is.null(roads_native) + !is.null(rail_native) + !is.null(cities_native)
    lc <- legend_corner_coords(legend_corner, n_legend_items)
    map_plot <- map_plot + patchwork::inset_element(
      legend_panel, left = lc["left"], bottom = lc["bottom"], right = lc["right"], top = lc["top"],
      align_to = "panel", clip = FALSE
    )
  }
  
  if (show_extent_inset && !is.null(locator_context)) {
    park_centroid_ll_pt <- sf::st_centroid(sf::st_union(
      if (boundary_available) sf::st_transform(boundary, 4326) else sf::st_transform(site_pts, 4326)
    ))
    extent_inset_panel <- tryCatch(
      build_extent_inset(locator_context, bb_pad_ll, park_centroid_ll_pt,
                         bg_color = extent_inset_bg_color, border_color = extent_inset_border_color,
                         fill_color = extent_inset_fill_color, box_color = extent_inset_box_color,
                         label_color = extent_inset_label_color),
      error = function(e) {
        message("Could not build extent inset (", conditionMessage(e), ") - skipping it for this draw.")
        NULL
      }
    )
    if (!is.null(extent_inset_panel)) {
      ## Height derived from the context shape's own aspect ratio so state/
      ## country outlines of very different proportions don't get squished.
      ctx_bb <- sf::st_bbox(locator_context$geom)
      ctx_ratio <- (ctx_bb["ymax"] - ctx_bb["ymin"]) / (ctx_bb["xmax"] - ctx_bb["xmin"])
      ei_h <- min(0.5, extent_inset_size * ctx_ratio * (target_ratio))
      eic <- corner_inset_coords(extent_inset_corner, extent_inset_size, ei_h)
      map_plot <- map_plot + patchwork::inset_element(
        extent_inset_panel, left = eic["left"], bottom = eic["bottom"], right = eic["right"], top = eic["top"],
        align_to = "panel", clip = FALSE
      )
    }
  }
  
  final_plot <- title_plot / map_plot / caption_plot +
    patchwork::plot_layout(heights = c(title_height_frac, map_height_frac, caption_height_frac)) &
    theme(plot.margin = margin(0, 0, 0, 0))
  
  print(final_plot)
  
  cat(sprintf("\nCurrent padding around extent: %.0f%% | Orientation: %s | Basemap: %s | Symbol: %s\n",
              pad_frac * 100, map_orientation, basemap_style, site_symbol))
  
  if (ask_yes_no("Accept and save this map?")) {
    accepted <- TRUE
    out_map_path <- file.path(sitesmeta_dir, paste0(park_code, "_SiteMap.png"))
    safe_ggsave(out_map_path, plot = final_plot, width = save_w, height = save_h, dpi = 300, bg = "black")
    message("Site map saved to: ", out_map_path)
    
  } else if (ask_yes_no("Zoom OUT to show more area?")) {
    pad_frac <- pad_frac + pad_step
    
  } else if (ask_yes_no("Zoom IN to show less area?")) {
    pad_frac <- max(pad_frac - pad_step, 0)
    
  } else {
    message("Quit without saving a map.")
    break
  }
}