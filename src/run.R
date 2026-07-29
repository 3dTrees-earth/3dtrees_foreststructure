suppressPackageStartupMessages({
  library(argparse)
  library(data.table)
  library(future)
  library(lidR)
  library(sf)
  library(terra)
})

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
    help = "Per-tile CHM resolution in metres (default: 0.5)"
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
    default = 200,
    help = "LAScatalog DTM chunk width in metres (default: 200)"
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
    "--performance-report", "--performance_report",
    action = "store_true",
    default = FALSE,
    help = "Write forest_structure_performance.csv with phase timings and peak RSS"
  )
  segments$add_argument(
    "--instance-dimension", "--instance_dimension",
    action = "append",
    default = NULL,
    help = paste(
      "Ordered instance-ID dimension candidate; repeat the option or provide",
      "comma-separated names. Defaults to PredInstance, PredInstance_SAT,",
      "PredInstance_FM, treeID"
    )
  )
  segments$add_argument(
    "--segment-diagnostics", "--segment_diagnostics",
    action = "store_true",
    default = FALSE,
    help = "Write segment_diagnostics.csv (disabled by default)"
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
      "PredInstance", "PredInstance_SAT", "PredInstance_FM", "treeID"
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
  args
}

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

read_point_cloud_extent <- function(path) {
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

dtm_chunk <- function(chunk, dtm_resolution, ptd_resolution) {
  lidR::set_lidr_threads(1L)
  las <- readLAS(chunk)
  if (is.empty(las)) return(NULL)
  las <- classify_ground(las, ptd(res = ptd_resolution))
  rasterize_terrain(las, res = dtm_resolution, algorithm = tin())
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

build_global_dtm <- function(point_cloud, chunk_size, dtm_buffer,
                             dtm_resolution, ptd_resolution, workers) {
  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- dtm_buffer
  opt_select(catalog) <- "xyz"
  opt_progress(catalog) <- FALSE

  result <- with_catalog_workers(
    workers,
    "DTM",
    catalog_apply(
      catalog,
      dtm_chunk,
      dtm_resolution = dtm_resolution,
      ptd_resolution = ptd_resolution,
      .options = list(automerge = TRUE, raster_alignment = dtm_resolution)
    )
  )
  if (inherits(result, "list")) {
    result <- Filter(Negate(is.null), result)
    if (length(result) == 0) return(NULL)
    result <- terra::mosaic(terra::sprc(result))
  }
  result
}

available_extra_dimensions <- function(point_cloud) {
  header <- readLASheader(point_cloud)
  extra_bytes <- header@VLR$Extra_Bytes[["Extra Bytes Description"]]
  if (is.null(extra_bytes) || length(extra_bytes) == 0) return(character())
  unique(vapply(extra_bytes, function(description) {
    as.character(description$name)
  }, character(1)))
}

select_instance_dimension <- function(point_cloud, candidates) {
  available <- available_extra_dimensions(point_cloud)
  selected <- candidates[candidates %in% available]
  if (length(selected) == 0) return(NULL)
  selected[[1]]
}

segment_chunk <- function(chunk, dtm_path, voxel_resolution, maximum_height,
                          instance_dimension) {
  lidR::set_lidr_threads(1L)
  las <- readLAS(chunk)
  if (is.empty(las) || !instance_dimension %in% names(las@data)) return(NULL)
  dtm <- terra::rast(dtm_path)
  las <- normalize_height(las, dtm)
  source <- as.data.table(las@data)
  source[, instance_id := get(instance_dimension)]
  source <- source[
    is.finite(instance_id) & instance_id > 0 &
      is.finite(Z) & Z >= 0 & Z <= maximum_height,
    .(X, Y, Z, instance_id)
  ]
  if (nrow(source) == 0) return(NULL)

  apex <- source[source[, .I[which.max(Z)], by = instance_id]$V1,
    .(instance_id, apex_x = X, apex_y = Y, apex_z = Z)]
  source[, `:=`(
    voxel_x = floor(X / voxel_resolution),
    voxel_y = floor(Y / voxel_resolution),
    voxel_z = floor(Z / voxel_resolution)
  )]

  list(
    voxels = unique(source[, .(instance_id, voxel_x, voxel_y, voxel_z)]),
    layers = unique(source[, .(instance_id, occupied_layer = floor(Z))]),
    apex = apex
  )
}

accumulate_segments <- function(point_cloud, dtm_path, chunk_size,
                                voxel_resolution, maximum_height,
                                instance_dimension, workers) {
  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- 0
  extra_dimensions <- available_extra_dimensions(point_cloud)
  extra_index <- match(instance_dimension, extra_dimensions) - 1L
  opt_select(catalog) <- if (is.finite(extra_index) && extra_index == 0) {
    "xyz0"
  } else {
    "*"
  }
  opt_progress(catalog) <- FALSE
  chunks <- with_catalog_workers(
    workers,
    "segment",
    catalog_apply(
      catalog,
      segment_chunk,
      dtm_path = dtm_path,
      voxel_resolution = voxel_resolution,
      maximum_height = maximum_height,
      instance_dimension = instance_dimension,
      .options = list(automerge = FALSE)
    )
  )
  chunks <- Filter(Negate(is.null), chunks)
  if (length(chunks) == 0) return(NULL)

  voxels <- unique(rbindlist(lapply(chunks, `[[`, "voxels")))
  layers <- unique(rbindlist(lapply(chunks, `[[`, "layers")))
  apex <- rbindlist(lapply(chunks, `[[`, "apex"))
  apex <- apex[apex[, .I[which.max(apex_z)], by = instance_id]$V1]
  list(voxels = voxels, layers = layers, apex = apex)
}

finalize_segments <- function(accumulated, parameters) {
  voxels <- accumulated$voxels
  layers <- accumulated$layers
  apex <- accumulated$apex

  voxel_metrics <- voxels[, .(n_vox = .N), by = instance_id]
  voxel_metrics[, voxel_volume := n_vox * parameters$voxel_resolution^3]
  crown_metrics <- voxels[, .(
    crown_area = uniqueN(data.table(voxel_x, voxel_y)) *
      parameters$voxel_resolution^2
  ), by = instance_id]
  layer_metrics <- layers[, .(
    n_occupied_layers = uniqueN(occupied_layer)
  ), by = instance_id]
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
  }, by = instance_id, .SDcols = c("voxel_x", "voxel_y", "voxel_z")]

  segments <- Reduce(
    function(left, right) merge(left, right, by = "instance_id", all = TRUE),
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

empty_segment_diagnostics <- function() {
  data.table(
    point_cloud = character(),
    instance_dimension = character(),
    instance_id = numeric(),
    tile_id = integer(),
    n_vox = integer(),
    voxel_volume = numeric(),
    crown_area = numeric(),
    apex_x = numeric(),
    apex_y = numeric(),
    apex_z = numeric(),
    pca_extent_1 = numeric(),
    pca_extent_2 = numeric(),
    pca_extent_3 = numeric(),
    n_occupied_layers = integer(),
    pass_voxels = logical(),
    pass_apex = logical(),
    pass_thickness = logical(),
    pass_occupied_layers = logical(),
    is_tree = logical(),
    fail_reason = character(),
    apex_in_tile = logical()
  )
}

write_segment_diagnostics <- function(segments, point_cloud, instance_dimension,
                                      path) {
  diagnostics <- empty_segment_diagnostics()
  if (!is.null(segments) && nrow(segments) > 0) {
    diagnostics <- segments[, .(
      point_cloud = basename(point_cloud),
      instance_dimension = instance_dimension,
      instance_id,
      tile_id,
      n_vox,
      voxel_volume = round(voxel_volume, 4),
      crown_area = round(crown_area, 4),
      apex_x = round(apex_x, 4),
      apex_y = round(apex_y, 4),
      apex_z = round(apex_z, 4),
      pca_extent_1 = round(pca_extent_1, 4),
      pca_extent_2 = round(pca_extent_2, 4),
      pca_extent_3 = round(pca_extent_3, 4),
      n_occupied_layers,
      pass_voxels,
      pass_apex,
      pass_thickness,
      pass_occupied_layers,
      is_tree,
      fail_reason,
      apex_in_tile = !is.na(tile_id)
    )]
  }
  fwrite(diagnostics, path, na = "NA")
  invisible(path)
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

create_chm_template <- function(tile, dtm, resolution) {
  bounds <- st_bbox(tile)
  template <- rast(
    xmin = as.numeric(bounds[["xmin"]]),
    xmax = as.numeric(bounds[["xmax"]]),
    ymin = as.numeric(bounds[["ymin"]]),
    ymax = as.numeric(bounds[["ymax"]]),
    resolution = resolution,
    crs = terra::crs(dtm)
  )
  values(template) <- NA_real_
  template
}

write_chm <- function(chm, path) {
  writeRaster(chm, path, overwrite = TRUE, filetype = "GTiff")
  invisible(path)
}

calculate_tile_metrics <- function(point_cloud, tile, dtm, parameters, chm_output_path) {
  bounds <- st_bbox(tile)
  voxel_total <- round(
    (parameters$tile_size / parameters$voxel_resolution)^2 *
      ((parameters$maximum_height - parameters$vegetation_minimum_height) /
         parameters$voxel_resolution)
  )
  empty <- empty_metric_values(voxel_total)
  chm_template <- create_chm_template(tile, dtm, parameters$chm_resolution)
  return_empty <- function() {
    write_chm(chm_template, chm_output_path)
    empty
  }

  las <- readLAS(
    point_cloud,
    select = "xyz",
    filter = sprintf(
      "-inside %.10f %.10f %.10f %.10f",
      bounds[["xmin"]], bounds[["ymin"]], bounds[["xmax"]], bounds[["ymax"]]
    )
  )
  if (is.empty(las)) return(return_empty())

  las <- normalize_height(las, dtm)
  las <- filter_poi(las, is.finite(Z) & Z >= 0 & Z <= parameters$maximum_height)
  if (is.empty(las)) return(return_empty())

  voxels <- voxelize_points(las, res = parameters$voxel_resolution)
  if (is.empty(voxels)) return(return_empty())

  height_max <- max(voxels@data$Z, na.rm = TRUE)
  height_mean <- mean(voxels@data$Z, na.rm = TRUE)
  raw_chm <- rasterize_canopy(voxels, res = parameters$chm_resolution, algorithm = p2r())
  chm <- terra::resample(raw_chm, chm_template, method = "near")
  write_chm(chm, chm_output_path)
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

build_tile_row <- function(point_cloud_name, tile, edge_tile, metrics, tree_metrics) {
  bounds <- st_bbox(tile)
  as.data.table(c(list(
    point_cloud = point_cloud_name,
    tile_id = tile$tile_id[[1]],
    tile_xmin = as.numeric(bounds[["xmin"]]),
    tile_ymin = as.numeric(bounds[["ymin"]]),
    edge_tile = edge_tile
  ), metrics, tree_metrics))
}

empty_result_table <- function() {
  data.table(
    point_cloud = character(),
    tile_id = integer(),
    tile_xmin = numeric(),
    tile_ymin = numeric(),
    edge_tile = logical(),
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
                                     instance_dimension, timings, path) {
  report <- data.table(
    point_cloud = basename(parameters$point_cloud),
    footprint_source = footprint_source,
    point_count = point_count,
    tile_count = tile_count,
    instance_dimension = if (is.null(instance_dimension)) NA_character_ else instance_dimension,
    threads_requested = parameters$threads,
    threads_effective = get_lidr_threads(),
    catalog_workers = get_lidr_threads(),
    peak_rss_mib = round(peak_rss_mib(), 3),
    grid_seconds = round(timings$grid, 6),
    dtm_seconds = round(timings$dtm, 6),
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
    instance_dimension_candidates = paste(parameters$instance_dimension, collapse = "|")
  )
  fwrite(report, path, na = "NA")
  message(sprintf(
    "PERF total=%.3fs grid=%.3fs dtm=%.3fs segments=%.3fs tiles=%.3fs outputs=%.3fs peak_rss=%.1fMiB",
    timings$total, timings$grid, timings$dtm, timings$segments,
    timings$tiles, timings$outputs, report$peak_rss_mib[[1]]
  ))
  invisible(path)
}

main <- function() {
  total_started <- proc.time()[["elapsed"]]
  parameters <- parse_parameters()
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
  dtm <- build_global_dtm(
    parameters$point_cloud,
    parameters$dtm_chunk_size,
    parameters$dtm_buffer,
    parameters$dtm_resolution,
    parameters$ptd_resolution,
    thread_budget
  )
  if (is.null(dtm)) stop("global DTM generation produced no raster")
  dtm_path <- file.path(parameters$output_dir, "forest_structure_dtm.tif")
  writeRaster(dtm, dtm_path, overwrite = TRUE, filetype = "GTiff")
  dtm_seconds <- elapsed_seconds(dtm_started)

  segment_started <- proc.time()[["elapsed"]]
  instance_dimension <- select_instance_dimension(
    parameters$point_cloud,
    parameters$instance_dimension
  )
  segments <- NULL
  if (is.null(instance_dimension)) {
    message("No configured Instance Dimension found; tree and segment metrics will be NA")
  } else {
    message(sprintf("Using Instance Dimension: %s", instance_dimension))
    accumulated <- accumulate_segments(
      parameters$point_cloud,
      dtm_path,
      parameters$chunk_size,
      parameters$voxel_resolution,
      parameters$maximum_height,
      instance_dimension,
      thread_budget
    )
    if (!is.null(accumulated)) {
      segments <- assign_segments_to_tiles(
        finalize_segments(accumulated, parameters),
        tiles
      )
      message(sprintf(
        "Global segment pass found %d segments (%d accepted trees)",
        nrow(segments),
        sum(segments$is_tree, na.rm = TRUE)
      ))
      rm(accumulated)
    }
  }

  if (parameters$segment_diagnostics) {
    write_segment_diagnostics(
      segments,
      parameters$point_cloud,
      if (is.null(instance_dimension)) NA_character_ else instance_dimension,
      file.path(parameters$output_dir, "segment_diagnostics.csv")
    )
  }
  segment_seconds <- elapsed_seconds(segment_started)

  chm_directory <- file.path(parameters$output_dir, "chm")
  if (!dir.exists(chm_directory) && !dir.create(chm_directory, recursive = TRUE)) {
    stop("could not create CHM output directory")
  }

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
    chm_path <- file.path(
      chm_directory,
      sprintf("tile_%06d_chm.tif", tiles$tile_id[[index]])
    )
    worker_dtm <- if (tile_workers > 1L) rast(dtm_path) else dtm
    metrics <- calculate_tile_metrics(
      parameters$point_cloud,
      tiles[index, ],
      worker_dtm,
      parameters,
      chm_path
    )
    build_tile_row(
      basename(parameters$point_cloud),
      tiles[index, ],
      edge_flags[[index]],
      metrics,
      tree_metrics_for_tile(segments, tiles$tile_id[[index]])
    )
  }
  if (length(tile_indices) > 0L) {
    message(sprintf(
      "Calculating %d tile metric rows sequentially with %d lidR thread(s)",
      length(tile_indices),
      tile_threads_per_worker
    ))
  }
  result <- collect_tile_rows(tile_indices, calculate_row, tile_workers)
  tile_seconds <- elapsed_seconds(tile_started)

  output_started <- proc.time()[["elapsed"]]
  output_path <- file.path(parameters$output_dir, "forest_structure_tiles.csv")
  fwrite(result, output_path, na = "NA")
  write_tile_geojson(
    tiles,
    result,
    dtm,
    file.path(parameters$output_dir, "forest_structure_tiles.geojson")
  )
  write_layout_png(
    aoi,
    tiles,
    edge_flags,
    basename(parameters$point_cloud),
    parameters$tile_size,
    file.path(parameters$output_dir, "forest_structure_tiles.png")
  )
  output_seconds <- elapsed_seconds(output_started)
  if (parameters$performance_report) {
    point_count <- readLASheader(parameters$point_cloud)@PHB[["Number of point records"]]
    write_performance_report(
      parameters,
      aoi$source,
      point_count,
      nrow(tiles),
      instance_dimension,
      list(
        grid = grid_seconds,
        dtm = dtm_seconds,
        segments = segment_seconds,
        tiles = tile_seconds,
        outputs = output_seconds,
        total = elapsed_seconds(total_started)
      ),
      file.path(parameters$output_dir, "forest_structure_performance.csv")
    )
  }
  message(sprintf("Wrote %d Analysis Tile rows to %s", nrow(result), output_path))
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
