suppressPackageStartupMessages({
  library(jsonlite)
  library(terra)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 3L) {
  stop("usage: compare_julia_dtm.R JULIA_DTM CANDIDATE_DTM REPORT_JSON")
}

julia_dtm <- rast(arguments[[1]])
candidate_dtm <- rast(arguments[[2]])
geometry_equal <- compareGeom(
  julia_dtm,
  candidate_dtm,
  crs = TRUE,
  ext = TRUE,
  rowcol = TRUE,
  res = TRUE,
  stopOnError = FALSE
)
if (!isTRUE(geometry_equal)) stop("Julia and candidate DTM geometry differs")

julia_values <- values(julia_dtm, mat = FALSE)
candidate_values <- values(candidate_dtm, mat = FALSE)
if (!identical(is.na(julia_values), is.na(candidate_values))) {
  stop("Julia and candidate DTM NA masks differ")
}
populated <- !is.na(julia_values)
differing <- which(julia_values[populated] != candidate_values[populated])
if (length(differing) > 0L) {
  stop(sprintf(
    "Julia and candidate DTM differ in %d populated cell(s)",
    length(differing)
  ))
}

report <- list(
  status = "valid",
  comparison = "zero-tolerance cell equality",
  geometry_equal = TRUE,
  cells = ncell(julia_dtm),
  populated_cells = sum(populated),
  differing_cells = 0,
  resolution = as.numeric(res(julia_dtm)),
  extent = c(
    xmin = xmin(julia_dtm),
    xmax = xmax(julia_dtm),
    ymin = ymin(julia_dtm),
    ymax = ymax(julia_dtm)
  ),
  crs = crs(julia_dtm),
  julia_datatype = datatype(julia_dtm),
  candidate_datatype = datatype(candidate_dtm)
)
write_json(report, arguments[[3]], auto_unbox = TRUE, pretty = TRUE)
message(sprintf(
  "Julia DTM equivalence passed: %d cells, zero differing values",
  ncell(julia_dtm)
))
