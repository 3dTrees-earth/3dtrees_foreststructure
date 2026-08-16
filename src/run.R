suppressPackageStartupMessages({
  library(argparse)
  library(data.table)
  library(future)
  library(lidR)
  library(sf)
  library(terra)
})

# Runtime invariants chosen for the validated production image. Catalog
# workers use one lidR thread; segment aggregation uses a small, fixed
# data.table pool and deterministic disk buckets to bound peak memory.
DATA_TABLE_THREADS <- 5L
SEGMENT_BUCKET_COUNT <- 64L
MAX_LIDR_POINT_COUNT <- .Machine$integer.max
DTM_CATALOG_SELECTION <- "xyz"
SEGMENT_CATALOG_BASE_SELECTION <- "xyzrn"

configure_catalog_worker <- function() {
  lidR::set_lidr_threads(1L)
  data.table::setDTthreads(DATA_TABLE_THREADS)
  invisible(NULL)
}

read_las_uint_le <- function(connection, bytes) {
  raw_value <- readBin(connection, what = "raw", n = bytes)
  if (length(raw_value) != bytes) stop("LAS/LAZ header is truncated")
  sum(as.numeric(raw_value) * 256^(seq_len(bytes) - 1L))
}

point_count_from_las_header <- function(path) {
  connection <- file(path, open = "rb")
  on.exit(close(connection), add = TRUE)
  signature <- rawToChar(readBin(connection, what = "raw", n = 4L))
  if (!identical(signature, "LASF")) {
    stop("point cloud does not have a LAS/LAZ header")
  }

  seek(connection, where = 24L, origin = "start")
  version <- as.integer(readBin(connection, what = "raw", n = 2L))
  if (length(version) != 2L) stop("LAS/LAZ header is truncated")

  seek(connection, where = 107L, origin = "start")
  legacy_count <- read_las_uint_le(connection, 4L)
  is_las_14 <- version[[1]] > 1L ||
    (version[[1]] == 1L && version[[2]] >= 4L)
  if (!is_las_14) return(legacy_count)

  seek(connection, where = 247L, origin = "start")
  extended_count <- read_las_uint_le(connection, 8L)
  if (extended_count > 0) extended_count else legacy_count
}

assert_lidr_point_count_supported <- function(point_count) {
  if (!is.finite(point_count) || point_count < 0) {
    stop("LAS/LAZ header contains an invalid point count")
  }
  if (point_count > MAX_LIDR_POINT_COUNT) {
    stop(sprintf(
      paste(
        "FORESTSTRUCTURE_FLAG unsupported_lidr_point_count:",
        "single point-cloud file contains %.0f points; lidR/R supports at most %.0f"
      ),
      point_count,
      MAX_LIDR_POINT_COUNT
    ))
  }
  invisible(point_count)
}

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
source(file.path(script_directory, "tile_scheduler.R"))

# CLI and artifact naming ---------------------------------------------------

parse_parameters <- function() {
  parser <- ArgumentParser(
    description = "Compute forest-structure indices for optimized Analysis Tiles"
  )
  inputs <- parser$add_argument_group("Inputs")
  scientific <- parser$add_argument_group("Scientific parameters")
  runtime <- parser$add_argument_group("Runtime controls")
  segments <- parser$add_argument_group("Optional segment controls")

  inputs$add_argument(
    "--point-cloud", "--point_cloud",
    required = TRUE,
    help = "Path to exactly one LAS or LAZ point cloud"
  )
  inputs$add_argument(
    "--dataset-id", "--dataset_id",
    required = TRUE,
    type = "integer",
    help = "Positive 3Dtrees dataset identifier used to prefix every output"
  )
  inputs$add_argument(
    "--aoi",
    required = FALSE,
    default = NULL,
    help = paste(
      "Optional GeoJSON or GeoPackage Audit AOI; when omitted, tiles cover",
      "the complete point-cloud XY extent"
    )
  )
  inputs$add_argument(
    "--output-dir", "--output_dir",
    required = TRUE,
    help = "Existing writable output directory"
  )
  scientific$add_argument(
    "--tile-size", "--tile_size",
    type = "double",
    default = 20,
    help = "Fixed Analysis Tile width in metres (default: 20)"
  )
  scientific$add_argument(
    "--grid-search-step", "--grid_search_step",
    type = "double",
    default = 0.5,
    help = "Offset-search resolution in metres; placement is always optimized (default: 0.5)"
  )
  scientific$add_argument(
    "--ptd-resolution", "--ptd_resolution",
    type = "double",
    default = 20,
    help = "PTD seed resolution in metres (default: 20)"
  )
  scientific$add_argument(
    "--dtm-resolution", "--dtm_resolution",
    type = "double",
    default = 1,
    help = "Global DTM resolution in metres (default: 1)"
  )
  scientific$add_argument(
    "--maximum-height", "--maximum_height",
    type = "double",
    default = 70,
    help = "Maximum normalized height retained in metres (default: 70)"
  )
  scientific$add_argument(
    "--voxel-resolution", "--voxel_resolution",
    type = "double",
    default = 0.2,
    help = "Voxel edge length in metres (default: 0.2)"
  )
  scientific$add_argument(
    "--vegetation-minimum-height", "--vegetation_minimum_height",
    type = "double",
    default = 0.5,
    help = "Minimum vegetation height in metres (default: 0.5)"
  )
  scientific$add_argument(
    "--chm-resolution", "--chm_resolution",
    type = "double",
    default = 0.5,
    help = "Full-point-cloud CHM resolution in metres (default: 0.5)"
  )
  scientific$add_argument(
    "--gap-height-threshold", "--gap_height_threshold",
    type = "double",
    default = 3,
    help = "CHM gap-height threshold in metres (default: 3)"
  )
  runtime$add_argument(
    "--dtm-chunk-size", "--dtm_chunk_size",
    type = "double",
    default = 60,
    help = "LAScatalog DTM chunk width in metres (default: 60)"
  )
  runtime$add_argument(
    "--chunk-size", "--chunk_size",
    type = "double",
    default = 60,
    help = "LAScatalog global-segment chunk width in metres (default: 60)"
  )
  runtime$add_argument(
    "--dtm-buffer", "--dtm_buffer",
    type = "double",
    default = 20,
    help = "DTM chunk buffer in metres (default: 20)"
  )
  runtime$add_argument(
    "--threads",
    type = "integer",
    default = 0,
    help = "lidR thread count; 0 preserves the package/container default (default: 0)"
  )
  runtime$add_argument(
    "--catalog-workers", "--catalog_workers",
    type = "integer",
    default = 2,
    help = paste(
      "Maximum concurrent LAScatalog processes; kept separate from the lidR",
      "thread allowance to bound memory (default: 2)"
    )
  )
  runtime$add_argument(
    "--performance-report", "--performance_report",
    action = "store_true",
    default = FALSE,
    help = "Write the dataset-prefixed performance CSV with timings and peak RSS"
  )
  segments$add_argument(
    "--instance-dimension", "--instance_dimension",
    action = "append",
    default = NULL,
    help = paste(
      "Instance-ID dimensions to process; repeat the option or provide",
      "comma-separated names. Missing dimensions are skipped. Defaults to",
      "PredInstance, PredInstance_SAT, PredInstance_FM"
    )
  )
  segments$add_argument(
    "--segment-diagnostics", "--segment_diagnostics",
    action = "store_true",
    default = FALSE,
    help = "Deprecated compatibility flag; segment diagnostics are always written"
  )
  segments$add_argument(
    "--minimum-tree-voxels", "--minimum_tree_voxels",
    type = "integer",
    default = 100,
    help = "Minimum occupied voxels for an accepted tree (default: 100)"
  )
  segments$add_argument(
    "--apex-minimum-height", "--apex_minimum_height",
    type = "double",
    default = 3,
    help = "Strict minimum tree-apex height in metres (default: 3)"
  )
  segments$add_argument(
    "--minimum-tree-thickness", "--minimum_tree_thickness",
    type = "double",
    default = 0.5,
    help = "Minimum smallest PCA extent in metres (default: 0.5)"
  )
  segments$add_argument(
    "--minimum-occupied-layers", "--minimum_occupied_layers",
    type = "integer",
    default = 3,
    help = "Minimum occupied one-metre height layers (default: 3)"
  )
  args <- parser$parse_args()

  raw_instance_dimensions <- unlist(
    args$instance_dimension,
    recursive = TRUE,
    use.names = FALSE
  )
  if (is.null(raw_instance_dimensions) || length(raw_instance_dimensions) == 0 ||
      all(is.na(raw_instance_dimensions))) {
    args$instance_dimension <- c(
      "PredInstance", "PredInstance_SAT", "PredInstance_FM"
    )
  } else {
    candidates <- trimws(unlist(strsplit(
      as.character(raw_instance_dimensions),
      ",",
      fixed = TRUE
    )))
    args$instance_dimension <- unique(candidates[!is.na(candidates) & nzchar(candidates)])
    if (length(args$instance_dimension) == 0) {
      stop("--instance-dimension must contain at least one non-empty name")
    }
  }

  if (!file.exists(args$point_cloud) || dir.exists(args$point_cloud)) {
    stop("--point-cloud must be exactly one existing LAS/LAZ file")
  }
  if (!is.finite(args$dataset_id) || args$dataset_id < 1) {
    stop("--dataset-id must be a positive integer")
  }
  if (!grepl("\\.la[sz]$", args$point_cloud, ignore.case = TRUE)) {
    stop("--point-cloud must have a .las or .laz extension")
  }
  if (!is.null(args$aoi)) {
    if (!file.exists(args$aoi) || dir.exists(args$aoi)) {
      stop("--aoi must be exactly one existing GeoJSON or GeoPackage file")
    }
    if (!grepl("\\.(geojson|json|gpkg)$", args$aoi, ignore.case = TRUE)) {
      stop("--aoi must have a .geojson, .json, or .gpkg extension")
    }
  }
  if (!dir.exists(args$output_dir)) {
    stop("--output-dir must be an existing directory")
  }
  if (file.access(args$output_dir, mode = 2) != 0) {
    stop("--output-dir must be writable")
  }

  positive <- c(
    "tile_size", "grid_search_step", "ptd_resolution", "dtm_resolution",
    "maximum_height", "voxel_resolution", "chm_resolution", "dtm_chunk_size",
    "chunk_size", "dtm_buffer"
  )
  for (name in positive) {
    if (!is.finite(args[[name]]) || args[[name]] <= 0) {
      stop(sprintf("--%s must be greater than zero", gsub("_", "-", name)))
    }
  }
  if (args$grid_search_step > args$tile_size) {
    stop("--grid-search-step must not exceed --tile-size")
  }
  if (!is.finite(args$vegetation_minimum_height) || args$vegetation_minimum_height < 0) {
    stop("--vegetation-minimum-height must be zero or greater")
  }
  if (!is.finite(args$gap_height_threshold) || args$gap_height_threshold < 0) {
    stop("--gap-height-threshold must be zero or greater")
  }
  if (!is.finite(args$minimum_tree_voxels) || args$minimum_tree_voxels < 1) {
    stop("--minimum-tree-voxels must be at least one")
  }
  if (!is.finite(args$apex_minimum_height) || args$apex_minimum_height < 0) {
    stop("--apex-minimum-height must be zero or greater")
  }
  if (!is.finite(args$minimum_tree_thickness) || args$minimum_tree_thickness < 0) {
    stop("--minimum-tree-thickness must be zero or greater")
  }
  if (!is.finite(args$minimum_occupied_layers) || args$minimum_occupied_layers < 1) {
    stop("--minimum-occupied-layers must be at least one")
  }
  if (!is.finite(args$threads) || args$threads < 0) {
    stop("--threads must be zero or greater")
  }
  if (!is.finite(args$catalog_workers) || args$catalog_workers < 1) {
    stop("--catalog-workers must be at least one")
  }
  args
}

