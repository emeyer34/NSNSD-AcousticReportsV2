#########################################################################
#
#  Step1_acoustic_parse_export.R
#
#  Purpose:
#    Replaces Step2_AcousticReport_HTML_DataExplore.Rmd. No HTML report is
#    produced. This script:
#      1) Lets you browse to a project folder (Windows file/folder dialog)
#      2) Recursively finds all METRICS_*.txt files under it
#      3) Lets you pick which of those files to actually process
#      4) Fixes the "missing tab before Lnat" issue in the selected files
#      5) Detects which season(s) each file contains, and whether it has
#         Listening Center and/or SPLAT analysis sections
#      6) Maintains a persistent "order" lookup (Season/Year -> Order #)
#         in <REPORTS>/<park_code>/season_order_lookup.csv
#      7) Loops over every Season+Year combo present in your selected
#         files and exports tables/plots as CSVs and PNGs into:
#           <REPORTS>/<park_code>/<order>_<season>_<year>/
#      8) Builds a SitesMeta folder per park with common reference images
#         and a SiteMeta.xlsx (site IDs + monitoring date ranges), which
#         it will open for you to fill in Latitude/Longitude by hand.
#
#  NOTE: Site-map generation (park boundary + site locations, styled like
#  the NPS acoustic monitoring templates) has been pulled out of this
#  script and will be built as its own standalone script that reads from
#  the SiteMeta.xlsx this script produces. That keeps the core parsing/
#  export pipeline here stable and decoupled from the more experimental
#  mapping/GIS dependencies.
#
#  Requires: readMetrics.R (you will be prompted to locate it)
#            sourceid.rds  (you will be prompted to locate it)
#
#########################################################################

## ---------------------------------------------------------------------
## 0. CONFIG
## ---------------------------------------------------------------------

plottitle    <- TRUE   # Produce titles on plots?
plotHRDBA    <- TRUE   # Produce hourly dBA plot?
plotTRUNCDBA <- TRUE   # Produce truncated hourly dBA plot?
plotFREQDBA  <- TRUE   # Produce frequency dBA plot?
plotCONTOUR  <- TRUE   # Produce contour plot?

yMaxHr <- 70   # upper limit, hourly graphs (multiple of 3)
yMinHr <- 5    # lower limit, hourly graphs (multiple of 3)
yMaxHz <- 70   # upper limit, frequency graphs (multiple of 3)
yMinHz <- -12  # lower limit, frequency graphs (multiple of 3)

tabfix_scope <- "day_night"  # "any" or "day_night" - see fix_missing_tabs_in_lines()

copy_common_images   <- TRUE   # copy shared reference PNGs into SitesMeta folder?
common_images_reldir <- file.path("..", "..", "MAPS_IMAGES", "COMMON")  # relative to this script's location

build_sitemeta      <- TRUE   # prompt to build/update SiteMeta.xlsx from NVSPL deployment folders?
prompt_open_sitemeta <- TRUE  # open SiteMeta.xlsx for editing (lat/long, etc) before finishing this step?

## Auto-fill Latitude/Longitude from the NSNSD Deployment Locations report
## before opening SiteMeta.xlsx for manual editing. Existing manually-
## entered coordinates are NEVER overwritten - this only fills in blanks.
use_deployment_locations_lookup <- TRUE

## "prompt"       - (recommended, most reliable) browse to a file you've
##                  exported yourself from the Deployment Locations page
##                  (CSV, XML, or MHTML all supported - see notes below).
##                  You'll be asked every run; point it at a fresh export
##                  whenever you want updated coordinates.
## "atomsvc_live" - EXPERIMENTAL: attempts to pull live data directly from
##                  a .atomsvc OData feed URL you provide, using your
##                  current Windows session for authentication. This is
##                  UNVERIFIED - it depends entirely on how that specific
##                  NPS reporting tool is set up and whether it accepts
##                  non-interactive authentication. If it fails, it falls
##                  back to "prompt" automatically.
deployment_locations_source <- "prompt"
deployment_locations_atomsvc_url <- ""  # only used if deployment_locations_source == "atomsvc_live"

## Format notes for the "prompt" file browser:
##   CSV   - most reliable; just needs Site/Latitude/Longitude-like columns
##   XML   - parsed generically (looks for repeating records with
##           recognizable field names); less predictable than CSV
##   MHTML - least reliable; the script strips the MIME envelope and
##           parses whatever HTML table it finds inside - CSV is strongly
##           preferred over this if your export tool offers a choice

build_trends <- TRUE          # after processing, build trend graphs across seasons/years (if more than one exists)?
trend_min_combos <- 2         # minimum number of season/year combos required before trends are built
trend_top_n_sources <- 5      # for EventCountsLengths trends, how many top noise sources to plot (by overall average count)

## Safe write helpers - report the exact path on failure instead of a bare
## "cannot open the connection" error, and don't let one bad file abort
## the whole run (e.g. a CSV left open in Excel, or a path that's too long).
safe_write_csv <- function(x, path, ...) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tryCatch(
    write.csv(x, path, ...),
    error = function(e) {
      warning(sprintf(paste0("Could not write CSV to:\n  %s\nReason: %s\n",
                             "(Is the file open in Excel? Is the path too long? Does the folder exist?)"),
                      path, conditionMessage(e)), call. = FALSE)
    }
  )
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

## Extracts the "(n = X days)" (or "(n = X day)") count from a specific
## section header line for a given label + season, e.g. the line
## "Listening Center Detailed Event Audibility (%), Summer (n = 9 days)"
## or "SPLAT Detailed Average Event Counts, Summer (n = 8 days)" in a
## metrics file. Used below to build the "N" / "N-M" analysis-period
## text automatically included in Step4's Methods section narrative,
## instead of a manual placeholder someone had to read out of the files
## by hand and update for every report.
extract_days_count <- function(fileName, label, season) {
  fileData <- scan(fileName, what = "character", sep = "\n", blank.lines.skip = FALSE, quiet = TRUE)
  search_str <- paste0(label, ", ", season)
  hit <- fileData[grepl(search_str, fileData, fixed = TRUE)]
  if (length(hit) == 0) return(NA_integer_)
  m <- regmatches(hit[1], regexpr("\\(n\\s*=\\s*\\d+\\s*days?\\)", hit[1]))
  if (length(m) == 0) return(NA_integer_)
  as.integer(gsub("[^0-9]", "", m))
}

## Converts a count of seconds to a "MM:SS" string - used as the y-axis
## label formatter for the Noise-Free Interval plot below. (A function of
## the same name/purpose also exists independently in Step4's Rmd, for
## formatting the SPLAT event-length table there - the two are not
## shared code, just the same small conversion needed in two places.)
sec_to_mmss <- function(x) {
  x <- round(as.numeric(x))
  m <- x %/% 60
  s <- x %% 60
  sprintf("%02d:%02d", m, s)
}

open_file_default_app <- function(path) {
  tryCatch({
    if (.Platform$OS.type == "windows") {
      shell.exec(path)
    } else if (Sys.info()["sysname"] == "Darwin") {
      system2("open", shQuote(path))
    } else {
      system2("xdg-open", shQuote(path))
    }
    TRUE
  }, error = function(e) {
    message("Could not auto-open the file (", conditionMessage(e), "). Please open it manually:\n  ", path)
    FALSE
  })
}

## Pops up a small "OK" dialog box in addition to a console message, so
## instructions aren't missed if a file dialog or Excel window is about
## to grab focus and bury the R console. Falls back to console-only if
## no GUI toolkit is available (e.g. running headless).
notify <- function(message_text, title = "Acoustic Report Script") {
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

## ---------------------------------------------------------------------
## 1. PACKAGES
## ---------------------------------------------------------------------

packages <- c("reshape2", "ggplot2", "ggthemes", "plyr", "lubridate",
              "tidyverse", "data.table", "readr", "sjmisc", "janitor",
              "dplyr", "scales", "english", "rlist", "jsonlite", "tcltk",
              "openxlsx", "rvest", "httr", "xml2")

lapply(packages, function(pkg) {
  if (!require(pkg, character.only = TRUE)) {
    install.packages(pkg, dependencies = TRUE)
    library(pkg, character.only = TRUE)
  }
})

## ---------------------------------------------------------------------
## 2. DETERMINE SCRIPT LOCATION -> anchor for REPORTS output folder
##    Mirrors the old Rmd's: report_dir <- "./../../REPORTS/<alpha_code>"
##    i.e. REPORTS lives two folders up from wherever this .R file lives,
##    NOT inside whatever project folder you browse to below.
## ---------------------------------------------------------------------

get_script_dir <- function() {
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
    if (!is.null(ctx) && nzchar(ctx$path)) {
      return(dirname(normalizePath(ctx$path, winslash = "/")))
    }
  }
  cmd_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", cmd_args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/")))
  }
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile) && nzchar(ofile)) {
    return(dirname(normalizePath(ofile, winslash = "/")))
  }
  message("Could not automatically determine this script's location.")
  message("Please select this .R script file so its folder can be used as the anchor for REPORTS.")
  dirname(normalizePath(file.choose(), winslash = "/"))
}

script_dir <- get_script_dir()
report_dir <- normalizePath(file.path(script_dir, "..", "..", "REPORTS"),
                            winslash = "/", mustWork = FALSE)
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
message("Reports will be written under: ", report_dir)

## ---------------------------------------------------------------------
## 3. LOCATE + SOURCE DEPENDENCIES
## ---------------------------------------------------------------------

message("Select readMetrics.R ...")
notify("A file browser is about to open.\n\nPlease select your readMetrics.R script.",
       title = "Select readMetrics.R")
readmetrics_path <- file.choose()
source(readmetrics_path)

message("Select sourceid.rds ...")
notify("A file browser is about to open.\n\nPlease select your sourceid.rds file.",
       title = "Select sourceid.rds")
sourceid_path <- file.choose()
sourceid <- readRDS(sourceid_path)

npsunits <- tryCatch(
  jsonlite::fromJSON("https://irmaservices.nps.gov/Unit/v2/api/?format=json"),
  error = function(e) {
    warning("Could not reach NPS units service; park full names will fall back to unit code.")
    NULL
  }
)

## ---------------------------------------------------------------------
## 4. SELECT PROJECT FOLDER
## ---------------------------------------------------------------------

select_folder <- function(caption = "Select project folder") {
  path <- NA_character_
  
  if (requireNamespace("rstudioapi", quietly = TRUE) && rstudioapi::isAvailable()) {
    path <- tryCatch(rstudioapi::selectDirectory(caption = caption),
                     error = function(e) NA_character_)
  }
  
  if ((is.na(path) || path == "") && requireNamespace("tcltk", quietly = TRUE)) {
    path <- tryCatch(tcltk::tk_choose.dir(caption = caption),
                     error = function(e) NA_character_)
  }
  
  if ((is.na(path) || path == "") && .Platform$OS.type == "windows") {
    path <- tryCatch(utils::choose.dir(caption = caption),
                     error = function(e) NA_character_)
  }
  
  if (is.na(path) || path == "") {
    stop("No folder selected. If this happened while using 'Source', try ",
         "selecting just this line and pressing Ctrl+Enter instead - dialog ",
         "windows can occasionally open behind RStudio when a whole script ",
         "is sourced at once.")
  }
  
  normalizePath(path, winslash = "/")
}

notify("A folder browser is about to open.\n\nPlease select the project folder that contains (or contains subfolders with) your METRICS_*.txt files.",
       title = "Select project folder")
project_path <- select_folder()
message("Project folder: ", project_path)

## ---------------------------------------------------------------------
## 5. RECURSIVELY FIND METRICS FILES + LET USER PICK SUBSET
## ---------------------------------------------------------------------

all_metrics_files <- list.files(
  path = project_path,
  pattern = "^METRICS_.*\\.txt$",
  full.names = TRUE,
  recursive = TRUE,
  ignore.case = TRUE
)

if (length(all_metrics_files) == 0) stop("No METRICS_*.txt files found under the selected folder.")

message(sprintf("Found %d metrics file(s).", length(all_metrics_files)))

# FIXED: previously used bare basename(all_metrics_files) as both the
# checklist labels AND the match key back to full paths
# (metricsFilesAll <- all_metrics_files[file_choices %in% picked]).
# That breaks in exactly the scenario this pipeline needs to support:
# the same site/year exported ONCE PER SEASON, where each season's
# export can end up with the IDENTICAL filename (e.g.
# "METRICS__2022_ANDE002.txt" appearing under two different season
# subfolders). With bare basenames, those two different files were
# visually indistinguishable in the picker, and %in% matches by VALUE
# (not by which row was actually checked) - so picking either one
# silently pulled in BOTH files, with no way to tell them apart or
# choose independently.
#
# Fix: whenever a basename collides with another file's, append that
# file's parent folder to its label, so duplicates are both visible and
# individually selectable. Matching downstream uses these same
# disambiguated labels rather than the raw basename.
file_basenames <- basename(all_metrics_files)
dup_basename <- file_basenames %in% file_basenames[duplicated(file_basenames)]
file_choices <- ifelse(
  dup_basename,
  paste0(file_basenames, "  [", basename(dirname(all_metrics_files)), "]"),
  file_basenames
)

if (any(dup_basename)) {
  message(sum(dup_basename), " file(s) share an identical filename with another file found under a ",
          "different folder (e.g. the same site/year exported once per season). These are labeled ",
          "below with their parent folder in brackets so you can tell them apart and select each one.")
}

notify(paste0("A checklist window is about to open with ", length(file_choices), " metrics file(s) found.\n\n",
              "Check the box next to each file you want included in this run, then click OK.\n\n",
              "Not all files need to be selected - only the ones you want processed now."),
       title = "Select metrics files")
picked <- select.list(
  choices = file_choices,
  multiple = TRUE,
  title = "Select metrics files to include in this run"
)

if (length(picked) == 0) stop("No metrics files selected.")

metricsFilesAll <- all_metrics_files[file_choices %in% picked]

## ---------------------------------------------------------------------
## 6. FIX MISSING TABS (Lnat / L50 merge issue) ON SELECTED FILES
## ---------------------------------------------------------------------

