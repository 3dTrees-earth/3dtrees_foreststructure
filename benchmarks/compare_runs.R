suppressPackageStartupMessages({
  library(data.table)
  library(sf)
  library(terra)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2) stop("usage: compare_runs.R BASELINE_ROOT CANDIDATE_ROOT")

assert_equal <- function(left, right, label, tolerance = 1e-9) {
  comparison <- all.equal(left, right, tolerance = tolerance, check.attributes = FALSE)
  if (!isTRUE(comparison)) stop(label, ": ", paste(comparison, collapse = "; "))
}

assert_raster_equal <- function(left_path, right_path, label) {
  left <- rast(left_path)
  right <- rast(right_path)
  if (!compareGeom(left, right, stopOnError = FALSE, crs = TRUE)) {
    stop(label, ": raster geometry or CRS differs")
  }
  left_values <- values(left, mat = FALSE)
  right_values <- values(right, mat = FALSE)
  assert_equal(left_values, right_values, paste0(label, " values"))
}

for (case_name in c("small", "large")) {
  baseline <- file.path(arguments[[1]], case_name)
  candidate <- file.path(arguments[[2]], case_name)

  assert_equal(
    fread(file.path(baseline, "forest_structure_tiles.csv"), na.strings = "NA"),
    fread(file.path(candidate, "forest_structure_tiles.csv"), na.strings = "NA"),
    paste(case_name, "tile CSV")
  )
  assert_equal(
    fread(file.path(baseline, "segment_diagnostics.csv"), na.strings = "NA"),
    fread(file.path(candidate, "segment_diagnostics.csv"), na.strings = "NA"),
    paste(case_name, "segment diagnostics")
  )

  baseline_tiles <- st_read(
    file.path(baseline, "forest_structure_tiles.geojson"), quiet = TRUE
  )
  candidate_tiles <- st_read(
    file.path(candidate, "forest_structure_tiles.geojson"), quiet = TRUE
  )
  assert_equal(st_drop_geometry(baseline_tiles), st_drop_geometry(candidate_tiles),
    paste(case_name, "tile GeoJSON attributes"))
  geometry_matches <- st_equals_exact(
    baseline_tiles,
    candidate_tiles,
    par = 1e-9,
    sparse = FALSE
  )
  if (!all(diag(geometry_matches))) {
    stop(case_name, ": tile GeoJSON geometry differs")
  }

  assert_raster_equal(
    file.path(baseline, "forest_structure_dtm.tif"),
    file.path(candidate, "forest_structure_dtm.tif"),
    paste(case_name, "DTM")
  )
  baseline_chms <- list.files(file.path(baseline, "chm"), full.names = TRUE)
  candidate_chms <- list.files(file.path(candidate, "chm"), full.names = TRUE)
  if (!identical(basename(baseline_chms), basename(candidate_chms))) {
    stop(case_name, ": CHM names differ")
  }
  for (index in seq_along(baseline_chms)) {
    assert_raster_equal(
      baseline_chms[[index]],
      candidate_chms[[index]],
      paste(case_name, basename(baseline_chms[[index]]))
    )
  }
}

cat("Scientific outputs match within absolute/relative tolerance 1e-9.\n")
