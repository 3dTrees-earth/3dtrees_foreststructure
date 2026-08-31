suppressPackageStartupMessages({
  library(jsonlite)
  library(terra)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 3L) {
  stop(
    "usage: compare_julia_dtm_overlap.R JULIA_DTM CANDIDATE_DTM REPORT_JSON"
  )
}

julia_dtm <- rast(arguments[[1]])
candidate_dtm <- rast(arguments[[2]])
julia_overlap <- crop(julia_dtm, candidate_dtm, snap = "near")
candidate_overlap <- crop(candidate_dtm, julia_dtm, snap = "near")

shared_geometry_equal <- compareGeom(
  julia_overlap,
  candidate_overlap,
  crs = TRUE,
  ext = TRUE,
  rowcol = TRUE,
  res = TRUE,
  stopOnError = FALSE
)
crs_equal <- identical(crs(julia_dtm), crs(candidate_dtm))
julia_values <- values(julia_overlap, mat = FALSE)
candidate_values <- values(candidate_overlap, mat = FALSE)
na_mask_equal <- identical(is.na(julia_values), is.na(candidate_values))
populated <- !is.na(julia_values) & !is.na(candidate_values)
differences <- abs(julia_values[populated] - candidate_values[populated])
differing_cells <- sum(differences != 0)
maximum_absolute_difference <- if (length(differences) == 0L) {
  0
} else {
  max(differences)
}

valid <- isTRUE(shared_geometry_equal) && crs_equal && na_mask_equal &&
  differing_cells == 0L
report <- list(
  status = if (valid) "valid" else "invalid",
  comparison = "zero-tolerance equality over complete shared DTM grid",
  full_geometry_equal = isTRUE(compareGeom(
    julia_dtm,
    candidate_dtm,
    crs = TRUE,
    ext = TRUE,
    rowcol = TRUE,
    res = TRUE,
    stopOnError = FALSE
  )),
  shared_geometry_equal = isTRUE(shared_geometry_equal),
  crs_equal = crs_equal,
  julia_has_crs = nzchar(crs(julia_dtm)),
  candidate_has_crs = nzchar(crs(candidate_dtm)),
  na_mask_equal = na_mask_equal,
  shared_cells = ncell(julia_overlap),
  shared_populated_cells = sum(populated),
  differing_cells = differing_cells,
  maximum_absolute_difference = maximum_absolute_difference,
  julia_dimensions = c(ncol = ncol(julia_dtm), nrow = nrow(julia_dtm)),
  candidate_dimensions = c(
    ncol = ncol(candidate_dtm),
    nrow = nrow(candidate_dtm)
  ),
  julia_extent = c(
    xmin = xmin(julia_dtm),
    xmax = xmax(julia_dtm),
    ymin = ymin(julia_dtm),
    ymax = ymax(julia_dtm)
  ),
  candidate_extent = c(
    xmin = xmin(candidate_dtm),
    xmax = xmax(candidate_dtm),
    ymin = ymin(candidate_dtm),
    ymax = ymax(candidate_dtm)
  )
)
write_json(report, arguments[[3]], auto_unbox = TRUE, pretty = TRUE)
if (!valid) stop("Julia and candidate DTM overlap differs")
message(sprintf(
  paste0(
    "Julia DTM shared-grid equivalence passed: %d cells, ",
    "zero differing values; full geometry equal=%s"
  ),
  ncell(julia_overlap),
  report$full_geometry_equal
))