fix_missing_tabs_in_lines <- function(lines, scope = c("any", "day_night")) {
  scope <- match.arg(scope)
  insert_tab <- function(x) gsub("(?<=--\\.-)(?=\\d)", "\t", x, perl = TRUE)
  if (scope == "any") {
    return(insert_tab(lines))
  } else {
    day_night <- grepl("^\\s*(Day|Night)\\b", lines)
    lines_fixed <- lines
    lines_fixed[day_night] <- insert_tab(lines[day_night])
    return(lines_fixed)
  }
}

fix_missing_tabs_file <- function(path, backup = TRUE, scope = c("any", "day_night")) {
  scope <- match.arg(scope)
  lines <- readLines(path, warn = FALSE)
  lines_fixed <- fix_missing_tabs_in_lines(lines, scope = scope)
  changed <- !identical(lines, lines_fixed)
  if (!changed) {
    message(sprintf("[SKIP] No change needed: %s", path))
    return(invisible(FALSE))
  }
  if (backup) writeLines(lines, con = paste0(path, ".bak"), useBytes = TRUE)
  writeLines(lines_fixed, con = path, useBytes = TRUE)
  message(sprintf("[FIXED] %s%s", path, if (backup) " (backup created)" else ""))
  invisible(TRUE)
}

invisible(lapply(metricsFilesAll, fix_missing_tabs_file, backup = TRUE, scope = tabfix_scope))

## ---------------------------------------------------------------------
## 7. DETECT SEASON PRESENCE + LC/SPLAT PRESENCE PER FILE
## ---------------------------------------------------------------------

all_seasons <- c("Winter", "Spring", "Summer", "Fall")

season_present <- function(fileData, season) {
  length(grep(paste0("Median Hourly Metrics \\(dBA\\), ", season), fileData)) > 0
}
has_section <- function(fileData, label) {
  any(grepl(label, fileData, fixed = TRUE))
}

file_info <- lapply(metricsFilesAll, function(f) {
  fd <- scan(f, what = "character", sep = "\n", blank.lines.skip = FALSE, quiet = TRUE)
  # FIXED: previously "(?<=METRICS_)\\d{4}" - required the year to sit
  # immediately after exactly ONE literal underscore following
  # "METRICS". Files exported one-per-season by the Acoustic Monitoring
  # Toolbox can come out with an EXTRA underscore
  # ("METRICS__2022_SITE.txt" instead of "METRICS_2022_SITE.txt"), which
  # made that lookbehind fail to match anything - yr silently became NA,
  # and any combo with a NA year never merges into the season_order_
  # lookup.csv table, so it vanishes from processing entirely with no
  # error. This version instead matches any run of exactly 4 digits with
  # an underscore immediately on each side - it no longer anchors on the
  # literal "METRICS_" prefix at all, so it's indifferent to how many
  # underscores separate "METRICS" from the year.
  yr  <- str_extract(basename(f), "(?<=_)\\d{4}(?=_)")
  sid <- str_extract(basename(f), "(?<=_)[^_]+(?=\\.txt$)")
  park_code <- substr(sid, 1, 4)
  seasons_here <- all_seasons[sapply(all_seasons, function(s) season_present(fd, s))]
  list(
    file = f,
    year = yr,
    site = sid,
    park_code = park_code,
    seasons = seasons_here,
    has_lc = has_section(fd, "Listening Center"),
    has_splat = has_section(fd, "SPLAT")
  )
})

# Surfaces the failure loudly instead of letting affected files silently
# disappear a few steps later when they fail to merge into the order
# lookup table - if this fires, the filename doesn't match the expected
# "...<underscore>YYYY<underscore>SITEID.txt" pattern at all and needs a
# closer look (e.g. a typo, or a genuinely different naming scheme).
bad_year <- vapply(file_info, function(fi) is.na(fi$year), logical(1))
if (any(bad_year)) {
  warning("Could not extract a 4-digit year from the following filename(s) - these will be EXCLUDED from processing:\n",
          paste("  ", sapply(file_info[bad_year], `[[`, "file"), collapse = "\n"),
          "\nExpected pattern: ...METRICS<underscore(s)>YYYY<underscore>SITEID.txt")
}

parks_found <- unique(sapply(file_info, `[[`, "park_code"))
if (length(parks_found) > 1) {
  stop("Selected files span multiple parks (", paste(parks_found, collapse = ", "),
       "). Please run one park at a time.")
}
park_code <- parks_found[1]
all_site_ids <- sort(unique(sapply(file_info, `[[`, "site")))

## ---------------------------------------------------------------------
## 8. BUILD LIST OF SEASON+YEAR COMBOS PRESENT; MANAGE ORDER LOOKUP
## ---------------------------------------------------------------------

combo_rows <- do.call(rbind, lapply(file_info, function(fi) {
  if (length(fi$seasons) == 0) return(NULL)
  data.frame(Park = fi$park_code, Season = fi$seasons, Year = fi$year,
             stringsAsFactors = FALSE)
}))
combos <- unique(combo_rows)
combos <- combos[order(combos$Year, combos$Season), ]

park_report_dir <- file.path(report_dir, park_code)
dir.create(park_report_dir, recursive = TRUE, showWarnings = FALSE)

lookup_path <- file.path(park_report_dir, paste0(park_code, "_season_order_lookup.csv"))

if (file.exists(lookup_path)) {
  lookup <- read.csv(lookup_path, stringsAsFactors = FALSE)
} else {
  lookup <- data.frame(Park = character(), Season = character(),
                       Year = character(), Order = integer(),
                       stringsAsFactors = FALSE)
}

merged <- merge(combos, lookup, by = c("Park", "Season", "Year"), all.x = TRUE)
new_rows <- is.na(merged$Order)

