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
    help = "Path to one GeoJSON or GeoPackage Audit AOI"
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
  parser$add_argument(
    "--instance-dimension", "--instance_dimension",
    action = "append",
    default = NULL,
    help = paste(
      "Ordered instance-ID dimension candidate; repeat the option or provide",
      "comma-separated names. Defaults to PredInstance, PredInstance_SAT,",
      "PredInstance_FM, treeID"
    )
  )
  parser$add_argument(
    "--segment-diagnostics", "--segment_diagnostics",
    action = "store_true",
    default = FALSE,
    help = "Write segment_diagnostics.csv (disabled by default)"
  )
  parser$add_argument(
    "--minimum-tree-voxels", "--minimum_tree_voxels",
    type = "integer",
    default = 100
  )
  parser$add_argument(
    "--apex-minimum-height", "--apex_minimum_height",
    type = "double",
    default = 3
  )
  parser$add_argument(
    "--minimum-tree-thickness", "--minimum_tree_thickness",
    type = "double",
    default = 0.5
  )
  parser$add_argument(
    "--minimum-occupied-layers", "--minimum_occupied_layers",
    type = "integer",
    default = 3
  )
  args <- parser$parse_args()

  raw_instance_dimensions <- unlist(
    args$instance_dimension,
    recursive = TRUE,
    use.names = FALSE
  )
  if (is.null(raw_instance_dimensions) || length(raw_instance_dimensions) == 0) {
    args$instance_dimension <- c(
      "PredInstance", "PredInstance_SAT", "PredInstance_FM", "treeID"
    )
  } else {
    candidates <- trimws(unlist(strsplit(
      as.character(raw_instance_dimensions),
      ",",
      fixed = TRUE
    )))
    args$instance_dimension <- unique(candidates[nzchar(candidates)])
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
  if (!file.exists(args$aoi) || dir.exists(args$aoi)) {
    stop("--aoi must be exactly one existing GeoJSON or GeoPackage file")
  }
  if (!grepl("\\.(geojson|json|gpkg)$", args$aoi, ignore.case = TRUE)) {
    stop("--aoi must have a .geojson, .json, or .gpkg extension")
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
  unknown <- unique(roles[!roles %in% c("include", "exclude")])
  if (length(unknown) > 0) {
    stop(sprintf("Audit AOI contains unsupported feature role(s): %s", paste(unknown, collapse = ", ")))
  }
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
  list(inclusion = inclusion, exclusion = exclusion, usable = usable)
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

segment_chunk <- function(chunk, dtm, voxel_resolution, maximum_height,
                          instance_dimension) {
  las <- readLAS(chunk)
  if (is.empty(las) || !instance_dimension %in% names(las@data)) return(NULL)
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

accumulate_segments <- function(point_cloud, dtm, chunk_size,
                                voxel_resolution, maximum_height,
                                instance_dimension) {
  catalog <- readLAScatalog(point_cloud)
  opt_chunk_size(catalog) <- chunk_size
  opt_chunk_buffer(catalog) <- 0
  opt_select(catalog) <- "*"
  opt_progress(catalog) <- FALSE
  chunks <- catalog_apply(
    catalog,
    segment_chunk,
    dtm = dtm,
    voxel_resolution = voxel_resolution,
    maximum_height = maximum_height,
    instance_dimension = instance_dimension,
    .options = list(automerge = FALSE)
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
  plot(
    aoi$inclusion,
    col = adjustcolor("#2e8b57", alpha.f = 0.12),
    border = "#17633b",
    lwd = 3,
    axes = TRUE,
    asp = 1,
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
  legend(
    "bottomright",
    legend = c("Audit AOI", "Exclusion", "Edge tile", "Interior tile"),
    col = c("#17633b", "#991b1b", "#f59e0b", "#2563eb"),
    lwd = c(3, 2, 2, 2),
    bg = "white"
  )
  invisible(path)
}

main <- function() {
  parameters <- parse_parameters()
  aoi <- read_audit_aoi(parameters$aoi)
  tiles <- build_optimized_tiles(
    aoi$usable,
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
  dtm_path <- file.path(parameters$output_dir, "forest_structure_dtm.tif")
  writeRaster(dtm, dtm_path, overwrite = TRUE, filetype = "GTiff")

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
      dtm,
      parameters$chunk_size,
      parameters$voxel_resolution,
      parameters$maximum_height,
      instance_dimension
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

  chm_directory <- file.path(parameters$output_dir, "chm")
  if (!dir.exists(chm_directory) && !dir.create(chm_directory, recursive = TRUE)) {
    stop("could not create CHM output directory")
  }

  edge_flags <- compute_edge_flags(tiles, parameters$tile_size)
  rows <- lapply(seq_len(nrow(tiles)), function(index) {
    chm_path <- file.path(
      chm_directory,
      sprintf("tile_%06d_chm.tif", tiles$tile_id[[index]])
    )
    metrics <- calculate_tile_metrics(
      parameters$point_cloud,
      tiles[index, ],
      dtm,
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
  })
  result <- if (length(rows)) {
    rbindlist(rows, use.names = TRUE, fill = TRUE)
  } else {
    empty_result_table()
  }

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
  message(sprintf("Wrote %d Analysis Tile rows to %s", nrow(result), output_path))
}

tryCatch(
  main(),
  error = function(error) {
    message("forest-structure analysis failed: ", conditionMessage(error))
    quit(status = 1)
  }
)