artifact_paths <- function(output_dir, dataset_id) {
  prefix <- file.path(output_dir, as.character(dataset_id))
  list(
    prefix = prefix,
    dtm = paste0(prefix, "_dtm.tif"),
    chm = paste0(prefix, "_chm.tif"),
    tiles_png = paste0(prefix, "_tiles.png"),
    performance = paste0(prefix, "_performance.csv")
  )
}

dimension_artifact_paths <- function(paths, instance_dimension = NULL) {
  suffix <- if (is.null(instance_dimension)) {
    ""
  } else {
    safe <- gsub("[^A-Za-z0-9_-]", "_", instance_dimension)
    if (!nzchar(safe)) stop("Instance Dimension cannot form a safe artifact name")
    paste0("_", safe)
  }
  list(
    results = paste0(paths$prefix, suffix, "_results.csv"),
    segment_diagnostics = paste0(
      paths$prefix, suffix, "_segment_diagnostics.csv"
    ),
    tiles_geojson = paste0(paths$prefix, suffix, "_tiles.geojson")
  )
}

# Audit footprint and deterministic tile grid ------------------------------

normalize_aoi_geometry <- function(features, label, allow_empty = FALSE) {
  if (is.null(features) || nrow(features) == 0) {
    if (allow_empty) return(st_sfc(crs = NA_crs_))
    stop(sprintf("Audit AOI contains no %s geometry", label))
  }
  geometry_types <- unique(as.character(st_geometry_type(features, by_geometry = TRUE)))
  if (!all(geometry_types %in% c("POLYGON", "MULTIPOLYGON"))) {
    stop(sprintf("Audit AOI %s must contain only Polygon or MultiPolygon geometry", label))
  }

  # Audit AOIs are already expressed in the point cloud's local XY space.
  # GeoJSON readers may infer WGS84 from the container format; that metadata is
  # not authoritative for the local audit handoff and must not trigger a transform.
  st_crs(features) <- NA
  features <- st_make_valid(features)
  geometry <- st_union(st_geometry(features))
  if (length(geometry) == 0 || any(st_is_empty(geometry))) {
    if (allow_empty) return(st_sfc(crs = NA_crs_))
    stop(sprintf("Audit AOI %s is empty after geometry validation", label))
  }
  geometry
}

read_geojson_aoi <- function(path) {
  features <- st_read(path, quiet = TRUE, stringsAsFactors = FALSE)
  if (nrow(features) == 0) stop("Audit AOI contains no geometry")
  if (!"role" %in% names(features)) {
    return(list(inclusion = features, exclusion = NULL))
  }

  roles <- tolower(trimws(as.character(features$role)))
  aliases <- c(
    include = "include",
    inclusion = "include",
    exclude = "exclude",
    exclusion = "exclude"
  )
  unknown <- unique(roles[!roles %in% names(aliases)])
  if (length(unknown) > 0) {
    stop(sprintf("Audit AOI contains unsupported feature role(s): %s", paste(unknown, collapse = ", ")))
  }
  roles <- unname(aliases[roles])
  list(
    inclusion = features[roles == "include", , drop = FALSE],
    exclusion = features[roles == "exclude", , drop = FALSE]
  )
}

read_geopackage_aoi <- function(path) {
  layers <- st_layers(path)$name
  if (!"include" %in% layers) {
    stop("GeoPackage Audit AOI must contain an 'include' layer")
  }
  list(
    inclusion = st_read(path, layer = "include", quiet = TRUE, stringsAsFactors = FALSE),
    exclusion = if ("exclude" %in% layers) {
      st_read(path, layer = "exclude", quiet = TRUE, stringsAsFactors = FALSE)
    } else {
      NULL
    }
  )
}

read_audit_aoi <- function(path) {
  raw <- if (grepl("\\.gpkg$", path, ignore.case = TRUE)) {
    read_geopackage_aoi(path)
  } else {
    read_geojson_aoi(path)
  }
  inclusion <- normalize_aoi_geometry(raw$inclusion, "inclusion")
  exclusion <- normalize_aoi_geometry(raw$exclusion, "exclusion", allow_empty = TRUE)
  usable <- if (length(exclusion) > 0) {
    st_difference(inclusion, exclusion)
  } else {
    inclusion
  }
  if (length(usable) == 0 || all(st_is_empty(usable))) {
    stop("Audit AOI exclusions remove the complete inclusion geometry")
  }
  list(
    inclusion = inclusion,
    exclusion = exclusion,
    usable = usable,
    source = "audit_aoi"
  )
}

point_cloud_xy_bounds <- function(path) {
  header <- readLASheader(path)
  bounds <- c(
    xmin = as.numeric(header@PHB[["Min X"]]),
    ymin = as.numeric(header@PHB[["Min Y"]]),
    xmax = as.numeric(header@PHB[["Max X"]]),
    ymax = as.numeric(header@PHB[["Max Y"]])
  )
  if (any(!is.finite(bounds)) ||
      bounds[["xmax"]] <= bounds[["xmin"]] ||
      bounds[["ymax"]] <= bounds[["ymin"]]) {
    stop("point-cloud header does not contain a usable two-dimensional XY extent")
  }
  bounds
}

read_point_cloud_extent <- function(path) {
  bounds <- point_cloud_xy_bounds(path)
  ring <- matrix(c(
    bounds[["xmin"]], bounds[["ymin"]],
    bounds[["xmax"]], bounds[["ymin"]],
    bounds[["xmax"]], bounds[["ymax"]],
    bounds[["xmin"]], bounds[["ymax"]],
    bounds[["xmin"]], bounds[["ymin"]]
  ), ncol = 2, byrow = TRUE)
  extent <- st_sfc(st_polygon(list(ring)), crs = NA_crs_)
  list(
    inclusion = extent,
    exclusion = st_sfc(crs = NA_crs_),
    usable = extent,
    source = "point_cloud_extent"
  )
}

read_analysis_footprint <- function(point_cloud, aoi = NULL) {
  if (is.null(aoi)) return(read_point_cloud_extent(point_cloud))
  audit <- read_audit_aoi(aoi)
  point_cloud_extent <- read_point_cloud_extent(point_cloud)
  overlap <- suppressWarnings(st_intersection(
    audit$usable,
    point_cloud_extent$usable
  ))
  overlap_area <- if (length(overlap) == 0L) 0 else sum(as.numeric(st_area(overlap)))
  if (!is.finite(overlap_area) || overlap_area <= 0) {
    stop(
      "Audit AOI does not overlap the point-cloud XY extent; ",
      "both inputs must use the same local coordinate frame"
    )
  }
  audit
}

make_grid_at <- function(geometry, tile_size, offset_x, offset_y,
                         reference_bounds = st_bbox(geometry)) {
  st_make_grid(
    geometry,
    cellsize = tile_size,
    offset = c(
      reference_bounds[["xmin"]] - offset_x,
      reference_bounds[["ymin"]] - offset_y
    )
  )
}

count_complete_tiles <- function(grid, geometry) {
  sum(lengths(st_within(grid, geometry)) > 0)
}

build_optimized_tiles <- function(geometry, tile_size, search_step, threads = 1L) {
  offsets <- seq(0, tile_size - search_step, by = search_step)
  reference_bounds <- st_bbox(geometry)
  components <- st_cast(geometry, "POLYGON", warn = FALSE)
  candidates <- data.frame(
    offset_x = rep(offsets, each = length(offsets)),
    offset_y = rep(offsets, times = length(offsets))
  )
  maximum_possible_tiles <- floor(
    as.numeric(st_area(geometry)) / tile_size^2
  )
  count_candidate <- function(index) {
    sum(vapply(seq_along(components), function(component_index) {
      component <- components[component_index]
      count_complete_tiles(
        make_grid_at(
          component,
          tile_size,
          candidates$offset_x[[index]],
          candidates$offset_y[[index]],
          reference_bounds
        ),
        component
      )
    }, integer(1)))
  }

  first_count <- count_candidate(1L)
  if (first_count >= maximum_possible_tiles || nrow(candidates) == 1L) {
    best_index <- 1L
  } else {
    remaining <- seq.int(2L, nrow(candidates))
    workers <- min(max(1L, as.integer(threads)), length(remaining))
    message(sprintf(
      "Optimizing %d remaining grid offsets with %d worker(s)",
      length(remaining),
      workers
    ))
    remaining_counts <- if (workers == 1L) {
      vapply(remaining, count_candidate, integer(1))
    } else {
      unlist(
        parallel::mclapply(
          remaining,
          count_candidate,
          mc.cores = workers,
          mc.preschedule = TRUE,
          mc.set.seed = FALSE
        ),
        use.names = FALSE
      )
    }
    counts <- c(first_count, remaining_counts)
    best_index <- which.max(counts)
  }

  best_x <- candidates$offset_x[[best_index]]
  best_y <- candidates$offset_y[[best_index]]
  grid <- make_grid_at(geometry, tile_size, best_x, best_y)
  complete <- lengths(st_within(grid, geometry)) > 0
  if (!any(complete)) {
    return(st_sf(
      tile_id = integer(),
      geometry = st_sfc(crs = st_crs(geometry))
    ))
  }

  tiles <- st_sf(geometry = grid[complete])
  bounds <- t(vapply(seq_len(nrow(tiles)), function(index) {
    as.numeric(st_bbox(tiles[index, ]))
  }, numeric(4)))
  order_index <- order(bounds[, 2], bounds[, 1])
  tiles <- tiles[order_index, , drop = FALSE]
  tiles$tile_id <- seq_len(nrow(tiles))
  tiles[, c("tile_id", "geometry")]
}

