suppressPackageStartupMessages(library(terra))

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2) {
  stop("usage: verify_rasters.R RESULTS_DIR POINT_CLOUD")
}
results_dir <- arguments[[1]]
point_cloud <- arguments[[2]]
header <- lidR::readLASheader(point_cloud)
point_bounds <- c(
  xmin = as.numeric(header@PHB[["Min X"]]),
  ymin = as.numeric(header@PHB[["Min Y"]]),
  xmax = as.numeric(header@PHB[["Max X"]]),
  ymax = as.numeric(header@PHB[["Max Y"]])
)

case_directories <- list.dirs(results_dir, recursive = FALSE, full.names = TRUE)
case_directories <- case_directories[
  !startsWith(basename(case_directories), "failure_")
]
if (length(case_directories) != 7) stop("unexpected number of acceptance cases")

for (output_dir in case_directories) {
  dataset_id <- "150"
  result_paths <- list.files(
    output_dir,
    pattern = sprintf("^%s(_[A-Za-z0-9_-]+)?_results[.]csv$", dataset_id),
    full.names = TRUE
  )
  if (length(result_paths) < 1) stop("no tile result CSV found")
  csv <- read.csv(result_paths[[1]], na.strings = "NA")
  expected_tiles <- nrow(csv)
  dtm <- rast(file.path(output_dir, sprintf("%s_dtm.tif", dataset_id)))
  if (!all(abs(res(dtm) - c(1, 1)) < 1e-9)) stop("DTM resolution is not 1 m")
  if (!nzchar(crs(dtm))) stop("DTM did not preserve available CRS metadata")
  if (xmin(dtm) > point_bounds[["xmin"]] ||
      xmax(dtm) < point_bounds[["xmax"]] ||
      ymin(dtm) > point_bounds[["ymin"]] ||
      ymax(dtm) < point_bounds[["ymax"]]) {
    stop("DTM does not cover the complete point-cloud XY extent")
  }

  chm <- rast(file.path(output_dir, sprintf("%s_chm.tif", dataset_id)))
  if (!all(abs(res(chm) - c(0.5, 0.5)) < 1e-9)) stop("CHM resolution is not 0.5 m")
  if (!nzchar(crs(chm))) stop("CHM did not preserve available CRS metadata")
  if (xmin(chm) > point_bounds[["xmin"]] ||
      xmax(chm) < point_bounds[["xmax"]] ||
      ymin(chm) > point_bounds[["ymin"]] ||
      ymax(chm) < point_bounds[["ymax"]]) {
    stop("CHM does not cover the complete point-cloud XY extent")
  }
  if (dir.exists(file.path(output_dir, "chm"))) {
    stop("per-tile CHM directory must not be created")
  }
}
