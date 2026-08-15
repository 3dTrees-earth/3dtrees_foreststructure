suppressPackageStartupMessages({
  library(data.table)
  library(sf)
  library(terra)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2) stop("usage: compare_runs.R BASELINE_ROOT CANDIDATE_ROOT")
dataset_id <- "999999"
instance_dimension <- "PredInstance"
artifact_prefix <- paste(dataset_id, instance_dimension, sep = "_")

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
    fread(file.path(baseline, paste0(artifact_prefix, "_results.csv")), na.strings = "NA"),
    fread(file.path(candidate, paste0(artifact_prefix, "_results.csv")), na.strings = "NA"),
    paste(case_name, "tile CSV")
  )
  assert_equal(
    fread(
      file.path(baseline, paste0(artifact_prefix, "_segment_diagnostics.csv")),
      na.strings = "NA"
    ),
    fread(
      file.path(candidate, paste0(artifact_prefix, "_segment_diagnostics.csv")),
      na.strings = "NA"
    ),
    paste(case_name, "segment diagnostics")
  )

  baseline_tiles <- st_read(
    file.path(baseline, paste0(artifact_prefix, "_tiles.geojson")), quiet = TRUE
  )
  candidate_tiles <- st_read(
    file.path(candidate, paste0(artifact_prefix, "_tiles.geojson")), quiet = TRUE
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
    file.path(baseline, paste0(dataset_id, "_dtm.tif")),
    file.path(candidate, paste0(dataset_id, "_dtm.tif")),
    paste(case_name, "DTM")
  )
  assert_raster_equal(
    file.path(baseline, paste0(dataset_id, "_chm.tif")),
    file.path(candidate, paste0(dataset_id, "_chm.tif")),
    paste(case_name, "CHM")
  )
}

cat("Scientific outputs match within absolute/relative tolerance 1e-9.\n")