build_covering_tiles <- function(geometry, tile_size) {
  bounds <- st_bbox(geometry)
  span_x <- as.numeric(bounds[["xmax"]] - bounds[["xmin"]])
  span_y <- as.numeric(bounds[["ymax"]] - bounds[["ymin"]])
  columns <- as.integer(ceiling(span_x / tile_size))
  rows <- as.integer(ceiling(span_y / tile_size))
  covered_width <- columns * tile_size
  covered_height <- rows * tile_size
  origin_x <- as.numeric(bounds[["xmin"]] - (covered_width - span_x) / 2)
  origin_y <- as.numeric(bounds[["ymin"]] - (covered_height - span_y) / 2)

  polygons <- vector("list", columns * rows)
  index <- 1L
  for (row in seq_len(rows)) {
    ymin <- origin_y + (row - 1) * tile_size
    ymax <- ymin + tile_size
    for (column in seq_len(columns)) {
      xmin <- origin_x + (column - 1) * tile_size
      xmax <- xmin + tile_size
      ring <- matrix(c(
        xmin, ymin,
        xmax, ymin,
        xmax, ymax,
        xmin, ymax,
        xmin, ymin
      ), ncol = 2, byrow = TRUE)
      polygons[[index]] <- st_polygon(list(ring))
      index <- index + 1L
    }
  }
  st_sf(
    tile_id = seq_along(polygons),
    geometry = st_sfc(polygons, crs = st_crs(geometry))
  )
}

build_analysis_tiles <- function(footprint, tile_size, search_step, threads = 1L) {
  if (identical(footprint$source, "point_cloud_extent")) {
    return(build_covering_tiles(footprint$usable, tile_size))
  }
  build_optimized_tiles(footprint$usable, tile_size, search_step, threads)
}

compute_edge_flags <- function(tiles, tile_size) {
  if (nrow(tiles) == 0) return(logical())
  centroids <- st_coordinates(st_centroid(st_geometry(tiles)))
  index_x <- as.integer(round(centroids[, 1] / tile_size))
  index_y <- as.integer(round(centroids[, 2] / tile_size))
  keys <- paste(index_x, index_y, sep = "_")

  vapply(seq_len(nrow(tiles)), function(index) {
    neighbours <- expand.grid(dx = -1:1, dy = -1:1)
    neighbours <- neighbours[neighbours$dx != 0 | neighbours$dy != 0, ]
    neighbour_keys <- paste(
      index_x[[index]] + neighbours$dx,
      index_y[[index]] + neighbours$dy,
      sep = "_"
    )
    !all(neighbour_keys %in% keys)
  }, logical(1))
}

# Disk-backed DTM and CHM pipeline -----------------------------------------

dtm_chunk <- function(chunk, dtm_resolution, ptd_resolution) {
  lidR::set_lidr_threads(1L)
  las <- readLAS(chunk)
  if (is.empty(las)) return(empty_chunk_raster(chunk, dtm_resolution))
  if (!las_has_nondegenerate_xy(las)) {
    message(
      "DTM chunk has fewer than three non-collinear input points; ",
      "leaving it empty for buffered neighbouring chunks"
    )
    return(empty_chunk_raster(chunk, dtm_resolution))
  }
  las <- classify_ground(las, ptd(res = ptd_resolution))
  surface <- classified_ground_surface(las, dtm_resolution)
  if (is.null(surface)) empty_chunk_raster(chunk, dtm_resolution) else surface
}

las_has_nondegenerate_xy <- function(las) {
  xy <- unique(as.data.table(las@data)[, .(X, Y)])
  if (nrow(xy) < 3L) return(FALSE)
  qr(scale(as.matrix(xy), center = TRUE, scale = FALSE))$rank >= 2L
}

chunk_has_valid_extent <- function(chunk) {
  chunk_bounds <- st_bbox(chunk)
  all(is.finite(chunk_bounds)) &&
    chunk_bounds[["xmax"]] > chunk_bounds[["xmin"]] &&
    chunk_bounds[["ymax"]] > chunk_bounds[["ymin"]]
}

ensure_nonempty_grid_bounds <- function(bounds, resolution) {
  if (bounds[["xmax"]] <= bounds[["xmin"]]) {
    bounds[["xmax"]] <- bounds[["xmin"]] + resolution
  }
  if (bounds[["ymax"]] <= bounds[["ymin"]]) {
    bounds[["ymax"]] <- bounds[["ymin"]] + resolution
  }
  bounds
}

empty_chunk_raster <- function(chunk, resolution) {
  if (!chunk_has_valid_extent(chunk)) return(NULL)
  chunk_bounds <- st_bbox(chunk)
  bounds <- ensure_nonempty_grid_bounds(
    covering_grid_bounds(chunk_bounds, resolution),
    resolution
  )
  raster <- terra::rast(
    xmin = bounds[["xmin"]],
    xmax = bounds[["xmax"]],
    ymin = bounds[["ymin"]],
    ymax = bounds[["ymax"]],
    resolution = resolution
  )
  terra::values(raster) <- NA_real_
  raster
}

classified_ground_surface <- function(las, dtm_resolution) {
  classifications <- las[["Classification"]]
  if (is.null(classifications) || !any(classifications == 2L, na.rm = TRUE)) {
    message(
      "DTM chunk contains no PTD ground points; leaving it empty for ",
      "buffered neighbouring chunks"
    )
    return(NULL)
  }
  ground_xy <- unique(
    as.data.table(las@data)[Classification == 2L, .(X, Y)]
  )
  ground_rank <- if (nrow(ground_xy) < 3L) {
    0L
  } else {
    qr(scale(as.matrix(ground_xy), center = TRUE, scale = FALSE))$rank
  }
  if (nrow(ground_xy) < 3L || ground_rank < 2L) {
    message(
      "DTM chunk has fewer than three non-collinear PTD ground points; ",
      "leaving it empty for buffered neighbouring chunks"
    )
    return(NULL)
  }
  tryCatch(
    rasterize_terrain(las, res = dtm_resolution, algorithm = tin()),
    error = function(error) {
      if (grepl(
        paste0(
          "cannot triangulate less than 3 points|No ground points found|",
          "Invalid grid dimensions"
        ),
        conditionMessage(error),
        ignore.case = TRUE
      )) {
        message(
          "DTM chunk has insufficient ground geometry for TIN; ",
          "leaving it empty for buffered neighbouring chunks"
        )
        return(NULL)
      }
      stop(error)
    }
  )
}

assert_catalog_completed <- function(results, phase) {
  if (length(results) == 0L || any(vapply(results, is.null, logical(1)))) {
    stop(sprintf(
      "%s LAScatalog processing failed or returned incomplete chunks",
      phase
    ))
  }
  invisible(results)
}

with_catalog_workers <- function(workers, phase, expression) {
  workers <- max(1L, as.integer(workers))
  previous_lidr_threads <- lidR::get_lidr_threads()
  on.exit(
    lidR::set_lidr_threads(previous_lidr_threads),
    add = TRUE
  )
  message(sprintf(
    "Processing %s LAScatalog chunks with %d worker(s)",
    phase,
    workers
  ))
  if (workers == 1L) return(force(expression))

  previous_plan <- future::plan()
  on.exit(future::plan(previous_plan), add = TRUE)
  future::plan(future::multisession, workers = workers)
  force(expression)
}

prepare_raster_work_directory <- function(path, label) {
  if (dir.exists(path)) unlink(path, recursive = TRUE, force = TRUE)
  if (!dir.create(path, recursive = TRUE, showWarnings = FALSE)) {
    stop(sprintf("could not create temporary %s chunk directory", label))
  }
  invisible(path)
}

virtual_raster_source <- function(result, label) {
  if (!inherits(result, "SpatRaster") || terra::inMemory(result)) {
    stop(sprintf(
      "global %s processing did not produce a disk-backed raster mosaic",
      label
    ))
  }
  sources <- terra::sources(result)
  if (length(sources) != 1L ||
      !grepl("\\.vrt$", sources[[1]], ignore.case = TRUE)) {
    stop(sprintf(
      "global %s processing did not produce one virtual raster mosaic",
      label
    ))
  }
  sources[[1]]
}

complete_chunk_raster_paths <- function(results, label) {
  assert_catalog_completed(results, label)
  paths <- unname(unlist(results, use.names = FALSE))
  if (length(paths) == 0L || any(!file.exists(paths))) {
    stop(sprintf(
      "%s LAScatalog processing did not write every chunk raster",
      label
    ))
  }

  paths
}

populated_or_all_empty_chunk_raster_paths <- function(paths, label) {
  has_data <- vapply(paths, function(path) {
    count <- suppressWarnings(terra::global(terra::rast(path), "notNA"))
    is.finite(count[[1L, 1L]]) && count[[1L, 1L]] > 0
  }, logical(1))
  if (any(has_data)) {
    return(paths[has_data])
  }

  message(sprintf(
    "global %s processing produced only empty chunks; publishing an all-NoData raster",
    label
  ))
  paths
}

