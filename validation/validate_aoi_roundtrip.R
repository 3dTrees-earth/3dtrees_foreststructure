suppressPackageStartupMessages({
  library(jsonlite)
  library(sf)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) < 1L || length(arguments) > 2L) {
  stop("usage: validate_aoi_roundtrip.R AOI_GEOJSON [REPORT_JSON]")
}

command <- commandArgs(trailingOnly = FALSE)
script_argument <- grep("^--file=", command, value = TRUE)
if (length(script_argument) != 1L) {
  stop("cannot locate validation script path")
}
script_path <- normalizePath(sub("^--file=", "", script_argument[[1L]]))
repository_root <- dirname(dirname(script_path))
source(file.path(repository_root, "src", "aoi_conversion.R"))

source_geojson <- normalizePath(arguments[[1L]], mustWork = TRUE)
temporary_gpkg <- tempfile(fileext = ".gpkg")
on.exit(unlink(temporary_gpkg, force = TRUE), add = TRUE)

expected <- effective_geojson_geometry(source_geojson)
st_write(
  st_sf(role = "include", geometry = expected),
  temporary_gpkg,
  layer = "include",
  driver = "GPKG",
  delete_dsn = TRUE,
  quiet = TRUE
)
converted <- st_read(
  temporary_gpkg,
  layer = "include",
  quiet = TRUE,
  stringsAsFactors = FALSE
)
st_crs(converted) <- NA
actual <- polygonal_union(converted, "converted inclusion")

expected_summary <- geometry_summary(expected)
actual_summary <- geometry_summary(actual)
topology_equal <- isTRUE(st_equals(expected, actual, sparse = FALSE)[[1L, 1L]])
bounds_equal <- identical(expected_summary$bounds, actual_summary$bounds)
coordinates_equal <- identical(
  canonical_polygon_coordinate_signature(expected),
  canonical_polygon_coordinate_signature(actual)
)
area_delta <- abs(expected_summary$area - actual_summary$area)
area_equal <- aoi_areas_equal(expected_summary$area, actual_summary$area)
valid <- topology_equal && bounds_equal && coordinates_equal && area_equal

report <- list(
  status = if (valid) "valid" else "invalid",
  source_geojson = source_geojson,
  area_tolerance = 1e-6,
  expected_area = expected_summary$area,
  converted_area = actual_summary$area,
  area_delta = area_delta,
  area_within_tolerance = area_equal,
  topology_equal = topology_equal,
  bounds_equal = bounds_equal,
  canonical_coordinates_equal = coordinates_equal
)
encoded <- toJSON(report, auto_unbox = TRUE, pretty = TRUE, digits = 17)
if (length(arguments) == 2L) {
  writeLines(encoded, arguments[[2L]], useBytes = TRUE)
} else {
  writeLines(encoded)
}
if (!valid) quit(save = "no", status = 1L)
