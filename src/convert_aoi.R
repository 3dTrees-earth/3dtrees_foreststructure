suppressPackageStartupMessages(library(argparse))

script_argument <- grep(
  "^--file=",
  commandArgs(trailingOnly = FALSE),
  value = TRUE
)
script_directory <- if (length(script_argument)) {
  dirname(normalizePath(sub("^--file=", "", script_argument[[1]])))
} else {
  getwd()
}
Sys.setenv(FORESTSTRUCTURE_SOURCE_ONLY = "1")
source(file.path(script_directory, "run.R"))
source(file.path(script_directory, "aoi_conversion.R"))

parser <- ArgumentParser(
  description = "Convert a local-XY Audit GeoJSON to a validated GeoPackage"
)
parser$add_argument("--point-cloud", required = TRUE)
parser$add_argument("--aoi-geojson", required = TRUE)
parser$add_argument("--output-gpkg", required = TRUE)
parser$add_argument("--provenance-json", default = NULL)
arguments <- parser$parse_args()

provenance <- convert_geojson_to_gpkg(
  arguments$aoi_geojson,
  arguments$output_gpkg,
  point_cloud_xy_bounds(arguments$point_cloud),
  tile_threads = 1L
)
if (!is.null(arguments$provenance_json)) {
  jsonlite::write_json(
    provenance,
    arguments$provenance_json,
    auto_unbox = TRUE,
    pretty = TRUE
  )
}
cat(jsonlite::toJSON(provenance, auto_unbox = TRUE), "\n")