chunk_reference_crs <- function(paths, label) {
  candidates <- vapply(paths, function(path) {
    terra::crs(terra::rast(path))
  }, character(1))
  candidates <- unique(candidates[!is.na(candidates) & nzchar(candidates)])
  if (length(candidates) > 1L) {
    stop(sprintf("%s chunk rasters contain conflicting CRS metadata", label))
  }
  if (length(candidates) == 1L) candidates[[1L]] else NA_character_
}

spatial_reference_wkt <- function(value) {
  reference <- sf::st_crs(value)
  if (is.na(reference) || is.null(reference$wkt) ||
      is.na(reference$wkt) || !nzchar(reference$wkt)) {
    return(NA_character_)
  }
  reference$wkt
}

build_chunk_virtual_raster <- function(results, work_directory, label,
                                       fallback_crs = NA_character_) {
  all_paths <- complete_chunk_raster_paths(results, label)
  reference_crs <- chunk_reference_crs(all_paths, label)
  if ((is.na(reference_crs) || !nzchar(reference_crs)) &&
      !is.na(fallback_crs) && nzchar(fallback_crs)) {
    reference_crs <- fallback_crs
  }
  paths <- populated_or_all_empty_chunk_raster_paths(all_paths, label)
  vrt_path <- file.path(
    work_directory,
    sprintf("%s_chunks.vrt", tolower(label))
  )
  input_list_path <- file.path(
    work_directory,
    sprintf("%s_chunks.txt", tolower(label))
  )
  unlink(vrt_path, force = TRUE)
  writeLines(paths, input_list_path, useBytes = TRUE)
  arguments <- c("-overwrite")
  if (!is.na(reference_crs) && nzchar(reference_crs)) {
    arguments <- c(arguments, "-a_srs", shQuote(reference_crs))
  }
  arguments <- c(
    arguments,
    "-input_file_list", shQuote(input_list_path),
    shQuote(vrt_path)
  )
  status <- system2("gdalbuildvrt", arguments)
  if (!identical(status, 0L) || !file.exists(vrt_path)) {
    stop(sprintf("could not build the global %s chunk VRT", label))
  }
  result <- terra::rast(vrt_path)
  if (!is.na(reference_crs) && nzchar(reference_crs)) {
    actual_crs <- terra::crs(result)
    if (is.na(actual_crs) || !nzchar(actual_crs)) {
      stop(sprintf(
        "global %s chunk VRT did not persist its reference CRS",
        label
      ))
    }
  }
  result
}

stream_virtual_raster <- function(result, output_path, label) {
  source_path <- virtual_raster_source(result, label)
  partial_path <- paste0(output_path, ".partial.tif")
  unlink(partial_path, force = TRUE)
  on.exit(unlink(partial_path, force = TRUE), add = TRUE)
  status <- system2(
    "gdal_translate",
    c(
      "-of", "GTiff",
      "-co", "TILED=YES",
      "-co", "COMPRESS=LZW",
      "-co", "BIGTIFF=IF_SAFER",
      shQuote(source_path),
      shQuote(partial_path)
    )
  )
  if (!identical(status, 0L) || !file.exists(partial_path)) {
    stop(sprintf(
      "could not stream the global %s virtual mosaic to GeoTIFF",
      label
    ))
  }
  if (!file.rename(partial_path, output_path)) {
    stop(sprintf("could not atomically publish the global %s GeoTIFF", label))
  }
  invisible(output_path)
}

align_grid_coordinate <- function(value, resolution, direction) {
  scaled <- value / resolution
  nearest <- round(scaled)
  if (abs(scaled - nearest) < 1e-9) scaled <- nearest
  if (identical(direction, "lower")) {
    floor(scaled) * resolution
  } else {
    ceiling(scaled) * resolution
  }
}

covering_grid_bounds <- function(bounds, resolution) {
  c(
    xmin = align_grid_coordinate(bounds[["xmin"]], resolution, "lower"),
    ymin = align_grid_coordinate(bounds[["ymin"]], resolution, "lower"),
    xmax = align_grid_coordinate(bounds[["xmax"]], resolution, "upper"),
    ymax = align_grid_coordinate(bounds[["ymax"]], resolution, "upper")
  )
}

raster_extent_covers_point_bounds <- function(raster_extent, point_bounds,
                                               resolution) {
  extent_values <- c(
    xmin = as.numeric(raster_extent$xmin),
    ymin = as.numeric(raster_extent$ymin),
    xmax = as.numeric(raster_extent$xmax),
    ymax = as.numeric(raster_extent$ymax)
  )
  coordinate_scale <- max(abs(c(extent_values, point_bounds)), 1)
  tolerance <- max(
    resolution * 1e-9,
    .Machine$double.eps * coordinate_scale * 16
  )
  extent_values[["xmin"]] <= point_bounds[["xmin"]] + tolerance &&
    extent_values[["xmax"]] >= point_bounds[["xmax"]] - tolerance &&
    extent_values[["ymin"]] <= point_bounds[["ymin"]] + tolerance &&
    extent_values[["ymax"]] >= point_bounds[["ymax"]] - tolerance
}

cover_virtual_raster <- function(result, point_cloud, resolution,
                                 work_directory, label) {
  source_path <- virtual_raster_source(result, label)
  point_bounds <- point_cloud_xy_bounds(point_cloud)
  target_bounds <- covering_grid_bounds(point_bounds, resolution)
  covering_path <- file.path(
    work_directory,
    sprintf("%s_covering.vrt", tolower(label))
  )
  number <- function(value) {
    format(value, scientific = FALSE, trim = TRUE, digits = 15)
  }
  status <- system2(
    "gdalbuildvrt",
    c(
      "-overwrite",
      "-resolution", "user",
      "-tr", number(resolution), number(resolution),
      "-te",
      number(target_bounds[["xmin"]]),
      number(target_bounds[["ymin"]]),
      number(target_bounds[["xmax"]]),
      number(target_bounds[["ymax"]]),
      "-vrtnodata", "-999999",
      shQuote(covering_path),
      shQuote(source_path)
    )
  )
  if (!identical(status, 0L) || !file.exists(covering_path)) {
    stop(sprintf(
      "could not create the point-cloud-covering global %s VRT",
      label
    ))
  }
  covering <- terra::rast(covering_path)
  if (terra::inMemory(covering)) {
    stop(sprintf("global %s covering VRT materialized in memory", label))
  }
  covering_extent <- terra::ext(covering)
  if (!raster_extent_covers_point_bounds(
    covering_extent,
    point_bounds,
    resolution
  )) {
    stop(sprintf(
      "global %s covering VRT does not contain the point-cloud XY extent",
      label
    ))
  }
  covering
}

write_global_dtm <- function(point_cloud, output_path, work_directory,
                             chunk_size, dtm_buffer, dtm_resolution,
                             ptd_resolution, workers) {
  prepare_raster_work_directory(work_directory, "DTM")
  on.exit(unlink(work_directory, recursive = TRUE, force = TRUE), add = TRUE)

  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- dtm_buffer
  opt_select(catalog) <- DTM_CATALOG_SELECTION
  opt_progress(catalog) <- FALSE
  opt_output_files(catalog) <- file.path(work_directory, "dtm_{ID}")
  catalog@output_options$drivers$SpatRaster$param$datatype <- "FLT8S"
  source_crs <- spatial_reference_wkt(catalog)

  results <- with_catalog_workers(
    workers,
    "DTM",
    catalog_apply(
      catalog,
      dtm_chunk,
      dtm_resolution = dtm_resolution,
      ptd_resolution = ptd_resolution,
      .options = list(
        automerge = FALSE,
        drop_null = FALSE,
        raster_alignment = dtm_resolution
      )
    )
  )
  assert_catalog_completed(results, "DTM")
  chunk_paths <- sort(unname(unlist(results, use.names = FALSE)))
  if (length(chunk_paths) == 0L || any(!file.exists(chunk_paths))) {
    stop("DTM LAScatalog processing did not write every chunk raster")
  }
  mosaic <- build_dtm_overlap_mosaic(
    chunk_paths,
    work_directory,
    fallback_crs = source_crs
  )
  covering <- cover_virtual_raster(
    mosaic,
    point_cloud,
    dtm_resolution,
    work_directory,
    "DTM"
  )
  stream_virtual_raster(covering, output_path, "DTM")
}

build_dtm_overlap_mosaic <- function(chunk_paths, work_directory,
                                     fallback_crs = NA_character_) {
  reference_crs <- chunk_reference_crs(chunk_paths, "DTM")
  if ((is.na(reference_crs) || !nzchar(reference_crs)) &&
      !is.na(fallback_crs) && nzchar(fallback_crs)) {
    reference_crs <- fallback_crs
  }
  mosaic_path <- file.path(work_directory, "dtm_mosaic.tif")
  mosaic <- terra::mosaic(
    terra::sprc(lapply(chunk_paths, terra::rast)),
    filename = mosaic_path,
    overwrite = TRUE,
    wopt = list(
      datatype = "FLT8S",
      gdal = c("TILED=YES", "COMPRESS=LZW", "BIGTIFF=IF_SAFER")
    )
  )
  if (terra::inMemory(mosaic) || !file.exists(mosaic_path)) {
    stop("global DTM overlap mosaic was not written disk-to-disk")
  }

  mosaic_vrt_path <- file.path(work_directory, "dtm_mosaic.vrt")
  arguments <- c("-overwrite")
  if (!is.na(reference_crs) && nzchar(reference_crs)) {
    arguments <- c(arguments, "-a_srs", shQuote(reference_crs))
  }
  arguments <- c(
    arguments,
    shQuote(mosaic_vrt_path),
    shQuote(mosaic_path)
  )
  status <- system2(
    "gdalbuildvrt",
    arguments
  )
  if (!identical(status, 0L) || !file.exists(mosaic_vrt_path)) {
    stop("could not create the global DTM publication VRT")
  }
  result <- terra::rast(mosaic_vrt_path)
  if (!is.na(reference_crs) && nzchar(reference_crs)) {
    actual_crs <- terra::crs(result)
    if (is.na(actual_crs) || !nzchar(actual_crs)) {
      stop("global DTM publication VRT did not persist its reference CRS")
    }
  }
  result
}