if (any(new_rows)) {
  write.csv(merged, lookup_path, row.names = FALSE)
  
  notify(paste0(
    "New Season/Year combinations were found that don't have an 'Order' ",
    "assigned yet (i.e. which numbered monitoring season this was for the ",
    "park, e.g. Winter 2019 = 1, Spring 2019 = 2, etc).\n\n",
    "This file is about to open:\n", lookup_path, "\n\n",
    "Fill in the Order column for any blank rows, then SAVE and CLOSE the ",
    "file. Come back to R afterward and press Enter to continue."
  ), title = "Fill in Order column")
  
  open_file_default_app(lookup_path)
  invisible(readline(prompt = "Press [Enter] once the lookup file is saved and closed... "))
  
  lookup <- tryCatch(read.csv(lookup_path, stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(lookup)) {
    notify(paste0("Could not read the lookup file back in - it may still be open in Excel ",
                  "(which locks the file).\n\nClose it completely, then click OK/press Enter to try again."),
           title = "File still open?")
    invisible(readline(prompt = "Press [Enter] to retry reading the lookup file... "))
    lookup <- read.csv(lookup_path, stringsAsFactors = FALSE)
  }
  merged <- merge(combos, lookup, by = c("Park", "Season", "Year"), all.x = TRUE)
}

still_missing <- is.na(merged$Order)
if (any(still_missing)) {
  warning("The following Season/Year combos still have no Order assigned ",
          "and will be skipped:\n",
          paste(sprintf("  %s %s", merged$Season[still_missing], merged$Year[still_missing]),
                collapse = "\n"))
}

run_combos <- merged[!still_missing, ]

## ---------------------------------------------------------------------
## 9. HELPER: get park full name
## ---------------------------------------------------------------------

get_park_name <- function(unit_code) {
  if (is.null(npsunits)) return(unit_code)
  hit <- npsunits[npsunits$UnitCode == unit_code, ]
  if (nrow(hit) == 0) return(unit_code)
  hit$FullName[1]
}

parkname <- get_park_name(park_code)

## ---------------------------------------------------------------------
## 9b. SITESMETA FOLDER: common images + site metadata table
##     Lives at <REPORTS>/<park_code>/SitesMeta - shared across all
##     season/year reports for this park (maps, legends, SiteMeta.xlsx).
## ---------------------------------------------------------------------

sitesmeta_dir <- file.path(park_report_dir, "SitesMeta")
dir.create(sitesmeta_dir, recursive = TRUE, showWarnings = FALSE)

## -- Copy common reference images -----------------------------------------
if (copy_common_images) {
  common_images_path <- normalizePath(file.path(script_dir, common_images_reldir),
                                      winslash = "/", mustWork = FALSE)
  if (dir.exists(common_images_path)) {
    commonpngfiles <- list.files(path = common_images_path, pattern = "\\.png$", full.names = TRUE)
    if (length(commonpngfiles) > 0) {
      file.copy(commonpngfiles, sitesmeta_dir, overwrite = TRUE)
      message(sprintf("Copied %d common image(s) to %s", length(commonpngfiles), sitesmeta_dir))
    } else {
      message("No common PNG files found at: ", common_images_path)
    }
  } else {
    message("Common images folder not found (skipping): ", common_images_path)
  }
}

## -- Build / update SiteMeta.xlsx -------------------------------------------
if (build_sitemeta) {
  
  format_mdy <- function(d) paste0(as.integer(format(d, "%m")), "/", as.integer(format(d, "%d")), "/", format(d, "%Y"))
  
  extract_site_dates <- function(nvspl_dir) {
    files <- list.files(nvspl_dir, full.names = FALSE)
    re <- "^NVSPL_([A-Za-z0-9]+)_(\\d{4})_(\\d{2})_(\\d{2})_(\\d{2})(?:\\.[A-Za-z0-9]+)?$"
    m <- str_match(files, re)
    m <- m[!is.na(m[, 1]), , drop = FALSE]
    if (nrow(m) == 0) return(NULL)
    site_codes <- unique(m[, 2])
    site <- if (length(site_codes) == 1) site_codes[1] else
      str_split(basename(dirname(nvspl_dir)), "_", n = 2, simplify = TRUE)[1]
    years <- as.integer(m[, 3]); months <- as.integer(m[, 4]); days <- as.integer(m[, 5])
    dates <- suppressWarnings(make_date(years, months, days))
    dates <- dates[!is.na(dates)]
    if (length(dates) == 0) return(NULL)
    list(Site = site, StartDate = min(dates), EndDate = max(dates))
  }
  
  build_site_aggregates <- function(deployment_dirs) {
    rows <- lapply(deployment_dirs, function(dep) {
      nvspl_dir <- file.path(dep, "NVSPL")
      if (!dir.exists(nvspl_dir)) { message(sprintf("Skipping (no NVSPL): %s", dep)); return(NULL) }
      info <- extract_site_dates(nvspl_dir)
      if (is.null(info)) { message(sprintf("Skipping (no valid NVSPL files): %s", nvspl_dir)); return(NULL) }
      data.frame(Site = info$Site, StartDate = info$StartDate, EndDate = info$EndDate, stringsAsFactors = FALSE)
    })
    per_dep <- do.call(rbind, rows)
    if (is.null(per_dep) || nrow(per_dep) == 0) {
      message("No valid NVSPL folders/files found; skipping SiteMeta build.")
      return(NULL)
    }
    agg <- aggregate(cbind(StartDate, EndDate) ~ Site, data = per_dep,
                     FUN = function(x) c(min = min(x), max = max(x)))
    out <- data.frame(
      Site      = agg$Site,
      StartDate = as.Date(agg$StartDate[, "min"]),
      EndDate   = as.Date(agg$EndDate[, "max"]),
      stringsAsFactors = FALSE
    )
    out$Dates <- paste0(format_mdy(out$StartDate), " - ", format_mdy(out$EndDate))
    out[order(out$Site), c("Site", "Dates")]
  }
  
  ## Merges freshly computed Site/Dates rows into any existing SiteMeta.xlsx,
  ## preserving manually-entered columns (Site Name, Vegetation, Wilderness,
  ## Elevation, Latitude, Longitude) for sites already listed, and writes
  ## the result out. Used whether or not NVSPL-derived dates are available.
  write_sitemeta_xlsx <- function(site_dates, sitemeta_path) {
    existing <- if (file.exists(sitemeta_path)) {
      tryCatch(openxlsx::read.xlsx(sitemeta_path), error = function(e) NULL)
    } else NULL
    
    ## Use Latitude/Longitude from site_dates if the deployment-locations
    ## lookup already populated them; otherwise start blank as before.
    lat_vals <- if ("Latitude" %in% names(site_dates)) site_dates$Latitude else NA_real_
    lon_vals <- if ("Longitude" %in% names(site_dates)) site_dates$Longitude else NA_real_
    
    out_df <- data.frame(
      Site            = site_dates$Site,
      `Site Name`     = NA_character_,
      Dates           = site_dates$Dates,
      Vegetation      = NA_character_,
      Wilderness      = NA_character_,
      `Elevation (m)` = NA_real_,
      Latitude        = lat_vals,
      Longitude       = lon_vals,
      check.names     = FALSE
    )
    
    if (!is.null(existing) && "Site" %in% names(existing)) {
      keep_cols <- setdiff(names(existing), c("Site", "Dates"))
      out_df <- merge(out_df[, c("Site", "Dates", "Latitude", "Longitude")],
                      existing[, c("Site", keep_cols), drop = FALSE],
                      by = "Site", all.x = TRUE, all.y = TRUE, suffixes = c("_new", ""))
      # all.y=TRUE keeps any manually-added sites/rows already in the file
      
      # Latitude/Longitude: prefer the EXISTING file's values (in case
      # someone hand-edited them there), but fall back to the newly
      # auto-filled ones (from the deployment locations lookup) wherever
      # the existing file's value is blank. Never lose a just-fetched
      # coordinate to a blank in an older SiteMeta.xlsx.
      if ("Latitude_new" %in% names(out_df)) {
        out_df$Latitude <- ifelse(is.na(out_df$Latitude), out_df$Latitude_new, out_df$Latitude)
        out_df$Latitude_new <- NULL
      }
      if ("Longitude_new" %in% names(out_df)) {
        out_df$Longitude <- ifelse(is.na(out_df$Longitude), out_df$Longitude_new, out_df$Longitude)
        out_df$Longitude_new <- NULL
      }
      
      out_df$Dates[is.na(out_df$Dates)] <- ""
      
      # Guard against an existing SiteMeta.xlsx that's missing one or more
      # of the expected columns (e.g. hand-edited, or from an earlier
      # version of this script) - fill in any that didn't survive the
      # merge so the column-order subset below can never fail.
      expected_cols <- c("Site", "Site Name", "Dates", "Vegetation",
                         "Wilderness", "Elevation (m)", "Latitude", "Longitude")
      missing_cols <- setdiff(expected_cols, names(out_df))
      for (mc in missing_cols) out_df[[mc]] <- NA
      
      out_df <- out_df[, expected_cols]
    }
    
    wb <- createWorkbook()
    addWorksheet(wb, "Sheet1")
    writeData(wb, sheet = "Sheet1", x = out_df)
    saveWorkbook(wb, sitemeta_path, overwrite = TRUE)
    message("SiteMeta.xlsx written to: ", sitemeta_path)
  }
  
  ## -- Deployment Locations lookup: auto-fill Lat/Long from an export of -----
  ## the NSNSD Deployment Locations report where a matching Site ID exists.
  
  ## Checks pattern groups IN PRIORITY ORDER, stopping at the first group
  ## with any match, rather than OR-ing all patterns together (which could
  ## incorrectly prefer a less-specific column just because it happens to
  ## appear earlier in the dataframe - e.g. "UnitName" vs "SiteCode").
  find_col <- function(df, pattern_groups) {
    for (grp in pattern_groups) {
      hit <- names(df)[grepl(grp, names(df), ignore.case = TRUE)]
      if (length(hit) > 0) return(hit[1])
    }
    NA_character_
  }
  
  ## Given any data.frame-like table, finds Site/Latitude/Longitude-like
  ## columns and returns a clean 3-column data.frame, or NULL if it can't
  ## find a usable combination. Site-column patterns are ordered from most
  ## to least specific - "SiteCode"/"Site ID" should always win over a
  ## looser fallback like a generic "Site" prefix, and "UnitName"/park-
  ## level fields are deliberately NOT matched here, since they identify
  ## the park, not the individual monitoring site.
  extract_site_lat_lon <- function(tbl) {
    if (is.null(tbl) || nrow(tbl) == 0) return(NULL)
    site_col <- find_col(tbl, list("^site.?code$", "^site.?id$", "^site$", "^site"))
    lat_col  <- find_col(tbl, list("^latitude$", "^lat$", "^lat"))
    lon_col  <- find_col(tbl, list("^longitude$", "^lon$", "^lon"))
    if (is.na(site_col) || is.na(lat_col) || is.na(lon_col)) return(NULL)
    out <- data.frame(
      Site = as.character(tbl[[site_col]]),
      Latitude = suppressWarnings(as.numeric(tbl[[lat_col]])),
      Longitude = suppressWarnings(as.numeric(tbl[[lon_col]])),
      stringsAsFactors = FALSE
    )
    out[!is.na(out$Site) & out$Site != "", ]
  }
  
  parse_deployment_locations_csv <- function(path) {
    d <- tryCatch(read.csv(path, stringsAsFactors = FALSE, check.names = FALSE), error = function(e) NULL)
    extract_site_lat_lon(d)
  }
  
  parse_deployment_locations_xml <- function(path) {
    tryCatch({
      doc <- xml2::read_xml(path)
      ## Generic approach: find the most common repeating child node (the
      ## "record" element) and pull its immediate children as fields.
      all_nodes <- xml2::xml_find_all(doc, ".//*")
      node_names <- xml2::xml_name(all_nodes)
      tbl_name <- names(sort(table(node_names), decreasing = TRUE))[1]
      records <- xml2::xml_find_all(doc, paste0(".//", tbl_name))
      if (length(records) < 2) return(NULL)  # not a repeating record structure
      
      rows <- lapply(records, function(r) {
        kids <- xml2::xml_children(r)
        if (length(kids) == 0) return(NULL)
        vals <- as.list(xml2::xml_text(kids))
        names(vals) <- xml2::xml_name(kids)
        as.data.frame(vals, stringsAsFactors = FALSE)
      })
      rows <- rows[!sapply(rows, is.null)]
      if (length(rows) == 0) return(NULL)
      d <- dplyr::bind_rows(rows)
      extract_site_lat_lon(d)
    }, error = function(e) {
      message("Could not parse XML file (", conditionMessage(e), ").")
      NULL
    })
  }
  
  parse_deployment_locations_mhtml <- function(path) {
    tryCatch({
      raw <- readLines(path, warn = FALSE, encoding = "UTF-8")
      full_text <- paste(raw, collapse = "\n")
      ## MHTML wraps HTML in a MIME envelope, often quoted-printable
      ## encoded. Strip down to the first <html...>...</html> block and
      ## hand it to the same HTML table parser used for the live fetch.
      html_start <- regexpr("<html", full_text, ignore.case = TRUE)
      html_end <- regexpr("</html>", full_text, ignore.case = TRUE)
      if (html_start < 0 || html_end < 0) {
        message("Could not find an HTML block inside this MHTML file - this format is the least reliable of the options; CSV is recommended instead.")
        return(NULL)
      }
      html_chunk <- substr(full_text, html_start, html_end + attr(html_end, "match.length"))
      ## Undo quoted-printable soft line breaks ("=\n") which MHTML commonly uses
      html_chunk <- gsub("=\\r?\\n", "", html_chunk)
      html_chunk <- gsub("=3D", "=", html_chunk, fixed = TRUE)
      
      page <- rvest::read_html(html_chunk)
      tables <- rvest::html_table(page, fill = TRUE)
      for (tbl in tables) {
        hit <- extract_site_lat_lon(tbl)
        if (!is.null(hit) && nrow(hit) > 0) return(hit)
      }
      NULL
    }, error = function(e) {
      message("Could not parse MHTML file (", conditionMessage(e), "). CSV is recommended instead of MHTML.")
      NULL
    })
  }
  
  ## Prompts you to browse to a local export of the Deployment Locations
  ## report and parses it based on file extension.
  get_deployment_locations_via_prompt <- function() {
    notify(paste0(
      "A file browser is about to open.\n\n",
      "Select your exported Deployment Locations file (CSV, XML, or MHTML).\n\n",
      "CSV is the most reliable format if your export tool gives you a choice."
    ), title = "Select Deployment Locations export")
    
    path <- tryCatch(file.choose(), error = function(e) NA_character_)
    if (is.na(path)) {
      message("No file selected - skipping Deployment Locations lookup for this run.")
      return(NULL)
    }
    
    ext <- tolower(tools::file_ext(path))
    result <- switch(ext,
                     "csv" = parse_deployment_locations_csv(path),
                     "txt" = parse_deployment_locations_csv(path),
                     "xml" = parse_deployment_locations_xml(path),
                     "mhtml" = parse_deployment_locations_mhtml(path),
                     "mht" = parse_deployment_locations_mhtml(path),
                     {
                       message("Unrecognized file extension '.", ext, "' - expected .csv, .xml, .mhtml, or .mht.")
                       NULL
                     }
    )
    
    if (is.null(result) || nrow(result) == 0) {
      message("Could not extract Site/Latitude/Longitude data from that file.")
      return(NULL)
    }
    message(sprintf("  Loaded %d site location(s) from: %s", nrow(result), basename(path)))
    result
  }
  
  ## EXPERIMENTAL: attempts to pull data live from a .atomsvc OData feed
  ## using the current Windows session for authentication (via httr's
  ## automatic NTLM/Kerberos support, if applicable to your network).
  ## This is UNVERIFIED against the actual NSNSD reporting tool - if it
  ## fails for any reason, it returns NULL and the caller falls back to
  ## the file-prompt method.
  get_deployment_locations_via_atomsvc <- function(feed_url) {
    if (!nzchar(feed_url)) {
      message("deployment_locations_atomsvc_url is empty - falling back to file selection.")
      return(NULL)
    }
    message("Attempting experimental live fetch from .atomsvc feed (this may fail if authentication isn't supported non-interactively) ...")
    tryCatch({
      svc_doc <- httr::content(httr::GET(feed_url, httr::authenticate(":", ":", type = "auto")), as = "text", encoding = "UTF-8")
      doc <- xml2::read_xml(svc_doc)
      ns <- xml2::xml_ns(doc)
      collection_hrefs <- xml2::xml_attr(xml2::xml_find_all(doc, ".//d1:collection", ns = c(d1 = "http://www.w3.org/2007/app")), "href")
      if (length(collection_hrefs) == 0) {
        message("  Could not find a data collection in the .atomsvc document - falling back to file selection.")
        return(NULL)
      }
      ## The collection href in NPS's SSRS-generated .atomsvc files has been
      ## observed to already be a complete, absolute URL (not a relative
      ## path to be joined onto the .atomsvc's own location) - use it as-is
      ## when it looks absolute, only falling back to path-joining otherwise.
      feed_data_url <- if (grepl("^https?://", collection_hrefs[1], ignore.case = TRUE)) {
        collection_hrefs[1]
      } else {
        base_url <- sub("/[^/]*\\.atomsvc.*$", "", feed_url)
        paste0(base_url, "/", collection_hrefs[1])
      }
      feed_resp <- httr::content(httr::GET(feed_data_url, httr::authenticate(":", ":", type = "auto")), as = "text", encoding = "UTF-8")
      feed_xml <- xml2::read_xml(feed_resp)
      entries <- xml2::xml_find_all(feed_xml, ".//*[local-name()='entry']//*[local-name()='properties']")
      if (length(entries) == 0) {
        message("  .atomsvc feed returned no entries - falling back to file selection.")
        return(NULL)
      }
      rows <- lapply(entries, function(e) {
        kids <- xml2::xml_children(e)
        vals <- as.list(xml2::xml_text(kids))
        names(vals) <- xml2::xml_name(kids)
        as.data.frame(vals, stringsAsFactors = FALSE)
      })
      d <- dplyr::bind_rows(rows)
      result <- extract_site_lat_lon(d)
      if (is.null(result) || nrow(result) == 0) {
        message("  Could not find usable Site/Latitude/Longitude fields in the feed - falling back to file selection.")
        return(NULL)
      }
      message(sprintf("  Retrieved %d site location(s) live from the .atomsvc feed.", nrow(result)))
      result
    }, error = function(e) {
      message("  Live .atomsvc fetch failed (", conditionMessage(e), ") - falling back to file selection.")
      NULL
    })
  }
  
  get_deployment_locations <- function() {
    if (deployment_locations_source == "atomsvc_live") {
      live <- get_deployment_locations_via_atomsvc(deployment_locations_atomsvc_url)
      if (!is.null(live)) return(live)
      message("Falling back to manual file selection for Deployment Locations.")
    }
    get_deployment_locations_via_prompt()
  }
  
  ## Fills Latitude/Longitude in site_dates from the deployment locations
  ## lookup table, matching on Site (case/whitespace-insensitive exact
  ## match). Only fills currently-blank coordinates - never overwrites.
  apply_deployment_locations <- function(site_dates, lookup_df) {
    if (is.null(lookup_df) || nrow(lookup_df) == 0) return(site_dates)
    
    if (!"Latitude" %in% names(site_dates)) site_dates$Latitude <- NA_real_
    if (!"Longitude" %in% names(site_dates)) site_dates$Longitude <- NA_real_
    
    norm <- function(x) toupper(trimws(as.character(x)))
    lookup_df$.norm_site <- norm(lookup_df$Site)
    lookup_df <- lookup_df[!duplicated(lookup_df$.norm_site), ]  # first match wins if duplicates exist
    
    matched <- 0
    for (i in seq_len(nrow(site_dates))) {
      if (!is.na(site_dates$Latitude[i]) && !is.na(site_dates$Longitude[i])) next  # never overwrite existing values
      hit <- lookup_df[lookup_df$.norm_site == norm(site_dates$Site[i]), ]
      if (nrow(hit) == 1 && is.finite(hit$Latitude[1]) && is.finite(hit$Longitude[1])) {
        site_dates$Latitude[i] <- hit$Latitude[1]
        site_dates$Longitude[i] <- hit$Longitude[1]
        matched <- matched + 1
      }
    }
    message(sprintf("Deployment Locations lookup: auto-filled coordinates for %d of %d site(s).",
                    matched, nrow(site_dates)))
    site_dates
  }
  
  message("\n--------------------------------------------------------------")
  message("SiteMeta.xlsx: select the parent folder containing this park's")
  message("deployment folders (each with an NVSPL subfolder), to auto-fill")
  message("monitoring date ranges. Cancel the dialog if you don't have")
  message("access to that folder right now - SiteMeta.xlsx will still be")
  message("built with the site IDs already known from your selected")
  message("metrics files, with blank Dates you can fill in by hand.")
  message("--------------------------------------------------------------")
  
  notify(paste0(
    "A folder browser is about to open.\n\n",
    "Select the PARENT folder that contains this park's deployment folders ",
    "(each deployment folder should have an NVSPL subfolder inside it).\n\n",
    "If you don't have access to that folder right now, click Cancel in the ",
    "browser - SiteMeta.xlsx will still be created using the site IDs already ",
    "known from your selected metrics files, with blank Dates you can fill in by hand."
  ), title = "Select deployment parent folder")
  
  parent_dir <- tryCatch(
    select_folder("Select parent folder containing deployment folders (Cancel to skip)"),
    error = function(e) NA_character_
  )
  
  site_dates <- NULL
  
  if (!is.na(parent_dir) && dir.exists(parent_dir)) {
    candidates      <- list.dirs(parent_dir, recursive = FALSE, full.names = TRUE)
    has_nvspl       <- dir.exists(file.path(candidates, "NVSPL"))
    named_ok        <- grepl("^[A-Za-z0-9]+_\\d{8}$", basename(candidates))
    deployment_dirs <- candidates[has_nvspl & named_ok]
    
    if (length(deployment_dirs) == 0) {
      message("No deployment folders found under: ", parent_dir, " - will build SiteMeta from known site IDs instead.")
    } else {
      dep_choices <- basename(deployment_dirs)
      notify(paste0("A checklist window is about to open with ", length(dep_choices),
                    " deployment folder(s) found.\n\n",
                    "Check the box next to each deployment you want included, then click OK."),
             title = "Select deployment folders")
      dep_picked <- select.list(
        choices = dep_choices,
        multiple = TRUE,
        title = "Select deployment folders to include in SiteMeta"
      )
      if (length(dep_picked) == 0) {
        message("No deployment folders selected - will build SiteMeta from known site IDs instead.")
      } else {
        deployment_dirs <- deployment_dirs[dep_choices %in% dep_picked]
        site_dates <- build_site_aggregates(deployment_dirs)
      }
    }
  } else {
    message("No folder selected - will build SiteMeta from known site IDs instead.")
  }
  
  ## Fallback: no NVSPL-derived dates available (cancelled, none found, or
  ## none picked) - build a skeleton from the site IDs already parsed out
  ## of the metrics files, with a blank Dates column to fill in by hand.
  if (is.null(site_dates)) {
    if (length(all_site_ids) == 0) {
      message("No known site IDs available either - skipping SiteMeta.xlsx entirely.")
    } else {
      site_dates <- data.frame(Site = all_site_ids, Dates = "", stringsAsFactors = FALSE)
    }
  }
  
  if (!is.null(site_dates) && use_deployment_locations_lookup) {
    deployment_locs <- get_deployment_locations()
    site_dates <- apply_deployment_locations(site_dates, deployment_locs)
  }
  
  if (!is.null(site_dates)) {
    sitemeta_path <- file.path(sitesmeta_dir, "SiteMeta.xlsx")
    write_sitemeta_xlsx(site_dates, sitemeta_path)
    
    if (prompt_open_sitemeta) {
      notify(paste0(
        "SiteMeta.xlsx is about to open.\n\n",
        "Fill in Latitude/Longitude (and any other columns you'd like, ",
        "e.g. Site Name, Elevation). SAVE and CLOSE the file completely ",
        "when you're done, then come back to R and press Enter."
      ), title = "Fill in SiteMeta.xlsx")
      open_file_default_app(sitemeta_path)
      invisible(readline(prompt = "Press [Enter] once SiteMeta.xlsx is saved and closed... "))
      
      reread_check <- tryCatch(openxlsx::read.xlsx(sitemeta_path), error = function(e) NULL)
      if (is.null(reread_check)) {
        notify(paste0("Could not read SiteMeta.xlsx back in - it may still be open in Excel ",
                      "(which locks the file).\n\nClose it completely, then click OK/press Enter to confirm."),
               title = "File still open?")
        invisible(readline(prompt = "Close the file completely, then press [Enter] to confirm... "))
      }
    }
  }
}

## ---------------------------------------------------------------------
## 10. MAIN LOOP: one pass per Season+Year combo
## ---------------------------------------------------------------------

for (r in seq_len(nrow(run_combos))) {
  
  season <- run_combos$Season[r]
  year   <- run_combos$Year[r]
  order  <- run_combos$Order[r]
  
  message(sprintf("\n=== Processing %s %s (order %s) ===", season, year, order))
  
  ## -- files relevant to this combo --------------------------------
  combo_info <- Filter(function(fi) fi$year == year && season %in% fi$seasons, file_info)
  metricsFiles <- sapply(combo_info, `[[`, "file")
  names_ <- sapply(combo_info, `[[`, "site")   # site IDs, aligned with metricsFiles
  
  if (length(metricsFiles) == 0) {
    message("  No files for this combo; skipping.")
    next
  }
  
  sitecount <- as.character(english::english(length(names_)))
  
  lc_idx    <- sapply(combo_info, `[[`, "has_lc")
  splat_idx <- sapply(combo_info, `[[`, "has_splat")
  metricsFiles_lc    <- metricsFiles[lc_idx]
  metricsFiles_splat <- metricsFiles[splat_idx]
  lcenterfiles <- length(metricsFiles_lc) > 0
  splatfiles   <- length(metricsFiles_splat) > 0
  eitherfiles  <- lcenterfiles | splatfiles
  
  outDir <- file.path(park_report_dir, paste0(order, "_", season, "_", year))
  dir.create(outDir, recursive = TRUE, showWarnings = FALSE)
  
  ## -- Analysis period (days) for Listening Center / SPLAT ------------
  ## Extracted directly from each site's own metrics file header (see
  ## extract_days_count() above). Different sites can legitimately have
  ## different numbers of analysis days (e.g. a logger that started/
  ## stopped listening slightly later than others) - collapsed here into
  ## a single number if every site agrees, or a "min-max" range
  ## otherwise, then written out as a small CSV. Step4 reads this file
  ## (aggregating further across every season/year folder currently in
  ## its report scope) to build the Methods section narrative text.
  lc_days <- if (lcenterfiles) {
    vapply(metricsFiles_lc, extract_days_count, integer(1),
           label = "Listening Center Detailed Event Audibility (%)", season = season)
  } else integer(0)
  lc_days <- lc_days[!is.na(lc_days)]
  
  splat_days <- if (splatfiles) {
    vapply(metricsFiles_splat, extract_days_count, integer(1),
           label = "SPLAT Detailed Average Event Counts", season = season)
  } else integer(0)
  splat_days <- splat_days[!is.na(splat_days)]
  
  format_days_range <- function(x) {
    if (length(x) == 0) return(NA_character_)
    rng <- range(x)
    if (rng[1] == rng[2]) as.character(rng[1]) else paste0(rng[1], "-", rng[2])
  }
  
  days_summary_df <- data.frame(
    Type = c("ListeningCenter", "SPLAT"),
    DaysText = c(
      ifelse(is.na(format_days_range(lc_days)), "", format_days_range(lc_days)),
      ifelse(is.na(format_days_range(splat_days)), "", format_days_range(splat_days))
    ),
    stringsAsFactors = FALSE
  )
  safe_write_csv(days_summary_df, file.path(outDir, paste0("analysisdays_", season, ".csv")), row.names = FALSE)
  
  ## -- Ambient full frequency ---------------------------------------
  amb_list <- list()
  for (i in seq_along(names_)) {
    res <- readMetrics(metricsFiles[i], "ambFull", season)
    if (is.null(res)) next
    amb_list[[names_[i]]] <- data.frame(res)  # keep whole list (incl. $n) - column
    # indices below are written against this
  }
  
  amb_full_rows <- list()
  amb_full_all_rows <- list()
  for (nm in names(amb_list)) {
    d <- amb_list[[nm]]
    ambday   <- d[1, c(6, 5)]; colnames(ambday)   <- c("LA50_Day", "LAnat_Day")
    ambnight <- d[2, c(6, 5)]; colnames(ambnight) <- c("LA50_Night", "LAnat_Night")
    amb_full_rows[[nm]] <- cbind(SiteID = nm, ambday, ambnight)
    
    dayall   <- d[1, c(7, 6, 5, 4)]; colnames(dayall)   <- c("LA10","LA50","LAnat","LA90")
    dayall$Time <- "Day"; dayall$SiteID <- nm
    nightall <- d[2, c(7, 6, 5, 4)]; colnames(nightall) <- c("LA10","LA50","LAnat","LA90")
    nightall$Time <- "Night"; nightall$SiteID <- nm
    amb_full_all_rows[[nm]] <- rbind(dayall, nightall)
  }
  amb_full <- rbindlist(amb_full_rows)
  amb_full$SiteID <- as.factor(amb_full$SiteID)
  amb_full <- amb_full[, c("SiteID","LA50_Day","LAnat_Day","LA50_Night","LAnat_Night")]
  
  amb_full_all <- rbindlist(amb_full_all_rows)
  amb_full_all$SiteID <- as.factor(amb_full_all$SiteID)
  amb_full_all <- amb_full_all[, c("Time","SiteID","LA10","LA50","LAnat","LA90")]
  
  safe_write_csv(amb_full_all, file.path(outDir, paste0("ambfullsum_", season, ".csv")), row.names = FALSE)
  
  ## -- Impact / Listening Area Reduction ----------------------------
  impact_la <- NULL
  if (eitherfiles) {
    impact_la <- amb_full[, c("SiteID","LA50_Day","LAnat_Day","LA50_Night","LAnat_Night")]
    impact_la$DayImpact   <- impact_la$LA50_Day - impact_la$LAnat_Day
    impact_la$DayLAR      <- (1 - 10^(-impact_la$DayImpact/10)) * 100
    impact_la$NightImpact <- impact_la$LA50_Night - impact_la$LAnat_Night
    impact_la$NightLAR    <- (1 - 10^(-impact_la$NightImpact/10)) * 100
    impact_la$AllImpact   <- (impact_la$DayImpact + impact_la$NightImpact) / 2
    impact_la$AllLAR      <- (impact_la$DayLAR + impact_la$NightLAR) / 2
    impact_la <- impact_la[, c("SiteID","DayImpact","DayLAR","NightImpact","NightLAR","AllImpact","AllLAR")]
    safe_write_csv(impact_la, file.path(outDir, paste0("impactlisteningarea_", season, ".csv")), row.names = FALSE)
  }
  
  ## -- Time Above ----------------------------------------------------
  ta_full_rows <- list(); ta_ans_rows <- list()
  for (i in seq_along(names_)) {
    r1 <- readMetrics(metricsFiles[i], "timeAbove", season)
    if (!is.null(r1)) {
      d <- data.frame(r1)  # whole list -> col1 = n, col2:5 = the four dB values
      full_day   <- d[1, 2:5]; colnames(full_day)   <- c("35dB Day","45dB Day","52dB Day","60dB Day")
      full_night <- d[2, 2:5]; colnames(full_night) <- c("35dB Night","45dB Night","52dB Night","60dB Night")
      ta_full_rows[[names_[i]]] <- cbind("Site ID" = names_[i],
                                         "Frequency (Hz)" = "Full (12.5-20,000)",
                                         full_day, full_night)
    }
    r2 <- readMetrics(metricsFiles[i], "timeAboveT", season)
    if (!is.null(r2)) {
      d <- data.frame(r2)
      ans_day   <- d[1, 2:5]; colnames(ans_day)   <- c("35dB Day","45dB Day","52dB Day","60dB Day")
      ans_night <- d[2, 2:5]; colnames(ans_night) <- c("35dB Night","45dB Night","52dB Night","60dB Night")
      ta_ans_rows[[names_[i]]] <- cbind("Site ID" = names_[i],
                                        "Frequency (Hz)" = "ANS (20-1,250)",
                                        ans_day, ans_night)
    }
  }
  timeAbove <- rbind(rbindlist(ta_full_rows), rbindlist(ta_ans_rows))
  if (nrow(timeAbove) > 0) {
    timeAbove <- timeAbove[order(timeAbove$`Site ID`), ]
    colnames(timeAbove) <- c("Site ID","Frequency (Hz)","35 dB Day","45 dB Day","52 dB Day","60 dB Day",
                             "35 dB Night","45 dB Night","52 dB Night","60 dB Night")
    safe_write_csv(timeAbove, file.path(outDir, paste0("timeabove_", season, ".csv")), row.names = FALSE)
  }
  
  ## -- Listening Center detail / categorical --------------------------
  detailfinal <- NULL
  catfinal <- NULL
  if (lcenterfiles) {
    newnames <- unique(str_extract(basename(metricsFiles_lc), "(?<=_)[^_]+(?=\\.txt$)"))
    
    lld_rows <- list()
    for (i in seq_along(newnames)) {
      idx <- which(names_ == newnames[i])[1]
      if (is.na(idx)) next
      res <- readMetrics(metricsFiles[idx], "LLDetail", season)
      if (is.null(res)) next
      lld_rows[[newnames[i]]] <- cbind(data.frame(res), SiteID = newnames[i])
    }
    if (length(lld_rows) > 0) {
      lldetail <- ldply(lld_rows, data.frame)
      colnames(lldetail) <- c("df","junk","SrcID","00h","01h","02h","03h","04h","05h","06hr","07hr",
                              "08h","09h","10h","11h","12h","13h","14h","15h","16h","17h","18h","19h",
                              "20h","21h","22h","23h","SiteID")
      lldetail$SrcID <- as.numeric(lldetail$SrcID)
      combineddata <- left_join(lldetail, sourceid, by = "SrcID")
      detailfinal <- combineddata[, c(28, 31, 4:27)]
      for (nm in newnames) {
        safe_write_csv(subset(detailfinal, SiteID == nm),
                       file.path(outDir, paste0("ListeningCenter_", season, "_DetailedResults_", nm, ".csv")),
                       row.names = FALSE)
      }
    }
    
    llc_rows <- list()
    for (i in seq_along(newnames)) {
      idx <- which(basename(metricsFiles_lc) %like% newnames[i])[1]
      if (is.na(idx)) next
      res <- readMetrics(metricsFiles_lc[idx], "LLCat", season)
      if (is.null(res)) next
      llc_rows[[newnames[i]]] <- cbind(data.frame(res), SiteID = newnames[i])
    }
    if (length(llc_rows) > 0) {
      llcat <- ldply(llc_rows, data.frame)
      colnames(llcat) <- c("df","junk","SrcID","00h","01h","02h","03h","04h","05h","06hr","07hr",
                           "08h","09h","10h","11h","12h","13h","14h","15h","16h","17h","18h","19h",
                           "20h","21h","22h","23h","SiteID")
      llcat$SrcID <- as.numeric(llcat$SrcID)
      combineddatacat <- left_join(llcat, sourceid, by = "SrcID")
      catfinal <- combineddatacat[, c(3, 28, 30, 4:27)]
    }
  }
  
  ## -- SPLAT detail / categorical --------------------------------------
  splatdetailfinal <- NULL
  splatcatfinal <- NULL
  newnames2 <- character(0)
  if (splatfiles) {
    newnames2 <- unique(str_extract(basename(metricsFiles_splat), "(?<=_)[^_]+(?=\\.txt$)"))
    
    spd_rows <- list()
    for (i in seq_along(newnames2)) {
      res <- readMetrics(metricsFiles_splat[i], "SPLATDet", season)
      if (is.null(res)) next
      spd_rows[[newnames2[i]]] <- cbind(data.frame(res), SiteID = newnames2[i])
    }
    if (length(spd_rows) > 0) {
      splatdetail <- ldply(spd_rows, data.frame)
      colnames(splatdetail) <- c("df","junk","SrcID","00h","01h","02h","03h","04h","05h","06hr","07hr",
                                 "08h","09h","10h","11h","12h","13h","14h","15h","16h","17h","18h","19h",
                                 "20h","21h","22h","23h","SiteID")
      splatdetail$SrcID <- as.numeric(splatdetail$SrcID)
      combineddata2 <- left_join(splatdetail, sourceid, by = "SrcID")
      splatdetailfinal <- combineddata2[, c(28, 31, 4:27)]
      
      splatcatfinal <- combineddata2[, c(29, 28, 30, 4:27)]
      splatcatfinal <- splatcatfinal %>%
        rename("SrcID" = "Type") %>%
        group_by(SrcID, SiteID, `Source Type`) %>%
        summarise(across(c(1:24), sum), .groups = "drop")
      
      for (nm in newnames2) {
        safe_write_csv(subset(splatdetailfinal, SiteID == nm),
                       file.path(outDir, paste0("SPLAT_", season, "DetailedResults_", nm, ".csv")),
                       row.names = FALSE)
      }
    }
  }
  
  ## -- SPLAT Event Counts, Event Lengths & Noise Free Interval ---------------
  ## Only present when a SPLAT section exists in the file. Written one CSV
  ## per site, since the number of Source ID columns in "Event Counts"/
  ## "Event Lengths" can vary from site to site (unlike the fixed 24-hour
  ## columns elsewhere).
  if (splatfiles) {
    for (i in seq_along(newnames2)) {
      
      ## Average event count & length per source, rows = Day/Night/24hr, cols = Source ID.
      ## Each is transposed so Source ID becomes a row, the two are merged
      ## together on SrcID, then joined against sourceid to attach Source
      ## Description (same lookup used above).
      res_ecs <- readMetrics(metricsFiles_splat[i], "SPLATecs", season)
      res_els <- readMetrics(metricsFiles_splat[i], "SPLATels", season)
      
      if (!is.null(res_ecs) || !is.null(res_els)) {
        
        prep_wide <- function(res, suffix) {
          d <- as.data.frame(t(res$data), check.names = FALSE)  # check.names=FALSE keeps "24hr" intact
          d$SrcID <- as.numeric(sub("^X", "", rownames(d)))     # undo R's auto "X" prefix on the Source IDs
          rownames(d) <- NULL
          names(d)[names(d) != "SrcID"] <- paste0(names(d)[names(d) != "SrcID"], suffix)
          d
        }
        
        d_ecs <- if (!is.null(res_ecs)) prep_wide(res_ecs, "_Count") else NULL
        d_els <- if (!is.null(res_els)) prep_wide(res_els, "_Length") else NULL
        
        d <- if (!is.null(d_ecs) && !is.null(d_els)) {
          full_join(d_ecs, d_els, by = "SrcID")
        } else if (!is.null(d_ecs)) d_ecs else d_els
        
        d <- left_join(d, sourceid, by = "SrcID")
        d$SiteID <- newnames2[i]
        
        lookup_cols <- intersect(names(sourceid), names(d))
        period_cols <- setdiff(names(d), c("SrcID", "SiteID", lookup_cols))
        d <- d[, c("SiteID", "SrcID", lookup_cols, period_cols)]
        
        safe_write_csv(d, file.path(outDir, paste0("SPLAT_", season, "_EventCountsLengths_", newnames2[i], ".csv")),
                       row.names = FALSE)
      }
      
      ## Noise-free interval duration (sec) at 90/50/10th percentile + mean, by hour
      res_nfi <- readMetrics(metricsFiles_splat[i], "SPLATnfi", season)
      if (!is.null(res_nfi)) {
        d <- res_nfi$data
        names(d) <- sub("^X", "", names(d))  # undo R's auto "X" prefix on hour columns (X00h -> 00h)
        d <- data.frame(Percentile = rownames(d), d, row.names = NULL, check.names = FALSE)
        d$SiteID <- newnames2[i]
        safe_write_csv(d, file.path(outDir, paste0("SPLAT_", season, "_NoiseFreeInterval_", newnames2[i], ".csv")),
                       row.names = FALSE)
        
        ## -- NFI time series plot: hour of day vs. noise-free interval
        ##    duration, shown as median (50%) and mean only (previously
        ##    also plotted the 90th/10th percentile lines). Y-axis shows
        ##    mm:ss instead of raw seconds - sec_to_mmss() (defined
        ##    earlier for the SPLAT event-length table) is reused here as
        ##    the axis label formatter.
        nfi_long <- d %>%
          select(-SiteID) %>%
          pivot_longer(cols = -Percentile, names_to = "hour", values_to = "seconds") %>%
          mutate(hr = as.numeric(sub("h$", "", hour))) %>%
          filter(Percentile %in% c("50%", "Mean"))
        nfi_long$Percentile <- factor(nfi_long$Percentile, levels = c("50%", "Mean"))
        
        p_nfi <- ggplot(nfi_long, aes(x = hr, y = seconds, color = Percentile, linetype = Percentile)) +
          geom_line(linewidth = 1) +
          geom_point(size = 1.5) +
          scale_x_continuous("Hour", breaks = 0:23) +
          scale_y_continuous("Noise-Free Interval (mm:ss)", labels = sec_to_mmss) +
          scale_color_manual(values = c("50%" = "#55A868", "Mean" = "black")) +
          scale_linetype_manual(values = c("50%" = "solid", "Mean" = "dashed")) +
          ggtitle(if (plottitle) paste0("Noise-Free Interval by Hour at: ", newnames2[i]) else "") +
          theme_classic(base_size = 11) +
          theme(legend.title = element_blank(), legend.position = "top")
        
        safe_ggsave(file.path(outDir, paste0(newnames2[i], "_", season, "_NFI_timeseries.png")),
                    plot = p_nfi, height = 5, width = 8)
      }
    }
  }
  
  ## -- pAud ------------------------------------------------------------
  pAud <- NULL; pAudtranspose <- NULL
  if (eitherfiles) {
    pAud_rows <- list()
    for (i in seq_along(names_)) {
      res <- readMetrics(metricsFiles[i], "pAud", season)
      if (is.null(res)) next
      pAud_rows[[names_[i]]] <- cbind(data.frame(res), "Site ID" = names_[i])
    }
    if (length(pAud_rows) > 0) {
      pAuddetail <- ldply(pAud_rows, data.frame)
      pAud <- pAuddetail %>%
        dplyr::group_by(Site.ID) %>%
        dplyr::summarize(mean = mean(as.numeric(data.Total), na.rm = TRUE), .groups = "drop") %>%
        dplyr::rename(SiteID = Site.ID, Noise = mean)
      
      pAudtranspose <- pAuddetail %>%
        rename(SiteID = Site.ID, hr = data.V1, totalnoise = data.Total) %>%
        select(SiteID, hr, totalnoise) %>%
        pivot_wider(names_from = hr, values_from = totalnoise) %>%
        mutate(`Source Type` = "Total Noise") %>%
        relocate(`Source Type`, .after = SiteID) %>%
        mutate(across(3:26, as.numeric))
    }
  }
  
  ## -- Combine categorical data + top sources --------------------------
  catcombined <- NULL; data_pa_all <- NULL
  firstnoise <- NULL; secondnoise <- NULL; sourcetype2 <- NULL
  if (eitherfiles && (!is.null(catfinal) || !is.null(splatcatfinal))) {
    catcombined <- rbind(if (!is.null(catfinal)) catfinal, if (!is.null(splatcatfinal)) splatcatfinal)
    catcombined$dailyave <- rowMeans(catcombined[, 4:27], na.rm = TRUE)
    catcombined$SiteID <- as.factor(catcombined$SiteID)
    catcombined$SourceCategory <- ifelse(catcombined$SrcID > 0 & catcombined$SrcID <= 20, "Noise",
                                         ifelse(catcombined$SrcID > 20 & catcombined$SrcID <= 40, "Natural", "Other"))
    
    data_pa_all <- catcombined %>%
      group_by(SiteID, SourceCategory, `Source Type`) %>%
      summarize(mean = mean(dailyave, na.rm = TRUE), .groups = "drop")
    
    sourcetype1 <- data_pa_all %>%
      filter(SourceCategory == "Noise") %>%
      group_by(`Source Type`) %>%
      summarize(sum = sum(mean), .groups = "drop") %>%
      top_n(3, sum) %>%
      arrange(desc(sum))
    nlist <- as.list(sourcetype1$`Source Type`)
    
    sourcetype2 <- data_pa_all %>%
      filter(SourceCategory == "Noise", `Source Type` %in% nlist) %>%
      pivot_wider(names_from = `Source Type`, values_from = mean)
    sourcetype2 <- sourcetype2[, -2, drop = FALSE]
    num_columns <- ncol(sourcetype2)
    if (num_columns < 4) {
      for (i in (num_columns + 1):4) sourcetype2[[paste0("NA_", i)]] <- NA
    }
    
    catfinal1 <- catcombined[, c(1:3, 28)]
    colnames(catfinal1) <- c("SrcID","SiteID","SourceType","Percent")
    firstnoise <- catfinal1 %>%
      filter(SrcID <= 20) %>% group_by(SiteID) %>% top_n(1, Percent) %>% mutate(rank = 1)
    secondnoise <- catfinal1 %>%
      filter(SrcID <= 20) %>% group_by(SiteID) %>% top_n(2, Percent) %>% top_n(-1, Percent) %>% mutate(rank = 2)
  }
  
  ## -- Executive summary table -------------------------------------------
  if (eitherfiles && !is.null(pAud) && !is.null(sourcetype2)) {
    natpercent2 <- merge(pAud, sourcetype2, by = "SiteID", all = TRUE)
    exectab <- merge(natpercent2, amb_full, by = "SiteID", all = TRUE)
    safe_write_csv(exectab, file.path(outDir, paste0("executivesumtab_", season, ".csv")), row.names = FALSE)
  }
  
  ## -- Noise source bar plots (top1 / top2) -------------------------------
  if (eitherfiles && !is.null(catcombined) && !is.null(pAudtranspose)) {
    srctypefinalplot <- catcombined[, c(2:27)]
    names(pAudtranspose) <- names(srctypefinalplot)
    toptwosource <- rbind(pAudtranspose, srctypefinalplot)
    toptwosource1 <- toptwosource %>%
      pivot_longer(cols = c(3:26), names_to = "hour", values_to = "paud")
    toptwosource1$hr <- substr(toptwosource1$hour, 1, 2)
    
    mansrc1list <- as.list(firstnoise$SourceType)
    mansrc2list <- as.list(secondnoise$SourceType)
    
    # FIXED: mansrc1list/mansrc2list (above) only have ONE ROW PER SITE
    # THAT ACTUALLY HAS a noise-category (SrcID <= 20) source at all -
    # a site with NO detected noise sources is simply absent from
    # firstnoise/secondnoise entirely, not present with an NA value.
    # The plotting loop below previously indexed these by POSITION
    # (mansrc1list[i] assumed to correspond to names_[i]), which meant
    # a single no-noise site silently shifted every subsequent site's
    # noise-source lookup out of alignment - not just skipping a plot
    # for the no-noise site, but potentially mislabeling every plot
    # after it in the loop. Building explicit SiteID-keyed lookups here
    # (with NA for any site absent from firstnoise/secondnoise) fixes
    # the alignment regardless of which sites are missing, and lets the
    # loop check "does this site actually have a noise source" directly
    # instead of relying on position.
    mansrc1_by_site <- setNames(as.character(firstnoise$SourceType), firstnoise$SiteID)
    mansrc2_by_site <- setNames(as.character(secondnoise$SourceType), secondnoise$SiteID)
    mansrc1_lookup <- mansrc1_by_site[names_]
    mansrc2_lookup <- mansrc2_by_site[names_]
    
    for (i in seq_along(names_)) {
      # FIXED: skip plot generation entirely for a site with no detected
      # noise source (mansrc1_lookup[i] is NA - see note above where
      # mansrc1_by_site/mansrc1_lookup are built) rather than generating
      # a top1/top2 plot - and a filename literally containing "NA" -
      # for a site that has nothing to show here.
      if (is.na(mansrc1_lookup[i])) {
        message("  No noise source detected for site ", names_[i], " - skipping top1/top2 noise source plots for this site.")
        next
      }
      
      df1 <- toptwosource1 %>% filter(SiteID %in% names_[i], `Source Type` %in% "Total Noise")
      df2 <- toptwosource1 %>% filter(SiteID %in% names_[i], `Source Type` %in% mansrc1_lookup[i])
      p <- ggplot() +
        geom_col(data = df1, aes(x = hr, y = paud, fill = `Source Type`, color = "Total human audibility"),
                 fill = "grey55", width = .9, size = 0) +
        geom_col(data = df2, aes(x = hr, y = paud, fill = `Source Type`), width = .85, alpha = .75, size = 0) +
        ggtitle(if (plottitle) paste0("Top Noise Source at: ", names_[i]) else "") +
        scale_fill_manual(values = c("slateblue")) +
        scale_x_discrete("Hour") +
        scale_y_continuous("Time Audible (%)", expand = c(0,0), limits = c(0,110), breaks = seq(0,100,10)) +
        scale_color_manual(values = c("lightgrey","slateblue")) +
        theme(legend.position = "top", legend.title = element_blank(),
              panel.background = element_rect(fill = "grey80", colour = "grey80", linewidth = 0.5),
              panel.grid.minor = element_blank())
      safe_ggsave(file.path(outDir, paste0(names_[i], "_", season, "_", mansrc1_lookup[i], "_",
                                           mansrc2_lookup[i], "PercentAud_top1.png")),
                  plot = p, height = 5, width = 8)
      
      df2b <- toptwosource1 %>% filter(SiteID %in% names_[i], `Source Type` %in% c(mansrc1_lookup[i], mansrc2_lookup[i]))
      p2 <- ggplot() +
        geom_col(data = df1, aes(x = hr, y = paud, fill = `Source Type`, color = "Total human audibility"),
                 fill = "grey55", width = .9, size = 0) +
        geom_col(data = df2b, aes(x = hr, y = paud, fill = `Source Type`), position = "dodge2",
                 width = .85, alpha = .80, size = 0) +
        scale_fill_manual(values = c("slateblue","lightcoral")) +
        scale_x_discrete("Hour") +
        scale_y_continuous("Time Audible (%)", expand = c(0,0), limits = c(0,110), breaks = seq(0,100,10)) +
        scale_color_manual(values = c("lightgrey","slateblue","lightcoral")) +
        ggtitle(if (plottitle) paste0("Top Two Noise Sources at: ", names_[i]) else "") +
        theme(legend.position = "top", legend.title = element_blank(),
              panel.background = element_rect(fill = "grey80", colour = "grey80", linewidth = 0.5),
              panel.grid.minor = element_blank())
      safe_ggsave(file.path(outDir, paste0(names_[i], "_", season, "_", mansrc1_lookup[i], "_",
                                           mansrc2_lookup[i], "PercentAud_top2.png")),
                  plot = p2, height = 5, width = 8)
    }
  }
  
  ## -- All-source detail & category plots ---------------------------------
  if (eitherfiles && (!is.null(detailfinal) || !is.null(splatdetailfinal))) {
    detcombined <- rbind(if (!is.null(detailfinal)) detailfinal, if (!is.null(splatdetailfinal)) splatdetailfinal)
    detcombined <- merge(detcombined, sourceid, by = "Source Description")
    detcombined$dailyave <- rowMeans(detcombined[, 3:26], na.rm = TRUE)
    detcombined$SiteID <- as.factor(detcombined$SiteID)
    detcombined$SourceCategory <- ifelse(detcombined$SrcID > 0 & detcombined$SrcID <= 20, "Noise",
                                         ifelse(detcombined$SrcID > 20 & detcombined$SrcID <= 40, "Natural", "Other"))
    data_detail_all <- detcombined %>%
      group_by(SiteID, SourceCategory, `Source Description`) %>%
      summarize(mean = mean(dailyave, na.rm = TRUE), .groups = "drop")
    
    cols <- RColorBrewer::brewer.pal(n = 2, name = "Set2")
    
    for (i in seq_along(names_)) {
      df1 <- data_detail_all %>% filter(SiteID == names_[i], SourceCategory != "Other")
      if (nrow(df1) == 0) next
      num_categories <- length(unique(df1$SourceCategory))
      df1_means <- df1 %>% group_by(`Source Description`) %>%
        summarise(mean_value = mean(mean, na.rm = TRUE)) %>% arrange(mean_value)
      df1$`Source Description` <- factor(df1$`Source Description`, levels = df1_means$`Source Description`)
      df1$SourceCategory <- factor(df1$SourceCategory, levels = rev(unique(df1$SourceCategory)))
      
      p <- ggplot(df1, aes(x = mean, y = `Source Description`, fill = SourceCategory)) +
        geom_col(width = 0.9) +
        scale_x_continuous(name = "Time Audible (%)") +
        scale_y_discrete(name = "Sound Source Description") +
        facet_wrap(~ SourceCategory, scales = "free") +
        theme_classic(base_size = 10) +
        scale_fill_manual(values = cols[1:num_categories]) +
        guides(fill = guide_legend(title = "Source Type")) +
        ggtitle(if (plottitle) paste0("All Sound Sources at: ", names_[i]) else "") +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
              legend.key.size = unit(0.5, "cm"), legend.position = "bottom")
      safe_ggsave(file.path(outDir, paste0(names_[i], "_", season, "_PercentAud_description_all.png")),
                  plot = p, height = 5, width = 8)
    }
  }
  
  if (eitherfiles && !is.null(data_pa_all)) {
    cols <- RColorBrewer::brewer.pal(n = 2, name = "Set2")
    for (i in seq_along(names_)) {
      df1 <- data_pa_all %>% filter(SiteID == names_[i], SourceCategory != "Other")
      if (nrow(df1) == 0) next
      num_categories <- length(unique(df1$SourceCategory))
      df1_means <- df1 %>% group_by(`Source Type`) %>%
        summarise(mean_value = mean(mean, na.rm = TRUE)) %>% arrange(mean_value)
      df1$`Source Type` <- factor(df1$`Source Type`, levels = df1_means$`Source Type`)
      df1$SourceCategory <- factor(df1$SourceCategory, levels = rev(unique(df1$SourceCategory)))
      
      p <- ggplot(df1, aes(x = mean, y = `Source Type`, fill = SourceCategory)) +
        geom_col(width = 0.9) +
        scale_x_continuous(name = "Time Audible (%)") +
        scale_y_discrete(name = "Sound Source Type") +
        facet_wrap(~ SourceCategory, scales = "free") +
        theme_classic(base_size = 10) +
        scale_fill_manual(values = cols[1:num_categories]) +
        guides(fill = guide_legend(title = "Source Type")) +
        ggtitle(if (plottitle) paste0("All Sound Sources at: ", names_[i]) else "") +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
              legend.key.size = unit(0.5, "cm"), legend.position = "bottom")
      safe_ggsave(file.path(outDir, paste0(names_[i], "_", season, "_PercentAud_category_all.png")),
                  plot = p, height = 5, width = 8)
    }
  }
  
  ## -- Base-graphics: Hourly / Frequency / Contour plots ------------------
  {
    titlesOnPlots <- as.numeric(plottitle)
    plotHRDBACOMB <- c(plotHRDBA, plotTRUNCDBA)
    filesToPlot <- metricsFiles
    
    pngWidth <- 1920 * 2; pngHeight <- 1080 * 2
    fTitle <- 7; fAxis <- 5; fLab <- 7; myLWD <- 6
    
    for (i in seq_along(filesToPlot)) {
      fileData <- scan(filesToPlot[i], what = "character", sep = "\n", blank.lines.skip = FALSE, quiet = TRUE)
      mVersion <- as.numeric(strsplit(fileData[grep("###", fileData)], "V")[[1]][2])
      siteID <- names_[i]
      
      hrdbaTitle <- NULL; hrdbaTruncTitle <- NULL; hzdbTitle <- NULL; hzhrTitle <- NULL
      
      dayTime   <- as.numeric(gsub(".*:\\s(\\d{2}).*", "\\1", fileData[grep("Day:", fileData)]))
      nightTime <- as.numeric(gsub(".*:\\s(\\d{2}).*", "\\1", fileData[grep("Night:", fileData)]))
      
      if (titlesOnPlots) {
        hrdbaTitle      <- paste0(siteID, ": Hour v. Sound Pressure Level")
        hrdbaTruncTitle <- paste0(siteID, ": Hour v. Sound Pressure Level (20Hz - 1250Hz)")
        hzdbTitle       <- paste0(siteID, ": Frequency v. Sound Pressure Level")
        hzhrTitle       <- paste0(siteID, ": Contour Plot for ")
      }
      
      ## Hour v. dBA / dBT
      for (pType in 1:2) {
        if (plotHRDBACOMB[pType]) {
          if (mVersion > 1.2) {
            dataPos <- if (pType == 1) grep("Median Hourly Metrics \\(dBA\\)", fileData) else
              grep("Median Hourly Metrics \\(dBT\\)", fileData)
          } else {
            dataPos <- if (pType == 1) grep("Median dBA values by Hour", fileData) else
              grep("Median Truncated dBA values by Hour", fileData)
          }
          if (length(dataPos) != 0) {
            for (sIdx in seq_along(dataPos)) {
              gInfo <- scan(filesToPlot[i], skip = dataPos[sIdx] - 1, sep = "!", n = 1, what = "character")
              seasonHere <- gsub(".*,\\s(\\w+)\\s.*", "\\1", gInfo)
              nSamples   <- gsub(".*=\\s(\\d+)hr.*", "\\1", gInfo)
              if (seasonHere != season) next   # only plot the season we're processing
              
              pngFile <- file.path(outDir, paste0(siteID, "_", seasonHere,
                                                  if (pType == 1) "_DBAvHR.png" else "_DBTvHR.png"))
              thisTitle <- if (pType == 1) hrdbaTitle else hrdbaTruncTitle
              if (titlesOnPlots) thisTitle <- paste0(thisTitle, " (", seasonHere, ")")
              
              data <- if (mVersion > 1.2) {
                t(read.table(filesToPlot[i], skip = dataPos[sIdx], nrows = 9, header = TRUE, row.names = 1,
                             sep = "\t", na.strings = c("--.-","-888.0")))
              } else {
                read.table(filesToPlot[i], skip = dataPos[sIdx], nrows = 24, header = TRUE,
                           sep = "\t", na.strings = c("--.-","-888.0"))
              }
              
              hasLNAT <- sum(!is.na(data[, "Lnat"])) > 0
              dataYmin <- min(data[, "L090"], na.rm = TRUE)
              if (hasLNAT) dataYmin <- min(dataYmin, min(data[, "Lnat"], na.rm = TRUE))
              dataYmax <- max(data[, "L010"], na.rm = TRUE)
              
              tempAxis <- if (ceiling(dataYmin/3)*3 < floor(dataYmax/3)*3) {
                ta <- seq(ceiling(dataYmin/3)*3, floor(dataYmax/3)*3, by = 3)
                if ((ta[1]-dataYmin) < 2) ta <- ta[-1]
                if (length(ta) != 0) {
                  if ((dataYmax - ta[length(ta)]) < 2) ta <- ta[-length(ta)]
                  c(dataYmin, ta, dataYmax)
                } else c(dataYmin, dataYmax)
              } else c(dataYmin, dataYmax)
              
              x <- 0:23
              png(filename = pngFile, width = pngWidth, height = pngHeight)
              par(mar = c(fTitle*2, fTitle*2+5, fAxis*2, fAxis)+0.1, mgp = c(fTitle,1,0), ljoin = 1, lend = 2)
              plot(1,1,type="n",main=thisTitle,bty="l",xaxt="n",yaxt="n",xlab="",ylab="",
                   yaxs="i", xlim=c(0,23), ylim=c(yMinHr,yMaxHr), cex.main=fTitle)
              axis(1, at=0:23, labels=x, cex.axis=fAxis, line=2, fg="white")
              axis(2, at=c(tempAxis[1], tempAxis[length(tempAxis)]), labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis)
              axis(2, at=tempAxis[c(-1,-length(tempAxis))], labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis*0.75, col.axis="grey50")
              axis(2, at=c(yMaxHr,yMinHr), labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis*0.75, col.axis="grey50")
              mtext("Hour", side=1, line=fTitle+1, cex=fLab)
              if (pType==1) mtext(expression(plain("Percentile Sound Level (L"[plain("A eq,1s")]*")")), side=2, line=fTitle+4, cex=fLab)
              if (pType==2) mtext(expression(plain("Percentile Sound Level (L"[plain("A eq,1s,NS")]*")")), side=2, line=fTitle+4, cex=fLab)
              mtext(paste0("n = ", nSamples), side=1, line=fTitle*2-1, cex=fAxis)
              
              segments(x, data[,"L010"], x, data[,"L090"], col="grey75", lwd=myLWD)
              segments(x-0.125, data[,"L090"], x+0.125, data[,"L090"], col="grey75", lwd=myLWD)
              segments(x-0.125, data[,"L010"], x+0.125, data[,"L010"], col="grey75", lwd=myLWD)
              if (hasLNAT) {
                rect(x-0.25, data[,"L050"], x+0.25, data[,"Lnat"], col="black", lwd=myLWD)
              } else {
                segments(x-0.25, data[,"L050"], x+0.25, data[,"L050"], lwd=myLWD)
              }
              
              xLegHr <- 0; yLegHr <- yMaxHr
              if (all(data[1:4,"L010"] < yMaxHr-10, na.rm=TRUE)) { xLegHr<-0; yLegHr<-yMaxHr }
              else if (all(data[1:4,"L090"] > yMinHr+10, na.rm=TRUE)) { xLegHr<-0; yLegHr<-yMinHr+10 }
              
              segments(xLegHr+0.625, yLegHr-1, xLegHr+0.625, yLegHr-9, col="grey75", lwd=myLWD)
              segments(xLegHr+0.5, yLegHr-1, xLegHr+0.75, yLegHr-1, col="grey75", lwd=myLWD)
              segments(xLegHr+0.5, yLegHr-9, xLegHr+0.75, yLegHr-9, col="grey75", lwd=myLWD)
              if (hasLNAT) {
                rect(xLegHr+0.375, yLegHr-6.5, xLegHr+0.875, yLegHr-3.5, col="black", border="black")
                text(xLegHr+0.75, yLegHr-3.5, expression(phantom(0)%<-%"L"[A50]), adj=c(0,0.5), cex=fAxis)
                text(xLegHr+0.75, yLegHr-6.5, expression(phantom(0)%<-%"L"[ANAT]), adj=c(0,0.5), cex=fAxis)
              } else {
                segments(xLegHr+0.375, yLegHr-5, xLegHr+0.875, yLegHr-5, col="black", lwd=myLWD)
                text(xLegHr+0.75, yLegHr-5, expression(phantom(0)%<-%"L"[A50]), adj=c(0,0.5), cex=fAxis)
              }
              text(xLegHr+0.75, yLegHr-1, expression(phantom(0)%<-%"L"[A10]), adj=c(0,0.5), cex=fAxis)
              text(xLegHr+0.75, yLegHr-8.9, expression(phantom(0)%<-%"L"[A90]), adj=c(0,0.5), cex=fAxis)
              graphics.off()
            }
          }
        }
      }
      
      ## Frequency v. dB
      if (plotFREQDBA) {
        dataDayPosAll <- grep("Median Daytime Frequency Metrics \\(dB\\), ", fileData)
        dataNightPosAll <- grep("Median Nighttime Frequency Metrics \\(dB\\), ", fileData)
        
        dayString_pos <- dataDayPosAll[grepl(season, fileData[dataDayPosAll])]
        nightString_pos <- dataNightPosAll[grepl(season, fileData[dataNightPosAll])]
        
        hasDay <- length(dayString_pos) > 0
        hasNight <- length(nightString_pos) > 0
        
        if (hasDay || hasNight) {
          nSamplesDay <- ""; nSamplesNight <- ""
          if (hasDay) {
            gInfo <- scan(filesToPlot[i], skip = dayString_pos[1]-1, sep="\n", n=1, what="character")
            nSamplesDay <- paste0(gsub(".*=\\s(\\d+)hr.*","\\1",gInfo), " daytime hours")
            dayStringLbl <- paste0("Day (",dayTime,"am-",nightTime%%12,"pm)")
            dataDay <- if (mVersion > 1.2) {
              t(read.table(filesToPlot[i], skip=dayString_pos[1], nrows=4, header=TRUE, row.names=1,
                           sep="\t", na.strings=c("--.-","-888.0")))
            } else read.table(filesToPlot[i], skip=dayString_pos[1], nrows=33, header=TRUE, sep="\t",
                              na.strings=c("--.-","-888.0"))
          }
          if (hasNight) {
            gInfo <- scan(filesToPlot[i], skip = nightString_pos[1]-1, sep="\n", n=1, what="character")
            nSamplesNight <- paste0(gsub(".*=\\s(\\d+)hr.*","\\1",gInfo), " nighttime hours")
            nightStringLbl <- paste0("Night (",nightTime%%12,"pm-",dayTime,"am)")
            dataNight <- if (mVersion > 1.2) {
              t(read.table(filesToPlot[i], skip=nightString_pos[1], nrows=4, header=TRUE, row.names=1,
                           sep="\t", na.strings=c("--.-","-888.0")))
            } else read.table(filesToPlot[i], skip=nightString_pos[1], nrows=33, header=TRUE, sep="\t",
                              na.strings=c("--.-","-888.0"))
          }
          
          pngFile <- file.path(outDir, paste0(siteID, "_", season, "_SPLvFREQ.png"))
          hzdbTitleP <- if (titlesOnPlots) paste0(hzdbTitle, " (", season, ")") else hzdbTitle
          
          xc <- 1:33
          myXLabels <- c("12.5","25","50","100","200","400","800","1.6k","3.15k","6.3k","12.5k")
          myXLabelPos <- seq(1, 33, by = 3)
          tohVals <- c(93.2,86.3,78.5,68.7,59.5,51.1,44,37.5,31.5,26.5,22.1,17.9,14.4,
                       11.4,8.4,5.8,3.8,2.1,1.0,0.8,1.9,0.5,-1.5,-3.1,-4,-3.8,-1.8,2.5,
                       6.8,9.8,14.4,43.7,84.7)
          
          xLabPos <- 1; yLabPos <- yMinHz + 14
          if (hasDay) {
            if (all(dataDay[26:33,"L010"] < (yMaxHz-15), na.rm=TRUE)) { xLabPos<-26; yLabPos<-yMaxHz-2 }
          } else if (hasNight) {
            if (all(dataNight[26:33,"L010"] < (yMaxHz-15), na.rm=TRUE)) { xLabPos<-26; yLabPos<-yMaxHz-2 }
          }
          
          hasLNAT <- if (hasDay) !is.na(dataDay[10,"Lnat"]) else !is.na(dataNight[10,"Lnat"])
          
          if (hasDay && hasNight) {
            dataYmin <- min(min(dataDay[,"L090"],na.rm=TRUE), min(dataNight[,"L090"],na.rm=TRUE))
            dataYmax <- max(max(dataDay[,"L010"],na.rm=TRUE), max(dataNight[,"L010"],na.rm=TRUE))
          } else if (hasDay) {
            dataYmin <- min(dataDay[,"L090"],na.rm=TRUE); dataYmax <- max(dataDay[,"L010"],na.rm=TRUE)
          } else {
            dataYmin <- min(dataNight[,"L090"],na.rm=TRUE); dataYmax <- max(dataNight[,"L010"],na.rm=TRUE)
          }
          
          tempAxis <- if (ceiling(dataYmin/3)*3 < floor(dataYmax/3)*3) {
            ta <- seq(ceiling(dataYmin/3)*3, floor(dataYmax/3)*3, by=3)
            if ((ta[1]-dataYmin) < 2) ta <- ta[-1]
            if (length(ta) != 0) {
              if ((dataYmax-ta[length(ta)]) < 2) ta <- ta[-length(ta)]
              c(dataYmin, ta, dataYmax)
            } else c(dataYmin, dataYmax)
          } else c(dataYmin, dataYmax)
          
          png(pngFile, width = pngWidth, height = pngHeight)
          par(mar=c(fTitle*2, fTitle*2, fAxis*2, fAxis)+0.1, mgp=c(fTitle,1,0), ljoin=1, lend=2)
          plot(1,1,type="n",main=hzdbTitleP,xlab="",ylab="",axes=TRUE,lty=1,bty="l",xaxs="i",yaxs="i",
               xaxt="n",yaxt="n",xlim=c(0,34),ylim=c(yMinHz,yMaxHz), cex.main=fTitle, lwd=myLWD)
          mtext("Frequency (Hz)", side=1, line=fTitle+1, cex=fLab)
          mtext("Sound Pressure Level (dB)", side=2, line=fTitle+2, cex=fLab)
          if (hasDay && hasNight) mtext(paste0("n = ", nSamplesDay, ", ", nSamplesNight), side=1, line=fTitle*2-1, cex=fAxis)
          else mtext(paste("n =", nSamplesDay, nSamplesNight), side=1, line=fTitle*2-1, cex=fAxis)
          
          polygon(c(0,0,xc[2:33],34,34), c(yMinHz,tohVals,100,yMinHz), col=rgb(0.95,0.95,0.95), border=NA)
          axis(1, at=myXLabelPos, labels=myXLabels, tck=-0.0125, las=1, tick=FALSE, cex.axis=fAxis, line=2)
          axis(1, at=c(0.5,xc+0.5), labels=FALSE, tck=0.0125, col="grey50")
          axis(1, at=c(0.5,xc+0.5), labels=FALSE, tck=-0.0125)
          axis(2, at=c(tempAxis[1], tempAxis[length(tempAxis)]), labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis)
          axis(2, at=tempAxis[c(-1,-length(tempAxis))], labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis*0.75, col.axis="grey50")
          axis(2, at=c(yMaxHz,yMinHz), labels=TRUE, las=2, tick=TRUE, cex.axis=fAxis*0.75, col.axis="grey50")
          
          dayColor <- c("palegoldenrod","lightgoldenrod","goldenrod")
          nightColor <- c("plum1","plum3","darkorchid")
          
          if (hasDay) {
            rect(xc, dataDay[,"L010"], xc-0.25, dataDay[,"L090"], lwd=myLWD, border=dayColor[2], col=dayColor[1])
            if (hasLNAT) rect(xc, dataDay[,"Lnat"], xc-0.25, dataDay[,"L050"], col=dayColor[3], border=dayColor[3], lwd=0.5)
            else segments(xc, dataDay[,"L050"], xc-0.25, dataDay[,"L050"], lwd=myLWD, col=dayColor[3])
          }
          if (hasNight) {
            rect(xc, dataNight[,"L010"], xc+0.25, dataNight[,"L090"], lwd=myLWD, border=nightColor[2], col=nightColor[1])
            if (hasLNAT) rect(xc, dataNight[,"Lnat"], xc+0.25, dataNight[,"L050"], col=nightColor[3], border=nightColor[3], lwd=0.5)
            else segments(xc, dataNight[,"L050"], xc+0.25, dataNight[,"L050"], lwd=myLWD, col=nightColor[3])
          }
          
          if (hasLNAT) {
            rect(xc[xLabPos], yLabPos-1, xc[xLabPos]-0.25, yLabPos-11, col="white", border="grey50", lwd=myLWD)
            rect(xc[xLabPos], yLabPos-4, xc[xLabPos]-0.25, yLabPos-8, col="grey50", border="grey50", lwd=0.5)
            text(xc[xLabPos]-0.25, yLabPos-1, expression(phantom(0)*phantom(0)%<-%"L"[10]), adj=c(0,0.5), cex=fAxis)
            text(xc[xLabPos]-0.25, yLabPos-4, expression(phantom(0)*phantom(0)%<-%"L"[50]), adj=c(0,0.5), cex=fAxis)
            text(xc[xLabPos]-0.25, yLabPos-8, expression(phantom(0)*phantom(0)%<-%"L"[NAT]), adj=c(0,0.5), cex=fAxis)
            text(xc[xLabPos]-0.25, yLabPos-10.9, expression(phantom(0)*phantom(0)%<-%"L"[90]), adj=c(0,0.5), cex=fAxis)
          } else {
            rect(xc[xLabPos], yLabPos-1, xc[xLabPos]-0.25, yLabPos-11, border="grey50", lwd=myLWD)
            segments(xc[xLabPos], yLabPos-6, xc[xLabPos]-0.25, yLabPos-6, lwd=myLWD)
            text(xc[xLabPos]-0.25, yLabPos-1, expression(phantom(0)*phantom(0)%<-%"L"[10]), adj=c(0,0.5), cex=fAxis)
            text(xc[xLabPos]-0.25, yLabPos-6, expression(phantom(0)*phantom(0)%<-%"L"[50]), adj=c(0,0.5), cex=fAxis)
            text(xc[xLabPos]-0.25, yLabPos-10.9, expression(phantom(0)*phantom(0)%<-%"L"[90]), adj=c(0,0.5), cex=fAxis)
          }
          if (hasDay) rect(xc[xLabPos+3], yLabPos-2, xc[xLabPos+3]+0.5, yLabPos-4, col=dayColor[1], border=dayColor[2], lwd=myLWD)
          if (hasNight) rect(xc[xLabPos+3], yLabPos-8, xc[xLabPos+3]+0.5, yLabPos-10, col=nightColor[1], border=nightColor[2], lwd=myLWD)
          if (hasDay) text(xc[xLabPos+3]+0.75, yLabPos-3, dayStringLbl, adj=c(0,0.5), cex=fAxis)
          if (hasNight) text(xc[xLabPos+3]+0.75, yLabPos-9, nightStringLbl, adj=c(0,0.5), cex=fAxis)
          
          segments(10, yMinHz+5.5, 19, yMinHz+5.5, lwd=myLWD, col="grey50")
          segments(10, yMinHz+5.5, 10, yMinHz+7.5, lwd=myLWD, col="grey50")
          segments(19, yMinHz+5.5, 19, yMinHz+7.5, lwd=myLWD, col="grey50")
          segments(14.5, yMinHz+5.5, 14.5, yMinHz+3.5, lwd=myLWD, col="grey50")
          text(14.5, yMinHz+2.15, "Transportation", cex=fAxis, col="grey50")
          
          segments(15, yMaxHz-5.5, 25, yMaxHz-5.5, lwd=myLWD, col="grey50")
          segments(15, yMaxHz-5.5, 15, yMaxHz-7.5, lwd=myLWD, col="grey50")
          segments(25, yMaxHz-5.5, 25, yMaxHz-7.5, lwd=myLWD, col="grey50")
          segments(20, yMaxHz-3.5, 20, yMaxHz-5.5, lwd=myLWD, col="grey50")
          text(20, yMaxHz-2.25, "Conversation", cex=fAxis, col="grey50")
          
          segments(20, yMinHz+5.5, 29, yMinHz+5.5, lwd=myLWD, col="grey50")
          segments(20, yMinHz+5.5, 20, yMinHz+7.5, lwd=myLWD, col="grey50")
          segments(29, yMinHz+5.5, 29, yMinHz+7.5, lwd=myLWD, col="grey50")
          segments(24.5, yMinHz+5.5, 24.5, yMinHz+3.5, lwd=myLWD, col="grey50")
          text(24.5, yMinHz+2.15, "Song birds", cex=fAxis, col="grey50")
          
          text(4, yMinHz+15, "Threshold of human hearing", cex=fAxis, col="grey50", srt=-45)
          graphics.off()
        }
      }
      
      ## Contour plots
      if (plotCONTOUR) {
        dataPos <- grep("L[0-9a-zA-Z]{2,3} Contour", fileData)
        dataPos <- dataPos[grepl(season, fileData[dataPos])]
        if (length(dataPos) != 0) {
          for (sIdx in seq_along(dataPos)) {
            gInfo <- scan(filesToPlot[i], skip=dataPos[sIdx]-1, sep="\n", nlines=1, what="character")
            nSamples <- gsub(".*=\\s(\\d+)hr.*","\\1",gInfo)
            lVal <- gsub("L([0-9a-zA-Z]{2,3}).*","\\1",gInfo)
            pngFile <- file.path(outDir, paste0(siteID, "_", season, "_L", lVal, "_CONTOUR.png"))
            hzhrTitleA <- paste0(hzhrTitle, "L")
            hzhrTitleB <- if (titlesOnPlots) paste0(" (", season, ")") else ""
            
            data <- as.matrix(read.table(filesToPlot[i], skip=dataPos[sIdx], nrows=24, header=TRUE,
                                         sep="\t"))[, 2:34]
            freqs <- c("20","40","80","160","315","630","1.25k","2.5k","5k","10k","20k")
            
            png(filename = pngFile, width = pngWidth, height = pngHeight)
            par(mar=c(fTitle*2, fTitle*2+2, fAxis*2, fAxis)+0.1, mgp=c(fTitle,1,0), ljoin=1, lend=2)
            body(filled.contour)[[grep("rect", body(filled.contour))]] <-
              substitute(rect(0, levels[-length(levels)], 1, levels[-1L], col = col, border = col))
            filled.contour(x=0:23, y=1:33, data, zlim=c(-9,87),
                           col=colorRampPalette(c("blue","orange","white"))(960), nlevels=960,
                           key.axes = axis(4, at=seq(-9,87,6), las=2, cex.axis=fAxis),
                           plot.axes = {
                             axis(1, at=0:23, labels=TRUE, cex.axis=fAxis, line=2, fg="white")
                             axis(2, at=seq(3,33,3), labels=freqs, las=2, cex.axis=fAxis)
                           },
                           plot.title = title(main=substitute(titleA[x]*titleB, list(titleA=hzhrTitleA, x=lVal, titleB=hzhrTitleB)),
                                              xlab="", ylab="", cex.main=fTitle))
            mtext("Hour", side=1, line=fTitle+2, cex=fLab)
            mtext(paste0("n = ", nSamples), side=1, line=fTitle*2-1, cex=fAxis)
            mtext("Frequency (Hz)", side=2, line=fTitle+4, cex=fLab)
            mtext("Sound Pressure Level (dB)", side=4, line=3, cex=fAxis)
            graphics.off()
          }
        }
      }
    }
  }
  
  message(sprintf("  Done. Output written to: %s", outDir))
}

