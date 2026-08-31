suppressPackageStartupMessages(library(sf))

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2L) {
  stop("usage: create_dataset150_canonical_geojson.R AUTHORITATIVE_GPKG OUTPUT_GEOJSON")
}
source_path <- arguments[[1]]
output_path <- arguments[[2]]
expected_sha256 <- "cc7befe0c55ce5e09c66c4eda062cbc947937ea005e7cc80161a028685f5c643"
actual_sha256 <- sub(
  "[[:space:]].*$",
  "",
  system2("sha256sum", source_path, stdout = TRUE)[[1]]
)
if (!identical(actual_sha256, expected_sha256)) {
  stop("authoritative dataset-150 80.gpkg SHA-256 differs")
}

layers <- st_layers(source_path)$name
if (length(layers) != 1L) {
  stop("authoritative dataset-150 GeoPackage must contain exactly one layer")
}
authoritative <- st_read(
  source_path,
  layer = layers[[1]],
  quiet = TRUE,
  stringsAsFactors = FALSE
)
st_crs(authoritative) <- NA
authoritative <- st_make_valid(st_zm(authoritative, drop = TRUE, what = "ZM"))
authoritative_geometry <- st_union(st_geometry(authoritative))

temporary <- tempfile(
  pattern = ".80_canonical_",
  tmpdir = dirname(output_path),
  fileext = ".geojson"
)
on.exit(unlink(temporary, force = TRUE), add = TRUE)
st_write(
    st_sf(role = "include", geometry = authoritative_geometry),
    temporary,
    driver = "GeoJSON",
    layer_options = "COORDINATE_PRECISION=17",
  delete_dsn = TRUE,
  quiet = TRUE
)
canonical <- st_read(temporary, quiet = TRUE, stringsAsFactors = FALSE)
st_crs(canonical) <- NA
canonical_geometry <- st_union(st_geometry(st_make_valid(canonical)))
relation <- st_equals_exact(
  authoritative_geometry,
  canonical_geometry,
  par = 0,
  sparse = FALSE
)
if (!isTRUE(relation[[1, 1]]) ||
    !identical(
      unname(as.numeric(st_bbox(authoritative_geometry))),
      unname(as.numeric(st_bbox(canonical_geometry)))
    ) ||
    !identical(
      unname(sum(as.numeric(st_area(authoritative_geometry)))),
      unname(sum(as.numeric(st_area(canonical_geometry))))
    )) {
  stop("canonical GeoJSON changed authoritative dataset-150 geometry")
}
unlink(output_path, force = TRUE)
if (!file.rename(temporary, output_path)) {
  stop("cannot atomically promote canonical dataset-150 GeoJSON")
}
cat(output_path, "\n")