chm_chunk <- function(chunk, dtm_path, voxel_resolution, maximum_height,
                      chm_resolution) {
  lidR::set_lidr_threads(1L)
  las <- readLAS(chunk)
  if (is.empty(las)) return(empty_chunk_raster(chunk, chm_resolution))
  las <- normalize_height(las, terra::rast(dtm_path))
  las <- filter_poi(las, is.finite(Z) & Z >= 0 & Z <= maximum_height)
  if (is.empty(las)) return(empty_chunk_raster(chunk, chm_resolution))
  voxels <- voxelize_points(las, res = voxel_resolution)
  if (is.empty(voxels)) return(empty_chunk_raster(chunk, chm_resolution))
  rasterize_canopy(voxels, res = chm_resolution, algorithm = p2r())
}

write_global_chm <- function(point_cloud, dtm_path, output_path, work_directory,
                             chunk_size, voxel_resolution, maximum_height,
                             chm_resolution, workers) {
  prepare_raster_work_directory(work_directory, "CHM")
  on.exit(unlink(work_directory, recursive = TRUE, force = TRUE), add = TRUE)

  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- 0
  opt_select(catalog) <- "xyz"
  opt_progress(catalog) <- FALSE
  opt_output_files(catalog) <- file.path(work_directory, "chm_{ID}")

  results <- with_catalog_workers(
    workers,
    "CHM",
    catalog_apply(
      catalog,
      chm_chunk,
      dtm_path = dtm_path,
      voxel_resolution = voxel_resolution,
      maximum_height = maximum_height,
      chm_resolution = chm_resolution,
      .options = list(
        automerge = FALSE,
        drop_null = FALSE,
        raster_alignment = chm_resolution
      )
    )
  )
  result <- build_chunk_virtual_raster(
    results,
    work_directory,
    "CHM",
    terra::crs(terra::rast(dtm_path))
  )
  covering <- cover_virtual_raster(
    result,
    point_cloud,
    chm_resolution,
    work_directory,
    "CHM"
  )
  stream_virtual_raster(covering, output_path, "CHM")
}

# Memory-bounded global segment aggregation --------------------------------

available_extra_dimensions <- function(point_cloud) {
  header <- readLASheader(point_cloud)
  extra_bytes <- header@VLR$Extra_Bytes[["Extra Bytes Description"]]
  if (is.null(extra_bytes) || length(extra_bytes) == 0) return(character())
  unique(vapply(extra_bytes, function(description) {
    as.character(description$name)
  }, character(1)))
}

select_instance_dimensions <- function(point_cloud, candidates) {
  available <- available_extra_dimensions(point_cloud)
  unique(candidates[candidates %in% available])
}

segment_catalog_selection <- function(point_cloud, instance_dimensions) {
  header <- readLASheader(point_cloud)
  extra_bytes <- header@VLR$Extra_Bytes[["Extra Bytes Description"]]
  if (is.null(extra_bytes) || length(extra_bytes) == 0) {
    return(SEGMENT_CATALOG_BASE_SELECTION)
  }
  available <- vapply(extra_bytes, function(description) {
    as.character(description$name)
  }, character(1))
  segment_selection_from_names(available, instance_dimensions)
}

segment_selection_from_names <- function(available, instance_dimensions) {
  positions <- unique(match(instance_dimensions, available))
  positions <- positions[!is.na(positions)]
  if (length(positions) == 0) return(SEGMENT_CATALOG_BASE_SELECTION)

  # lidR exposes individual ExtraBytes selectors only for positions 1-9.
  # Position 0 requests all ExtraBytes while still excluding unrelated
  # standard LAS attributes. This fallback preserves dimensions beyond the
  # ninth ExtraBytes field without returning to the all-attribute wildcard.
  if (any(positions > 9L)) {
    return(paste0(SEGMENT_CATALOG_BASE_SELECTION, "0"))
  }
  paste0(SEGMENT_CATALOG_BASE_SELECTION, paste(positions, collapse = ""))
}

segment_bucket <- function(instance_id, bucket_count) {
  as.integer((as.numeric(instance_id) %% bucket_count) + 1L)
}

write_segment_chunk_store <- function(voxels, layers, apex, work_directory,
                                      bucket_count) {
  voxels[, bucket := segment_bucket(instance_id, bucket_count)]
  layers[, bucket := segment_bucket(instance_id, bucket_count)]
  apex[, bucket := segment_bucket(instance_id, bucket_count)]
  paths <- character()
  for (bucket_index in sort(unique(voxels$bucket))) {
    path <- tempfile(
      pattern = sprintf("segment_%d_%03d_", Sys.getpid(), bucket_index),
      tmpdir = work_directory,
      fileext = ".rds"
    )
    saveRDS(
      list(
        voxels = voxels[bucket == bucket_index, .(
          instance_dimension, instance_id, voxel_x, voxel_y, voxel_z
        )],
        layers = layers[bucket == bucket_index, .(
          instance_dimension, instance_id, occupied_layer
        )],
        apex = apex[bucket == bucket_index, .(
          instance_dimension, instance_id, apex_x, apex_y, apex_z
        )]
      ),
      path,
      compress = FALSE
    )
    paths[[as.character(bucket_index)]] <- path
  }
  paths
}

segment_chunk <- function(chunk, dtm_path, voxel_resolution, maximum_height,
                          instance_dimensions, work_directory, bucket_count) {
  configure_catalog_worker()
  las <- readLAS(chunk)
  if (is.empty(las)) {
    if (!chunk_has_valid_extent(chunk)) return(NULL)
    return(list(paths = NULL))
  }
  selected <- instance_dimensions[instance_dimensions %in% names(las@data)]
  if (length(selected) == 0) return(list(paths = NULL))
  dtm <- terra::rast(dtm_path)
  las <- normalize_height(las, dtm)
  las_data <- as.data.table(las@data)
  dimension_paths <- lapply(selected, function(instance_dimension) {
    source <- data.table(
      X = las_data$X,
      Y = las_data$Y,
      Z = las_data$Z,
      instance_dimension = instance_dimension,
      instance_id = las_data[[instance_dimension]]
    )
    source <- source[
      is.finite(instance_id) & instance_id > 0 &
        is.finite(Z) & Z >= 0 & Z <= maximum_height
    ]
    if (nrow(source) == 0) return(character())

    segment_keys <- c("instance_dimension", "instance_id")
    apex <- source[
      source[, .I[which.max(Z)], by = segment_keys]$V1,
      .(instance_dimension, instance_id, apex_x = X, apex_y = Y, apex_z = Z)
    ]
    source[, `:=`(
      voxel_x = floor(X / voxel_resolution),
      voxel_y = floor(Y / voxel_resolution),
      voxel_z = floor(Z / voxel_resolution)
    )]

    write_segment_chunk_store(
      unique(source[, .(
        instance_dimension, instance_id, voxel_x, voxel_y, voxel_z
      )]),
      unique(source[, .(
        instance_dimension, instance_id, occupied_layer = floor(Z)
      )]),
      apex,
      work_directory,
      bucket_count
    )
  })
  list(paths = do.call(c, dimension_paths))
}

accumulate_segments <- function(point_cloud, dtm_path, chunk_size,
                                voxel_resolution, maximum_height,
                                instance_dimensions, workers, work_directory,
                                bucket_count = SEGMENT_BUCKET_COUNT) {
  prepare_raster_work_directory(work_directory, "segment")
  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- 0
  selection <- segment_catalog_selection(point_cloud, instance_dimensions)
  opt_select(catalog) <- selection
  opt_progress(catalog) <- FALSE
  message(sprintf(
    "Reading segment dimensions with LAS selection %s",
    selection
  ))
  chunks <- with_catalog_workers(
    workers,
    "segment",
    catalog_apply(
      catalog,
      segment_chunk,
      dtm_path = dtm_path,
      voxel_resolution = voxel_resolution,
      maximum_height = maximum_height,
      instance_dimensions = instance_dimensions,
      work_directory = work_directory,
      bucket_count = bucket_count,
      .options = list(automerge = FALSE, drop_null = FALSE)
    )
  )
  assert_catalog_completed(chunks, "segment")
  chunks <- lapply(chunks, `[[`, "paths")
  chunks <- Filter(function(paths) length(paths) > 0L, chunks)
  if (length(chunks) == 0) return(NULL)
  list(chunks = chunks, bucket_count = bucket_count)
}

finalize_segments <- function(accumulated, parameters) {
  voxels <- accumulated$voxels
  layers <- accumulated$layers
  apex <- accumulated$apex

  segment_keys <- c("instance_dimension", "instance_id")
  voxel_metrics <- voxels[, .(n_vox = .N), by = segment_keys]
  voxel_metrics[, voxel_volume := n_vox * parameters$voxel_resolution^3]
  crown_metrics <- voxels[, .(
    crown_area = uniqueN(data.table(voxel_x, voxel_y)) *
      parameters$voxel_resolution^2
  ), by = segment_keys]
  layer_metrics <- layers[, .(
    n_occupied_layers = uniqueN(occupied_layer)
  ), by = segment_keys]
  extent_metrics <- voxels[, {
    if (.N < 3) {
      .(pca_extent_1 = NA_real_, pca_extent_2 = NA_real_, pca_extent_3 = NA_real_)
    } else {
      coordinates <- as.matrix(.SD) * parameters$voxel_resolution
      extents <- tryCatch({
        rotated <- prcomp(coordinates, center = TRUE)$x
        apply(rotated, 2, function(values) diff(range(values)))
      }, error = function(error) rep(NA_real_, 3))
      .(
        pca_extent_1 = extents[[1]],
        pca_extent_2 = extents[[2]],
        pca_extent_3 = extents[[3]]
      )
    }
  }, by = segment_keys, .SDcols = c("voxel_x", "voxel_y", "voxel_z")]

  segments <- Reduce(
    function(left, right) merge(left, right, by = segment_keys, all = TRUE),
    list(apex, voxel_metrics, crown_metrics, layer_metrics, extent_metrics)
  )
  segments[, `:=`(
    pass_voxels = n_vox >= parameters$minimum_tree_voxels,
    pass_apex = apex_z > parameters$apex_minimum_height,
    pass_thickness = !is.na(pca_extent_3) &
      pca_extent_3 >= parameters$minimum_tree_thickness,
    pass_occupied_layers = n_occupied_layers >= parameters$minimum_occupied_layers
  )]
  segments[, is_tree := pass_voxels & pass_apex &
    pass_thickness & pass_occupied_layers]
  segments[, fail_reason := paste0(
    ifelse(!pass_voxels, "voxels ", ""),
    ifelse(!pass_apex, "apex ", ""),
    ifelse(!pass_thickness, "thickness ", ""),
    ifelse(!pass_occupied_layers, "layers ", "")
  )]
  segments
}