## ---------------------------------------------------------------------
## 11. TREND GRAPHS ACROSS SEASONS/YEARS
##     Only runs if more than one season/year combo exists for this park.
##     Re-scans <REPORTS>/<park_code>/ for every <order>_<season>_<year>
##     folder (not just the ones processed in this run), combines the
##     matching CSVs across all of them, and builds one trend graph per
##     site (and per metric grouping) into <REPORTS>/<park_code>_trends/.
## ---------------------------------------------------------------------

if (build_trends) {
  
  ## -- Discover all season/year folders for this park, in chronological order --
  trend_dirs_all <- list.dirs(park_report_dir, recursive = FALSE, full.names = TRUE)
  dir_pattern <- "^(\\d+)_([A-Za-z]+)_(\\d{4})$"
  dir_names <- basename(trend_dirs_all)
  dir_match <- str_match(dir_names, dir_pattern)
  valid_idx <- !is.na(dir_match[, 1])
  
  trend_meta <- data.frame(
    dir    = trend_dirs_all[valid_idx],
    order  = as.numeric(dir_match[valid_idx, 2]),
    season = dir_match[valid_idx, 3],
    year   = dir_match[valid_idx, 4],
    stringsAsFactors = FALSE
  )
  trend_meta <- trend_meta[order(trend_meta$order), ]
  
  if (nrow(trend_meta) < trend_min_combos) {
    message(sprintf("\nOnly %d season/year combo(s) found for %s - skipping trend graphs (need at least %d).",
                    nrow(trend_meta), park_code, trend_min_combos))
  } else {
    
    message(sprintf("\n=== Building trend graphs across %d season/year combos for %s ===",
                    nrow(trend_meta), park_code))
    
    ## Trends now live INSIDE the park's own report folder, not as a
    ## sibling: <REPORTS>/<park_code>/trends/<Season>/...
    trends_dir <- file.path(park_report_dir, "trends")
    dir.create(trends_dir, recursive = TRUE, showWarnings = FALSE)
    
    safe_name <- function(x) gsub("[^A-Za-z0-9_-]+", "_", x)
    
    combine_csvs_by_pattern <- function(pattern) {
      rows <- list()
      for (i in seq_len(nrow(trend_meta))) {
        files <- list.files(trend_meta$dir[i], pattern = pattern, full.names = TRUE)
        for (f in files) {
          d <- tryCatch(read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
          if (is.null(d) || nrow(d) == 0) next
          d$season <- trend_meta$season[i]
          d$year   <- trend_meta$year[i]
          d$order  <- trend_meta$order[i]
          d$src_file <- basename(f)
          rows[[length(rows) + 1]] <- d
        }
      }
      if (length(rows) == 0) return(NULL)
      dplyr::bind_rows(rows)
    }
    
    seasons_present <- unique(trend_meta$season)
    
    ## Filters a combined long-format dataframe down to one season and
    ## builds a chronological (by year) x-axis factor for it, plus the
    ## per-season output subfolder. Returns NULL if that season doesn't
    ## have at least 2 distinct years - a single-year season has nothing
    ## to trend against.
    prep_season_subset <- function(df, season_name) {
      df1 <- df %>% filter(season == season_name)
      yrs <- sort(unique(df1$year))
      if (length(yrs) < 2) return(NULL)
      df1$year <- factor(df1$year, levels = yrs)
      df1
    }
    
    season_out_dir <- function(season_name) {
      d <- file.path(trends_dir, season_name)
      dir.create(d, recursive = TRUE, showWarnings = FALSE)
      d
    }
    
    ## -- 1) ambfullsum: LA10/LA50/LAnat/LA90 x Day/Night, per site, per season --
    amb_trend <- combine_csvs_by_pattern("^ambfullsum_.*\\.csv$")
    if (!is.null(amb_trend) && all(c("SiteID","Time","LA10","LA50","LAnat","LA90") %in% names(amb_trend))) {
      for (sea in seasons_present) {
        df_sea <- prep_season_subset(amb_trend, sea)
        if (is.null(df_sea)) next
        out_dir_sea <- season_out_dir(sea)
        
        amb_long <- df_sea %>%
          pivot_longer(cols = c(LA10, LA50, LAnat, LA90), names_to = "Metric", values_to = "Value") %>%
          mutate(Metric = factor(Metric, levels = c("LA10","LA50","LAnat","LA90")),
                 Time = factor(Time, levels = c("Day","Night")))
        
        for (site in unique(amb_long$SiteID)) {
          df1 <- amb_long %>% filter(SiteID == site)
          p <- ggplot(df1, aes(x = year, y = Value, color = Metric, linetype = Time, group = interaction(Metric, Time))) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_brewer(palette = "Set1") +
            labs(title = paste0(site, ": Ambient Sound Level Trend (", sea, ")"),
                 x = "Year", y = "Sound Level (dBA)", color = "Metric", linetype = "Time") +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_AmbientLevels.png")),
                      plot = p, width = 9, height = 5.5)
        }
      }
      message("  Ambient level trends: done.")
    } else {
      message("  Skipping ambfullsum trends (no matching files found).")
    }
    
    ## -- 2) timeabove: 4 dB thresholds x Day/Night, per site per season per frequency band --
    ta_trend <- combine_csvs_by_pattern("^timeabove_.*\\.csv$")
    if (!is.null(ta_trend) && "Site.ID" %in% names(ta_trend)) {
      names(ta_trend)[names(ta_trend) == "Site.ID"] <- "SiteID"
    }
    if (!is.null(ta_trend) && all(c("SiteID","Frequency..Hz.") %in% names(ta_trend))) {
      names(ta_trend)[names(ta_trend) == "Frequency..Hz."] <- "FreqBand"
      value_cols <- grep("^X?35|^X?45|^X?52|^X?60", names(ta_trend), value = TRUE)
      
      for (sea in seasons_present) {
        df_sea <- prep_season_subset(ta_trend, sea)
        if (is.null(df_sea)) next
        out_dir_sea <- season_out_dir(sea)
        
        ta_long <- df_sea %>%
          pivot_longer(cols = all_of(value_cols), names_to = "col", values_to = "Value") %>%
          mutate(
            dB = str_extract(col, "35|45|52|60"),
            DayNight = ifelse(grepl("Night", col), "Night", "Day"),
            dB = factor(dB, levels = c("35","45","52","60"))
          )
        
        for (site in unique(ta_long$SiteID)) {
          for (fb in unique(ta_long$FreqBand[ta_long$SiteID == site])) {
            df1 <- ta_long %>% filter(SiteID == site, FreqBand == fb)
            if (nrow(df1) == 0) next
            p <- ggplot(df1, aes(x = year, y = Value, color = dB, linetype = DayNight, group = interaction(dB, DayNight))) +
              geom_line(linewidth = 0.9) + geom_point(size = 2) +
              scale_color_brewer(palette = "Set1") +
              labs(title = paste0(site, ": Time Above Threshold Trend (", sea, ", ", fb, ")"),
                   x = "Year", y = "Time Above Threshold (%)", color = "dB Threshold", linetype = "Time") +
              theme_classic(base_size = 11)
            safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_TimeAbove_", safe_name(fb), ".png")),
                        plot = p, width = 9, height = 5.5)
          }
        }
      }
      message("  Time-above trends: done.")
    } else {
      message("  Skipping timeabove trends (no matching files found).")
    }
    
    ## -- 3) impactlisteningarea: Impact (dB) and LAR (%) as separate plots, per season --
    imp_trend <- combine_csvs_by_pattern("^impactlisteningarea_.*\\.csv$")
    if (!is.null(imp_trend) && all(c("SiteID","DayImpact","NightImpact","AllImpact","DayLAR","NightLAR","AllLAR") %in% names(imp_trend))) {
      for (sea in seasons_present) {
        df_sea <- prep_season_subset(imp_trend, sea)
        if (is.null(df_sea)) next
        out_dir_sea <- season_out_dir(sea)
        
        imp_long_impact <- df_sea %>%
          pivot_longer(cols = c(DayImpact, NightImpact, AllImpact), names_to = "Period", values_to = "Impact") %>%
          mutate(Period = factor(gsub("Impact", "", Period), levels = c("Day","Night","All")))
        imp_long_lar <- df_sea %>%
          pivot_longer(cols = c(DayLAR, NightLAR, AllLAR), names_to = "Period", values_to = "LAR") %>%
          mutate(Period = factor(gsub("LAR", "", Period), levels = c("Day","Night","All")))
        
        for (site in unique(df_sea$SiteID)) {
          df_i <- imp_long_impact %>% filter(SiteID == site)
          p1 <- ggplot(df_i, aes(x = year, y = Impact, color = Period, group = Period)) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_brewer(palette = "Dark2") +
            labs(title = paste0(site, ": Noise Impact Trend (", sea, ")"), x = "Year",
                 y = "Impact (dBA, Existing - Natural)", color = NULL) +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_Impact.png")), plot = p1, width = 9, height = 5.5)
          
          df_l <- imp_long_lar %>% filter(SiteID == site)
          p2 <- ggplot(df_l, aes(x = year, y = LAR, color = Period, group = Period)) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_brewer(palette = "Dark2") +
            labs(title = paste0(site, ": Listening Area Reduction Trend (", sea, ")"), x = "Year",
                 y = "Listening Area Reduction (%)", color = NULL) +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_ListeningAreaReduction.png")), plot = p2, width = 9, height = 5.5)
        }
      }
      message("  Impact / listening area reduction trends: done.")
    } else {
      message("  Skipping impactlisteningarea trends (no matching files found).")
    }
    
    ## -- 4) NoiseFreeInterval: daily mean per percentile, per site, per season --
    nfi_trend <- combine_csvs_by_pattern("_NoiseFreeInterval_.*\\.csv$")
    if (!is.null(nfi_trend) && all(c("Percentile","SiteID") %in% names(nfi_trend))) {
      hour_cols <- grep("^X?[0-2][0-9]h?$", names(nfi_trend), value = TRUE)
      nfi_trend$DailyMean <- rowMeans(nfi_trend[, hour_cols], na.rm = TRUE)
      
      for (sea in seasons_present) {
        df_sea <- prep_season_subset(nfi_trend, sea)
        if (is.null(df_sea)) next
        out_dir_sea <- season_out_dir(sea)
        
        df_sea <- df_sea %>% mutate(Percentile = factor(Percentile, levels = c("90%","50%","10%","Mean")))
        
        for (site in unique(df_sea$SiteID)) {
          df1 <- df_sea %>% filter(SiteID == site)
          p <- ggplot(df1, aes(x = year, y = DailyMean, color = Percentile, group = Percentile)) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_manual(values = c("90%" = "#4C72B0", "50%" = "#55A868", "10%" = "#C44E52", "Mean" = "black")) +
            labs(title = paste0(site, ": Noise-Free Interval Trend (", sea, ", 24-hr Average)"),
                 x = "Year", y = "Mean Noise-Free Interval (sec)", color = "Percentile") +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_NoiseFreeInterval.png")), plot = p, width = 9, height = 5.5)
        }
      }
      message("  Noise-free interval trends: done.")
    } else {
      message("  Skipping NoiseFreeInterval trends (no matching files found).")
    }
    
    ## -- 5) EventCountsLengths: top N sources by average count, per site, per season --
    ecl_trend <- combine_csvs_by_pattern("_EventCountsLengths_.*\\.csv$")
    if (!is.null(ecl_trend) && all(c("SiteID","Source Description","Day_Count","Night_Count","Day_Length","Night_Length") %in% names(ecl_trend))) {
      ecl_trend <- ecl_trend %>%
        mutate(AvgCount = rowMeans(cbind(Day_Count, Night_Count), na.rm = TRUE),
               AvgLength = rowMeans(cbind(Day_Length, Night_Length), na.rm = TRUE))
      
      for (sea in seasons_present) {
        df_sea <- prep_season_subset(ecl_trend, sea)
        if (is.null(df_sea)) next
        out_dir_sea <- season_out_dir(sea)
        
        for (site in unique(df_sea$SiteID)) {
          df1 <- df_sea %>% filter(SiteID == site)
          
          top_sources <- df1 %>%
            group_by(`Source Description`) %>%
            summarize(overall_avg = mean(AvgCount, na.rm = TRUE), .groups = "drop") %>%
            arrange(desc(overall_avg)) %>%
            slice_head(n = trend_top_n_sources) %>%
            pull(`Source Description`)
          
          df_top <- df1 %>% filter(`Source Description` %in% top_sources)
          if (nrow(df_top) == 0) next
          
          p1 <- ggplot(df_top, aes(x = year, y = AvgCount, color = `Source Description`, group = `Source Description`)) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_brewer(palette = "Set2") +
            labs(title = paste0(site, ": Top ", length(top_sources), " Noise Source Event Count Trend (", sea, ")"),
                 x = "Year", y = "Average Daily Event Count", color = "Source") +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_EventCount_TopSources.png")), plot = p1, width = 9.5, height = 5.5)
          
          p2 <- ggplot(df_top, aes(x = year, y = AvgLength, color = `Source Description`, group = `Source Description`)) +
            geom_line(linewidth = 0.9) + geom_point(size = 2) +
            scale_color_brewer(palette = "Set2") +
            labs(title = paste0(site, ": Top ", length(top_sources), " Noise Source Event Length Trend (", sea, ")"),
                 x = "Year", y = "Average Event Length (sec)", color = "Source") +
            theme_classic(base_size = 11)
          safe_ggsave(file.path(out_dir_sea, paste0(safe_name(site), "_trend_EventLength_TopSources.png")), plot = p2, width = 9.5, height = 5.5)
        }
      }
      message("  Event count/length trends: done.")
    } else {
      message("  Skipping EventCountsLengths trends (no matching files found).")
    }
    
    message(sprintf("Trend graphs written to: %s", trends_dir))
  }
}

message("\nAll combinations processed.")