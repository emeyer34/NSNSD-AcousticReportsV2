run_logic <- function(spics, gsm, lcdet, pa_fig_end, sitenum, dirs) {
  results <- list()
  
  fig_counter <- pa_fig_end + 1  # Start figure numbering after pa_fig_end
  
  # Helper: Define site figures
  define_site_figures <- function(start_index) {
    site_fig_start <- start_index
    site_fig_end <- sitenum - 1 + site_fig_start
    site_fig_list <- as.list(seq(from = site_fig_start, to = site_fig_end, by = 1))
    return(list(
      site_fig_list = site_fig_list,
      site_fig_start = site_fig_start,
      site_fig_end = site_fig_end
    ))
  }
  
  # Helper: Define GSM figures
  define_gsm_figures <- function(start_index) {
    gsm_exist <- start_index
    gsm_natural <- gsm_exist + 1
    gsm_impact <- gsm_natural + 1
    return(list(
      gsm_exist = gsm_exist,
      gsm_natural = gsm_natural,
      gsm_impact = gsm_impact,
      gsm_end = gsm_impact
    ))
  }
  
  # Helper: Define detailed percent audibility figures
  define_det_pa_figures <- function(start_index) {
    detpalist <- list.files(path = dirs, pattern = "PercentAud_description_all", full.names = TRUE)
    det_pa_start <- start_index
    det_pa_end <- length(detpalist) - 1 + det_pa_start
    det_pa_fig_list <- as.list(seq(from = det_pa_start, to = det_pa_end, by = 1))
    return(list(
      det_pa_fig_list = det_pa_fig_list,
      det_pa_start = det_pa_start,
      det_pa_end = det_pa_end,
      det_pa_first = det_pa_fig_list[[1]],
      det_pa_last = det_pa_fig_list[[length(det_pa_fig_list)]]
    ))
  }
  
  # Include spics section
  if (spics == "A") {
    site_fig_data <- define_site_figures(fig_counter)
    results$site_fig_list <- site_fig_data$site_fig_list
    results$site_fig_start <- site_fig_data$site_fig_start
    results$site_fig_end <- site_fig_data$site_fig_end
    fig_counter <- site_fig_data$site_fig_end + 1
  }
  
  # Include gsm section
  if (gsm %in% c("A", "B")) {
    gsm_data <- define_gsm_figures(fig_counter)
    results$gsm_indices <- list(
      gsm_exist = gsm_data$gsm_exist,
      gsm_natural = gsm_data$gsm_natural,
      gsm_impact = gsm_data$gsm_impact
    )
    fig_counter <- gsm_data$gsm_end + 1
  }
  
  # Include lcdet section
  if (lcdet %in% c("A", "B", "C")) {
    if (!is.null(results$gsm_indices)) {
      gsm_impact <- results$gsm_indices$gsm_impact
    } else {
      gsm_impact <- fig_counter - 1  # If GSM not present, start from current counter
    }
    det_pa_data <- define_det_pa_figures(gsm_impact + 1)
    results$det_pa_fig_list <- det_pa_data$det_pa_fig_list
    results$det_pa_start <- det_pa_data$det_pa_start
    results$det_pa_end <- det_pa_data$det_pa_end
    results$det_pa_first <- det_pa_data$det_pa_first
    results$det_pa_last <- det_pa_data$det_pa_last
    fig_counter <- det_pa_data$det_pa_end + 1
  }
  
  return(results)
}
