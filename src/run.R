suppressPackageStartupMessages({
  library(argparse)
  library(data.table)
  library(lidR)
  library(sf)
  library(terra)
})

parse_parameters <- function() {
  parser <- ArgumentParser(
    description = "Compute forest-structure indices for optimized Analysis Tiles"
  )
  parser$add_argument(
    "--point-cloud", "--point_cloud",
    required = TRUE,
    help = "Path to exactly one LAS or LAZ point cloud"
  )
  parser$add_argument(
    "--aoi",
    required = TRUE,
    help = "Path to one inclusion-only GeoJSON Audit AOI"
  )
  parser$add_argument(
    "--output-dir", "--output_dir",
    required = TRUE,
    help = "Existing writable output directory"
  )
  parser$add_argument("--tile-size", "--tile_size", type = "double", default = 20)
  parser$add_argument(
    "--grid-search-step", "--grid_search_step",
    type = "double",
    default = 0.5
  )
  parser$add_argument("--ptd-resolution", "--ptd_resolution", type = "double", default = 20)
  parser$add_argument("--dtm-resolution", "--dtm_resolution", type = "double", default = 1)
  parser$add_argument("--maximum-height", "--maximum_height", type = "double", default = 70)
  parser$add_argument("--voxel-resolution", "--voxel_resolution", type = "double", default = 0.2)
  parser$add_argument(
    "--vegetation-minimum-height", "--vegetation_minimum_height",
    type = "double",
    default = 0.5
  )
  parser$add_argument("--chm-resolution", "--chm_resolution", type = "double", default = 0.5)
  parser$add_argument("--gap-height-threshold", "--gap_height_threshold", type = "double", default = 3)
  parser$add_argument("--chunk-size", "--chunk_size", type = "double", default = 60)
  parser$add_argument("--dtm-buffer", "--dtm_buffer", type = "double", default = 20)
  args <- parser$parse_args()

  if (!file.exists(args$point_cloud) || dir.exists(args$point_cloud)) {
    stop("--point-cloud must be exactly one existing LAS/LAZ file")
  }
  if (!grepl("\\.la[sz]$", args$point_cloud, ignore.case = TRUE)) {
    stop("--point-cloud must have a .las or .laz extension")
  }
  if (!file.exists(args$aoi) || dir.exists(args$aoi)) {
    stop("--aoi must be exactly one existing GeoJSON file")
  }
  if (!grepl("\\.(geojson|json)$", args$aoi, ignore.case = TRUE)) {
    stop("baseline --aoi input must have a .geojson or .json extension")
  }
  if (!dir.exists(args$output_dir)) {
    stop("--output-dir must be an existing directory")
  }

  positive <- c(
    "tile_size", "grid_search_step", "ptd_resolution", "dtm_resolution",
    "maximum_height", "voxel_resolution", "chm_resolution", "chunk_size",
    "dtm_buffer"
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
  args
}

read_inclusion_aoi <- function(path) {
  aoi <- st_read(path, quiet = TRUE, stringsAsFactors = FALSE)
  if (nrow(aoi) == 0) stop("Audit AOI contains no geometry")
  geometry_types <- unique(as.character(st_geometry_type(aoi, by_geometry = TRUE)))
  if (!all(geometry_types %in% c("POLYGON", "MULTIPOLYGON"))) {
    stop("baseline Audit AOI must contain only Polygon or MultiPolygon geometry")
  }

  # Audit AOIs are already expressed in the point cloud's local XY space.
  # GeoJSON readers may infer WGS84 from the container format; that metadata is
  # not authoritative for the local audit handoff and must not trigger a transform.
  st_crs(aoi) <- NA
  aoi <- st_make_valid(aoi)
  geometry <- st_union(st_geometry(aoi))
  if (length(geometry) == 0 || any(st_is_empty(geometry))) {
    stop("Audit AOI is empty after geometry validation")
  }
  geometry
}

make_grid_at <- function(geometry, tile_size, offset_x, offset_y) {
  bounds <- st_bbox(geometry)
  st_make_grid(
    geometry,
    cellsize = tile_size,
    offset = c(bounds[["xmin"]] - offset_x, bounds[["ymin"]] - offset_y)
  )
}

count_complete_tiles <- function(grid, geometry) {
  sum(lengths(st_within(grid, geometry)) > 0)
}

build_optimized_tiles <- function(geometry, tile_size, search_step) {
  offsets <- seq(0, tile_size - search_step, by = search_step)
  best_count <- -1L
  best_x <- 0
  best_y <- 0

  for (offset_x in offsets) {
    for (offset_y in offsets) {
      grid <- make_grid_at(geometry, tile_size, offset_x, offset_y)
      count <- count_complete_tiles(grid, geometry)
      if (count > best_count) {
        best_count <- count
        best_x <- offset_x
        best_y <- offset_y
      }
    }
  }

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
  las <- readLAS(chunk)
  if (is.empty(las)) return(NULL)
  las <- classify_ground(las, ptd(res = ptd_resolution))
  rasterize_terrain(las, res = dtm_resolution, algorithm = tin())
}

build_global_dtm <- function(point_cloud, chunk_size, dtm_buffer,
                             dtm_resolution, ptd_resolution) {
  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- dtm_buffer
  opt_select(catalog) <- "xyz"
  opt_progress(catalog) <- FALSE

  result <- catalog_apply(
    catalog,
    dtm_chunk,
    dtm_resolution = dtm_resolution,
    ptd_resolution = ptd_resolution,
    .options = list(automerge = TRUE, raster_alignment = dtm_resolution)
  )
  if (inherits(result, "list")) {
    result <- Filter(Negate(is.null), result)
    if (length(result) == 0) return(NULL)
    result <- terra::mosaic(terra::sprc(result))
  }
  result
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
  chm <- rasterize_canopy(voxels, res = parameters$chm_resolution, algorithm = p2r())
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

build_tile_row <- function(point_cloud_name, tile, edge_tile, metrics) {
  bounds <- st_bbox(tile)
  as.data.table(c(list(
    point_cloud = point_cloud_name,
    tile_id = tile$tile_id[[1]],
    tile_xmin = as.numeric(bounds[["xmin"]]),
    tile_ymin = as.numeric(bounds[["ymin"]]),
    edge_tile = edge_tile
  ), metrics))
}

main <- function() {
  parameters <- parse_parameters()
  aoi <- read_inclusion_aoi(parameters$aoi)
  tiles <- build_optimized_tiles(
    aoi,
    parameters$tile_size,
    parameters$grid_search_step
  )
  message(sprintf("Optimized grid contains %d complete Analysis Tiles", nrow(tiles)))

  dtm <- build_global_dtm(
    parameters$point_cloud,
    parameters$chunk_size,
    parameters$dtm_buffer,
    parameters$dtm_resolution,
    parameters$ptd_resolution
  )
  if (is.null(dtm)) stop("global DTM generation produced no raster")

  edge_flags <- compute_edge_flags(tiles, parameters$tile_size)
  rows <- lapply(seq_len(nrow(tiles)), function(index) {
    metrics <- calculate_tile_metrics(
      parameters$point_cloud,
      tiles[index, ],
      dtm,
      parameters
    )
    build_tile_row(
      basename(parameters$point_cloud),
      tiles[index, ],
      edge_flags[[index]],
      metrics
    )
  })
  result <- if (length(rows)) {
    rbindlist(rows, use.names = TRUE, fill = TRUE)
  } else {
    as.data.table(build_tile_row(
      basename(parameters$point_cloud),
      st_sf(tile_id = NA_integer_, geometry = st_sfc(st_polygon(), crs = NA)),
      NA,
      empty_metric_values(NA_integer_)
    ))[0]
  }

  output_path <- file.path(parameters$output_dir, "forest_structure_tiles.csv")
  fwrite(result, output_path, na = "NA")
  message(sprintf("Wrote %d Analysis Tile rows to %s", nrow(result), output_path))
}

tryCatch(
  main(),
  error = function(error) {
    message("forest-structure analysis failed: ", conditionMessage(error))
    quit(status = 1)
  }
)

