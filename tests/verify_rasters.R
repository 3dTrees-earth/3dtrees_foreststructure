suppressPackageStartupMessages(library(terra))

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 1) stop("usage: verify_rasters.R RESULTS_DIR")
results_dir <- arguments[[1]]

case_directories <- list.dirs(results_dir, recursive = FALSE, full.names = TRUE)
if (length(case_directories) != 6) stop("unexpected number of acceptance cases")

for (output_dir in case_directories) {
  csv <- read.csv(file.path(output_dir, "forest_structure_tiles.csv"), na.strings = "NA")
  expected_tiles <- nrow(csv)
  dtm <- rast(file.path(output_dir, "forest_structure_dtm.tif"))
  if (!all(abs(res(dtm) - c(1, 1)) < 1e-9)) stop("DTM resolution is not 1 m")
  if (!nzchar(crs(dtm))) stop("DTM did not preserve available CRS metadata")

  chm_paths <- list.files(
    file.path(output_dir, "chm"),
    pattern = "^tile_[0-9]{6}_chm\\.tif$",
    full.names = TRUE
  )
  if (length(chm_paths) != expected_tiles) stop("unexpected CHM count")
  for (path in chm_paths) {
    chm <- rast(path)
    if (!all(abs(res(chm) - c(0.5, 0.5)) < 1e-9)) stop("CHM resolution is not 0.5 m")
    dimensions <- c(xmax(chm) - xmin(chm), ymax(chm) - ymin(chm))
    if (!all(abs(dimensions - c(20, 20)) < 1e-9)) {
      stop("CHM extent does not match one Analysis Tile")
    }
    if (!nzchar(crs(chm))) stop("CHM did not preserve available CRS metadata")
  }
}