finalize_segment_store <- function(store, parameters) {
  previous_threads <- data.table::getDTthreads()
  on.exit(data.table::setDTthreads(previous_threads), add = TRUE)
  data.table::setDTthreads(DATA_TABLE_THREADS)
  finalized <- vector("list", store$bucket_count)
  for (bucket_index in seq_len(store$bucket_count)) {
    key <- as.character(bucket_index)
    paths <- unlist(lapply(store$chunks, function(chunk_paths) {
      unname(chunk_paths[names(chunk_paths) == key])
    }), use.names = FALSE)
    if (length(paths) == 0) next

    pieces <- lapply(paths, readRDS)
    voxels <- unique(rbindlist(lapply(pieces, `[[`, "voxels")))
    layers <- unique(rbindlist(lapply(pieces, `[[`, "layers")))
    apex <- rbindlist(lapply(pieces, `[[`, "apex"))
    apex <- apex[
      apex[, .I[which.max(apex_z)],
        by = c("instance_dimension", "instance_id")]$V1
    ]
    finalized[[bucket_index]] <- finalize_segments(
      list(voxels = voxels, layers = layers, apex = apex),
      parameters
    )
    rm(pieces, voxels, layers, apex)
    gc(verbose = FALSE)
  }
  finalized <- Filter(Negate(is.null), finalized)
  if (length(finalized) == 0) return(NULL)
  segments <- rbindlist(finalized, use.names = TRUE)
  setorderv(segments, c("instance_dimension", "instance_id"))
  segments
}

# Scientific tile metrics and output adapters ------------------------------

assign_segments_to_tiles <- function(segments, tiles) {
  if (is.null(segments)) return(NULL)
  segments[, tile_id := NA_integer_]
  if (nrow(tiles) == 0) return(segments)

  bounds <- t(vapply(seq_len(nrow(tiles)), function(index) {
    as.numeric(st_bbox(tiles[index, ]))
  }, numeric(4)))
  colnames(bounds) <- c("xmin", "ymin", "xmax", "ymax")
  segments[, tile_id := mapply(function(apex_x, apex_y) {
    matches <- which(
      apex_x >= bounds[, "xmin"] & apex_x < bounds[, "xmax"] &
        apex_y >= bounds[, "ymin"] & apex_y < bounds[, "ymax"]
    )
    if (length(matches) == 0) NA_integer_ else tiles$tile_id[[matches[[1]]]]
  }, apex_x, apex_y)]
  segments
}

gini <- function(values) {
  values <- values[!is.na(values)]
  count <- length(values)
  if (count < 2) return(NA_real_)
  if (any(values < 0)) values <- values - min(values)
  values <- sort(values)
  total <- sum(values)
  if (total == 0) return(0)
  coefficient <- (2 * sum(seq_len(count) * values) / (count * total)) -
    (count + 1) / count
  coefficient * count / (count - 1)
}

empty_tree_metrics <- function() {
  list(
    n_seg_total = NA_integer_,
    n_trees = NA_integer_,
    tree_height_max = NA_real_,
    tree_height_mean = NA_real_,
    tree_height_gini = NA_real_,
    tree_crownarea_mean = NA_real_,
    tree_crownarea_max = NA_real_,
    tree_crownarea_gini = NA_real_,
    tree_volume_mean = NA_real_,
    tree_volume_max = NA_real_,
    tree_volume_gini = NA_real_
  )
}

tree_metrics_for_tile <- function(segments, tile_id) {
  if (is.null(segments)) return(empty_tree_metrics())
  target_tile_id <- tile_id
  in_tile <- segments[segments$tile_id == target_tile_id]
  trees <- in_tile[is_tree == TRUE]
  metrics <- empty_tree_metrics()
  metrics$n_seg_total <- nrow(in_tile)
  metrics$n_trees <- nrow(trees)
  if (nrow(trees) == 0) return(metrics)

  metrics$tree_height_max <- safe_round(max(trees$apex_z))
  metrics$tree_height_mean <- safe_round(mean(trees$apex_z))
  metrics$tree_height_gini <- safe_round(gini(trees$apex_z))
  metrics$tree_crownarea_mean <- safe_round(mean(trees$crown_area))
  metrics$tree_crownarea_max <- safe_round(max(trees$crown_area))
  metrics$tree_crownarea_gini <- safe_round(gini(trees$crown_area))
  metrics$tree_volume_mean <- safe_round(mean(trees$voxel_volume))
  metrics$tree_volume_max <- safe_round(max(trees$voxel_volume))
  metrics$tree_volume_gini <- safe_round(gini(trees$voxel_volume))
  metrics
}

result_with_tree_metrics <- function(base_result, segments) {
  result <- copy(base_result)
  tree_columns <- names(empty_tree_metrics())
  if (nrow(result) == 0) return(result)
  for (index in seq_len(nrow(result))) {
    metrics <- tree_metrics_for_tile(segments, result$tile_id[[index]])
    for (name in tree_columns) {
      set(result, i = index, j = name, value = metrics[[name]])
    }
  }
  result
}

empty_segment_diagnostics <- function() {
  data.table(
    file = character(),
    sensor = character(),
    country = character(),
    tile_id = integer(),
    PredInstance = numeric(),
    n_vox = integer(),
    apex_z = numeric(),
    pc_ext1 = numeric(),
    pc_ext2 = numeric(),
    pc_ext3 = numeric(),
    n_zlayer = integer(),
    pass_vox = logical(),
    pass_apex = logical(),
    pass_thick = logical(),
    pass_zlayer = logical(),
    is_tree = logical(),
    apex_in_tile = logical()
  )
}

write_upstream_csv <- function(values, path) {
  utils::write.csv(
    as.data.frame(values),
    path,
    row.names = FALSE,
    na = "NA"
  )
  invisible(path)
}

write_segment_diagnostics <- function(segments, point_cloud, path) {
  diagnostics <- empty_segment_diagnostics()
  if (!is.null(segments) && nrow(segments) > 0) {
    diagnostics <- segments[, .(
      file = basename(point_cloud),
      sensor = NA_character_,
      country = NA_character_,
      tile_id,
      PredInstance = instance_id,
      n_vox,
      apex_z = round(apex_z, 4),
      pc_ext1 = round(pca_extent_1, 4),
      pc_ext2 = round(pca_extent_2, 4),
      pc_ext3 = round(pca_extent_3, 4),
      n_zlayer = n_occupied_layers,
      pass_vox = pass_voxels,
      pass_apex,
      pass_thick = pass_thickness,
      pass_zlayer = pass_occupied_layers,
      is_tree,
      apex_in_tile = !is.na(tile_id)
    )]
  }
  write_upstream_csv(diagnostics, path)
}

empty_metric_values <- function(voxel_total) {
  list(
    vox_filled = 0L,
    vox_total = voxel_total,
    veg_density = NA_real_,
    zsd = NA_real_,
    zskew = NA_real_,
    zkurt = NA_real_,
    zq90 = NA_real_,
    box_dim_fixed = NA_real_,
    vci = NA_real_,
    rumple = NA_real_,
    gap_fraction = NA_real_,
    chm_sd = NA_real_,
    chm_cv = NA_real_,
    height_max = NA_real_,
    height_mean = NA_real_
  )
}

safe_round <- function(value, digits = 4) {
  if (length(value) == 0 || !is.finite(value[[1]])) return(NA_real_)
  round(as.numeric(value[[1]]), digits)
}

calculate_tile_metrics <- function(point_cloud, tile, dtm, parameters) {
  bounds <- st_bbox(tile)
  voxel_total <- round(
    (parameters$tile_size / parameters$voxel_resolution)^2 *
      ((parameters$maximum_height - parameters$vegetation_minimum_height) /
         parameters$voxel_resolution)
  )
  empty <- empty_metric_values(voxel_total)

  las <- readLAS(
    point_cloud,
    select = "xyz",
    filter = sprintf(
      "-inside %.10f %.10f %.10f %.10f",
      bounds[["xmin"]], bounds[["ymin"]], bounds[["xmax"]], bounds[["ymax"]]
    )
  )
  if (is.empty(las)) return(empty)

  las <- normalize_height(las, dtm)
  las <- filter_poi(las, is.finite(Z) & Z >= 0 & Z <= parameters$maximum_height)
  if (is.empty(las)) return(empty)

  voxels <- voxelize_points(las, res = parameters$voxel_resolution)
  if (is.empty(voxels)) return(empty)

  height_max <- max(voxels@data$Z, na.rm = TRUE)
  height_mean <- mean(voxels@data$Z, na.rm = TRUE)
  chm <- rasterize_canopy(
    voxels,
    res = parameters$chm_resolution,
    algorithm = p2r()
  )
  chm_values <- terra::values(chm, mat = FALSE)
  observed <- chm_values[is.finite(chm_values)]
  chm_mean <- if (length(observed)) mean(observed) else NA_real_
  chm_sd <- if (length(observed) > 1) stats::sd(observed) else NA_real_
  gap_fraction <- if (length(observed)) {
    mean(observed < parameters$gap_height_threshold)
  } else {
    NA_real_
  }
  rumple <- tryCatch(rumple_index(chm), error = function(error) NA_real_)

  vegetation <- filter_poi(voxels, Z > parameters$vegetation_minimum_height)
  if (is.empty(vegetation)) {
    empty$height_max <- safe_round(height_max)
    empty$height_mean <- safe_round(height_mean)
    empty$rumple <- safe_round(rumple)
    empty$gap_fraction <- safe_round(gap_fraction)
    empty$chm_sd <- safe_round(chm_sd)
    empty$chm_cv <- safe_round(chm_sd / chm_mean)
    return(empty)
  }

  vegetation_data <- as.data.table(vegetation@data)
  filled <- nrow(vegetation_data)
  z_metrics <- cloud_metrics(vegetation, .stdmetrics_z)

  voxel_indices <- unique(vegetation_data[, .(
    vx = floor(X / parameters$voxel_resolution),
    vy = floor(Y / parameters$voxel_resolution),
    vz = floor(Z / parameters$voxel_resolution)
  )])
  box_widths <- parameters$voxel_resolution * 2^(0:30)
  box_widths <- box_widths[box_widths < parameters$tile_size]
  scale_factors <- unique(round(box_widths / parameters$voxel_resolution))
  counts <- vapply(scale_factors, function(scale_factor) {
    uniqueN(voxel_indices[, .(
      vx = vx %/% scale_factor,
      vy = vy %/% scale_factor,
      vz = vz %/% scale_factor
    )])
  }, numeric(1))
  usable_counts <- is.finite(counts) & counts > 0
  box_dimension <- if (sum(usable_counts) >= 2) {
    unname(coef(lm(
      log(counts[usable_counts]) ~ log(1 / box_widths[usable_counts])
    ))[[2]])
  } else {
    NA_real_
  }

  layer_breaks <- seq(0, parameters$maximum_height, by = 1)
  layers <- cut(vegetation_data$Z, breaks = layer_breaks, include.lowest = TRUE)
  layer_counts <- table(factor(layers, levels = levels(layers)))
  proportions <- layer_counts / sum(layer_counts)
  nonzero <- proportions[proportions > 0]
  vci <- if (length(layer_counts) > 1) {
    -sum(nonzero * log(nonzero)) / log(length(layer_counts))
  } else {
    NA_real_
  }

  list(
    vox_filled = filled,
    vox_total = voxel_total,
    veg_density = safe_round(filled / voxel_total),
    zsd = safe_round(z_metrics$zsd),
    zskew = safe_round(z_metrics$zskew),
    zkurt = safe_round(z_metrics$zkurt),
    zq90 = safe_round(z_metrics$zq90),
    box_dim_fixed = safe_round(box_dimension),
    vci = safe_round(vci),
    rumple = safe_round(rumple),
    gap_fraction = safe_round(gap_fraction),
    chm_sd = safe_round(chm_sd),
    chm_cv = safe_round(chm_sd / chm_mean),
    height_max = safe_round(height_max),
    height_mean = safe_round(height_mean)
  )
}

build_tile_row <- function(point_cloud_name, tile, edge_tile, tile_count,
                           metrics, tree_metrics) {
  bounds <- st_bbox(tile)
  as.data.table(c(list(
    file = point_cloud_name,
    sensor = NA_character_,
    country = NA_character_,
    tile_id = tile$tile_id[[1]],
    tile_xmin = as.numeric(bounds[["xmin"]]),
    tile_ymin = as.numeric(bounds[["ymin"]]),
    edge_tile = edge_tile,
    n_tiles_plot = as.integer(tile_count)
  ), metrics, tree_metrics))
}

empty_result_table <- function() {
  data.table(
    file = character(),
    sensor = character(),
    country = character(),
    tile_id = integer(),
    tile_xmin = numeric(),
    tile_ymin = numeric(),
    edge_tile = logical(),
    n_tiles_plot = integer(),
    vox_filled = integer(),
    vox_total = integer(),
    veg_density = numeric(),
    zsd = numeric(),
    zskew = numeric(),
    zkurt = numeric(),
    zq90 = numeric(),
    box_dim_fixed = numeric(),
    vci = numeric(),
    rumple = numeric(),
    gap_fraction = numeric(),
    chm_sd = numeric(),
    chm_cv = numeric(),
    height_max = numeric(),
    height_mean = numeric(),
    n_seg_total = integer(),
    n_trees = integer(),
    tree_height_max = numeric(),
    tree_height_mean = numeric(),
    tree_height_gini = numeric(),
    tree_crownarea_mean = numeric(),
    tree_crownarea_max = numeric(),
    tree_crownarea_gini = numeric(),
    tree_volume_mean = numeric(),
    tree_volume_max = numeric(),
    tree_volume_gini = numeric()
  )
}

apply_output_crs <- function(geometry, dtm) {
  raster_crs <- terra::crs(dtm)
  if (nzchar(raster_crs)) st_crs(geometry) <- st_crs(raster_crs)
  geometry
}

write_tile_geojson <- function(tiles, result, dtm, path) {
  if (nrow(tiles) == 0) {
    writeLines('{"type":"FeatureCollection","features":[]}', path, useBytes = TRUE)
    return(invisible(path))
  }
  output <- apply_output_crs(tiles, dtm)
  attributes <- as.data.frame(result)
  for (name in setdiff(names(attributes), "tile_id")) {
    output[[name]] <- attributes[[name]]
  }
  st_write(output, path, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE)
  invisible(path)
}

write_layout_png <- function(aoi, tiles, edge_flags, point_cloud_name, tile_size, path) {
  png(path, width = 1600, height = 1200, res = 150)
  on.exit(dev.off(), add = TRUE)
  par(mar = c(5, 5, 5, 2) + 0.1)
  plot_bounds <- st_bbox(aoi$inclusion)
  if (nrow(tiles) > 0) {
    tile_bounds <- st_bbox(tiles)
    plot_bounds[c("xmin", "ymin")] <- pmin(
      plot_bounds[c("xmin", "ymin")],
      tile_bounds[c("xmin", "ymin")]
    )
    plot_bounds[c("xmax", "ymax")] <- pmax(
      plot_bounds[c("xmax", "ymax")],
      tile_bounds[c("xmax", "ymax")]
    )
  }
  plot(
    aoi$inclusion,
    col = adjustcolor("#2e8b57", alpha.f = 0.12),
    border = "#17633b",
    lwd = 3,
    axes = TRUE,
    asp = 1,
    xlim = as.numeric(plot_bounds[c("xmin", "xmax")]),
    ylim = as.numeric(plot_bounds[c("ymin", "ymax")]),
    xlab = "Point-cloud-local X",
    ylab = "Point-cloud-local Y",
    main = sprintf("%s — %d valid Analysis Tiles", point_cloud_name, nrow(tiles))
  )
  if (length(aoi$exclusion) > 0) {
    plot(
      aoi$exclusion,
      add = TRUE,
      col = adjustcolor("#dc2626", alpha.f = 0.25),
      border = "#991b1b",
      lwd = 2
    )
  }
  if (nrow(tiles) > 0) {
    tile_colors <- ifelse(edge_flags, "#f59e0b", "#2563eb")
    for (index in seq_len(nrow(tiles))) {
      plot(st_geometry(tiles[index, ]), add = TRUE, border = tile_colors[[index]], lwd = 2)
    }
    centers <- st_coordinates(st_centroid(st_geometry(tiles)))
    text(centers[, 1], centers[, 2], labels = tiles$tile_id, cex = 0.85)
  } else {
    text(mean(par("usr")[1:2]), mean(par("usr")[3:4]), "0 valid tiles", cex = 1.4)
  }

  bounds <- st_bbox(aoi$inclusion)
  span_x <- as.numeric(bounds[["xmax"]] - bounds[["xmin"]])
  span_y <- as.numeric(bounds[["ymax"]] - bounds[["ymin"]])
  arrow_x <- as.numeric(bounds[["xmax"]] - span_x * 0.08)
  arrow_y <- as.numeric(bounds[["ymax"]] - span_y * 0.18)
  arrows(arrow_x, arrow_y, arrow_x, arrow_y + span_y * 0.1, length = 0.12, lwd = 2)
  text(arrow_x, arrow_y + span_y * 0.125, "N", font = 2)

  scale_x <- as.numeric(bounds[["xmin"]] + span_x * 0.06)
  scale_y <- as.numeric(bounds[["ymin"]] + span_y * 0.06)
  segments(scale_x, scale_y, scale_x + tile_size, scale_y, lwd = 4)
  segments(scale_x, scale_y - span_y * 0.01, scale_x, scale_y + span_y * 0.01, lwd = 2)
  segments(
    scale_x + tile_size,
    scale_y - span_y * 0.01,
    scale_x + tile_size,
    scale_y + span_y * 0.01,
    lwd = 2
  )
  text(scale_x + tile_size / 2, scale_y + span_y * 0.035, sprintf("%g m", tile_size))
  boundary_label <- if (identical(aoi$source, "point_cloud_extent")) {
    "Point-cloud extent"
  } else {
    "Audit AOI"
  }
  legend_labels <- c(boundary_label, "Edge tile", "Interior tile")
  legend_colors <- c("#17633b", "#f59e0b", "#2563eb")
  legend_widths <- c(3, 2, 2)
  if (length(aoi$exclusion) > 0) {
    legend_labels <- append(legend_labels, "Exclusion", after = 1)
    legend_colors <- append(legend_colors, "#991b1b", after = 1)
    legend_widths <- append(legend_widths, 2, after = 1)
  }
  legend(
    "bottomright",
    legend = legend_labels,
    col = legend_colors,
    lwd = legend_widths,
    bg = "white"
  )
  invisible(path)
}

# Orchestration and optional performance report ----------------------------

elapsed_seconds <- function(started_at) {
  unname(proc.time()[["elapsed"]] - started_at)
}

peak_rss_mib <- function() {
  status <- tryCatch(readLines("/proc/self/status", warn = FALSE),
    error = function(error) character())
  line <- grep("^VmHWM:", status, value = TRUE)
  if (length(line) == 0) return(NA_real_)
  as.numeric(gsub("[^0-9]", "", line[[1]])) / 1024
}

write_performance_report <- function(parameters, footprint_source, point_count, tile_count,
                                     instance_dimensions, catalog_workers,
                                     timings, path) {
  report <- data.table(
    point_cloud = basename(parameters$point_cloud),
    footprint_source = footprint_source,
    point_count = point_count,
    tile_count = tile_count,
    instance_dimension = if (length(instance_dimensions) == 0) {
      NA_character_
    } else {
      paste(instance_dimensions, collapse = "|")
    },
    threads_requested = parameters$threads,
    threads_effective = get_lidr_threads(),
    catalog_workers = catalog_workers,
    peak_rss_mib = round(peak_rss_mib(), 3),
    grid_seconds = round(timings$grid, 6),
    dtm_seconds = round(timings$dtm, 6),
    chm_seconds = round(timings$chm, 6),
    segment_seconds = round(timings$segments, 6),
    tile_seconds = round(timings$tiles, 6),
    output_seconds = round(timings$outputs, 6),
    total_seconds = round(timings$total, 6),
    tile_size = parameters$tile_size,
    grid_search_step = parameters$grid_search_step,
    ptd_resolution = parameters$ptd_resolution,
    dtm_resolution = parameters$dtm_resolution,
    maximum_height = parameters$maximum_height,
    voxel_resolution = parameters$voxel_resolution,
    vegetation_minimum_height = parameters$vegetation_minimum_height,
    chm_resolution = parameters$chm_resolution,
    gap_height_threshold = parameters$gap_height_threshold,
    minimum_tree_voxels = parameters$minimum_tree_voxels,
    apex_minimum_height = parameters$apex_minimum_height,
    minimum_tree_thickness = parameters$minimum_tree_thickness,
    minimum_occupied_layers = parameters$minimum_occupied_layers,
    dtm_chunk_size = parameters$dtm_chunk_size,
    chunk_size = parameters$chunk_size,
    dtm_buffer = parameters$dtm_buffer,
    dtm_storage_mode = "disk_backed_vrt",
    chm_storage_mode = "disk_backed_vrt",
    instance_dimension_candidates = paste(parameters$instance_dimension, collapse = "|")
  )
  fwrite(report, path, na = "NA")
  message(sprintf(
    "PERF total=%.3fs grid=%.3fs dtm=%.3fs chm=%.3fs segments=%.3fs tiles=%.3fs outputs=%.3fs peak_rss=%.1fMiB",
    timings$total, timings$grid, timings$dtm, timings$chm, timings$segments,
    timings$tiles, timings$outputs, report$peak_rss_mib[[1]]
  ))
  invisible(path)
}

main <- function() {
  total_started <- proc.time()[["elapsed"]]
  parameters <- parse_parameters()
  point_count <- point_count_from_las_header(parameters$point_cloud)
  assert_lidr_point_count_supported(point_count)
  paths <- artifact_paths(parameters$output_dir, parameters$dataset_id)
  segment_work_directory <- file.path(
    parameters$output_dir,
    sprintf(".%s_forest_structure_segment_chunks", parameters$dataset_id)
  )
  on.exit(
    unlink(segment_work_directory, recursive = TRUE, force = TRUE),
    add = TRUE
  )
  if (parameters$threads > 0) {
    set_lidr_threads(parameters$threads)
    message(sprintf("Using %d lidR threads", get_lidr_threads()))
  } else {
    message(sprintf("Using lidR default thread count: %d", get_lidr_threads()))
  }
  thread_budget <- max(
    1L,
    as.integer(
      if (parameters$threads > 0) parameters$threads else get_lidr_threads()
    )
  )
  catalog_workers <- min(
    thread_budget,
    max(1L, as.integer(parameters$catalog_workers))
  )
  message(sprintf(
    "Using %d memory-bounded LAScatalog worker(s) within the %d-thread allowance",
    catalog_workers,
    thread_budget
  ))
  grid_started <- proc.time()[["elapsed"]]
  aoi <- read_analysis_footprint(parameters$point_cloud, parameters$aoi)
  if (identical(aoi$source, "point_cloud_extent")) {
    message("No Audit AOI supplied; covering the complete point-cloud XY extent")
  } else {
    message(sprintf("Using Audit AOI: %s", basename(parameters$aoi)))
  }
  tiles <- build_analysis_tiles(
    aoi,
    parameters$tile_size,
    parameters$grid_search_step,
    thread_budget
  )
  grid_seconds <- elapsed_seconds(grid_started)
  message(sprintf("Optimized grid contains %d complete Analysis Tiles", nrow(tiles)))

  dtm_started <- proc.time()[["elapsed"]]
  dtm_path <- paths$dtm
  write_global_dtm(
    parameters$point_cloud,
    dtm_path,
    file.path(
      parameters$output_dir,
      sprintf(".%s_forest_structure_dtm_chunks", parameters$dataset_id)
    ),
    parameters$dtm_chunk_size,
    parameters$dtm_buffer,
    parameters$dtm_resolution,
    parameters$ptd_resolution,
    catalog_workers
  )
  dtm <- terra::rast(dtm_path)
  if (terra::inMemory(dtm)) {
    stop("published DTM unexpectedly materialized in memory")
  }
  dtm_seconds <- elapsed_seconds(dtm_started)

  chm_started <- proc.time()[["elapsed"]]
  chm_path <- paths$chm
  write_global_chm(
    parameters$point_cloud,
    dtm_path,
    chm_path,
    file.path(
      parameters$output_dir,
      sprintf(".%s_forest_structure_chm_chunks", parameters$dataset_id)
    ),
    parameters$chunk_size,
    parameters$voxel_resolution,
    parameters$maximum_height,
    parameters$chm_resolution,
    catalog_workers
  )
  chm_seconds <- elapsed_seconds(chm_started)

  segment_started <- proc.time()[["elapsed"]]
  instance_dimensions <- select_instance_dimensions(
    parameters$point_cloud,
    parameters$instance_dimension
  )
  segments <- NULL
  if (length(instance_dimensions) == 0) {
    message("No configured Instance Dimensions found; tree and segment metrics will be NA")
  } else {
    message(sprintf(
      "Using Instance Dimensions: %s",
      paste(instance_dimensions, collapse = ", ")
    ))
    accumulated <- accumulate_segments(
      parameters$point_cloud,
      dtm_path,
      parameters$chunk_size,
      parameters$voxel_resolution,
      parameters$maximum_height,
      instance_dimensions,
      catalog_workers,
      segment_work_directory
    )
    if (!is.null(accumulated)) {
      segments <- assign_segments_to_tiles(
        finalize_segment_store(accumulated, parameters),
        tiles
      )
      message(sprintf(
        "Global segment pass found %d segments (%d accepted trees) across %d dimension(s)",
        nrow(segments),
        sum(segments$is_tree, na.rm = TRUE),
        length(instance_dimensions)
      ))
      rm(accumulated)
    }
    unlink(segment_work_directory, recursive = TRUE, force = TRUE)
  }

  segment_seconds <- elapsed_seconds(segment_started)

  edge_flags <- compute_edge_flags(tiles, parameters$tile_size)
  tile_started <- proc.time()[["elapsed"]]
  tile_indices <- seq_len(nrow(tiles))
  tile_plan <- tile_worker_plan(thread_budget, length(tile_indices))
  tile_workers <- tile_plan$process_workers
  tile_threads_per_worker <- tile_plan$threads_per_worker
  calculate_row <- function(index) {
    if (tile_workers > 1L) {
      set_lidr_threads(tile_threads_per_worker)
    }
    worker_dtm <- rast(dtm_path)
    metrics <- calculate_tile_metrics(
      parameters$point_cloud,
      tiles[index, ],
      worker_dtm,
      parameters
    )
    build_tile_row(
      basename(parameters$point_cloud),
      tiles[index, ],
      edge_flags[[index]],
      nrow(tiles),
      metrics,
      empty_tree_metrics()
    )
  }
  if (length(tile_indices) > 0L) {
    message(sprintf(
      "Calculating %d tile metric rows sequentially with %d lidR thread(s)",
      length(tile_indices),
      tile_threads_per_worker
    ))
  }
  base_result <- collect_tile_rows(tile_indices, calculate_row, tile_workers)
  tile_seconds <- elapsed_seconds(tile_started)

  output_started <- proc.time()[["elapsed"]]
  output_dimensions <- if (length(instance_dimensions) == 0) {
    list(NULL)
  } else {
    as.list(instance_dimensions)
  }
  output_paths <- lapply(output_dimensions, function(instance_dimension) {
    target_dimension <- instance_dimension
    dimension_paths <- dimension_artifact_paths(paths, instance_dimension)
    dimension_segments <- if (is.null(instance_dimension) || is.null(segments)) {
      NULL
    } else {
      segments[instance_dimension == target_dimension]
    }
    result <- result_with_tree_metrics(base_result, dimension_segments)
    write_upstream_csv(result, dimension_paths$results)
    write_segment_diagnostics(
      dimension_segments,
      parameters$point_cloud,
      dimension_paths$segment_diagnostics
    )
    write_tile_geojson(
      tiles,
      result,
      dtm,
      dimension_paths$tiles_geojson
    )
    message(sprintf(
      "Wrote %d Analysis Tile rows for Instance Dimension %s to %s",
      nrow(result),
      if (is.null(instance_dimension)) "NA" else instance_dimension,
      dimension_paths$results
    ))
    dimension_paths
  })
  write_layout_png(
    aoi,
    tiles,
    edge_flags,
    basename(parameters$point_cloud),
    parameters$tile_size,
    paths$tiles_png
  )
  output_seconds <- elapsed_seconds(output_started)
  if (parameters$performance_report) {
    write_performance_report(
      parameters,
      aoi$source,
      point_count,
      nrow(tiles),
      instance_dimensions,
      catalog_workers,
      list(
        grid = grid_seconds,
        dtm = dtm_seconds,
        chm = chm_seconds,
        segments = segment_seconds,
        tiles = tile_seconds,
        outputs = output_seconds,
        total = elapsed_seconds(total_started)
      ),
      paths$performance
    )
  }
  invisible(output_paths)
}

if (!identical(Sys.getenv("FORESTSTRUCTURE_SOURCE_ONLY"), "1")) {
  tryCatch(
    main(),
    error = function(error) {
      message("forest-structure analysis failed: ", conditionMessage(error))
      quit(status = 1)
    }
  )
}
