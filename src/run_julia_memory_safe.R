suppressPackageStartupMessages({
  library(argparse)
  library(jsonlite)
  library(lidR)
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
Sys.setenv(FORESTSTRUCTURE_SOURCE_ONLY = "1")
source(file.path(script_directory, "run.R"))
source(file.path(script_directory, "aoi_conversion.R"))

parse_julia_memory_safe_parameters <- function() {
  parser <- ArgumentParser(
    description = paste(
      "Julia-faithful ForestStructure analysis with selective ExtraBytes",
      "and disk-backed memory guards"
    )
  )
  parser$add_argument("--point-cloud", required = TRUE)
  parser$add_argument("--aoi-geojson", required = TRUE)
  parser$add_argument("--dataset-id", required = TRUE, type = "integer")
  parser$add_argument("--output-dir", required = TRUE)
  parser$add_argument("--temp-dir", required = TRUE)
  parser$add_argument("--memory-budget-gib", type = "double", default = 60)
  parser$add_argument("--sensor", default = "NA")
  parser$add_argument("--country", default = "NA")
  parser$add_argument(
    "--instance-dimension",
    action = "append",
    default = NULL
  )
  arguments <- parser$parse_args()
  raw_instance_dimensions <- unlist(
    arguments$instance_dimension,
    recursive = TRUE,
    use.names = FALSE
  )
  if (is.null(raw_instance_dimensions) ||
      length(raw_instance_dimensions) == 0L ||
      all(is.na(raw_instance_dimensions))) {
    arguments$instance_dimension <- c(
      "PredInstance",
      "PredInstance_SAT",
      "PredInstance_FM"
    )
  } else {
    raw_instance_dimensions <- raw_instance_dimensions[
      !is.na(raw_instance_dimensions)
    ]
    arguments$instance_dimension <- unique(trimws(unlist(strsplit(
      as.character(raw_instance_dimensions),
      ",",
      fixed = TRUE
    ))))
    arguments$instance_dimension <- arguments$instance_dimension[
      nzchar(arguments$instance_dimension)
    ]
  }
  if (!file.exists(arguments$point_cloud) ||
      !grepl("\\.la[sz]$", arguments$point_cloud, ignore.case = TRUE)) {
    stop("--point-cloud must be exactly one existing LAS/LAZ file")
  }
  if (grepl("\\.copc\\.laz$", arguments$point_cloud, ignore.case = TRUE)) {
    stop("Julia-faithful analysis requires the original LAZ, never a COPC")
  }
  if (!file.exists(arguments$aoi_geojson) ||
      !grepl("\\.(geojson|json)$", arguments$aoi_geojson, ignore.case = TRUE)) {
    stop("--aoi-geojson must be exactly one existing GeoJSON file")
  }
  if (!is.finite(arguments$dataset_id) || arguments$dataset_id < 1) {
    stop("--dataset-id must be a positive integer")
  }
  for (directory in c(arguments$output_dir, arguments$temp_dir)) {
    if (!dir.exists(directory) || file.access(directory, mode = 2) != 0) {
      stop("output and temporary directories must exist and be writable")
    }
  }
  if (!is.finite(arguments$memory_budget_gib) ||
      arguments$memory_budget_gib <= 0 ||
      arguments$memory_budget_gib > 60) {
    stop("--memory-budget-gib must be greater than zero and at most 60")
  }
  arguments
}

extra_byte_definitions <- function(point_cloud) {
  header <- readLASheader(point_cloud)
  descriptions <- header@VLR$Extra_Bytes[["Extra Bytes Description"]]
  if (is.null(descriptions)) return(list())
  lapply(seq_along(descriptions), function(index) {
    description <- descriptions[[index]]
    list(
      name = as.character(description$name),
      ordinal = index,
      data_type = as.integer(description$data_type)
    )
  })
}

run_projection <- function(source, output, dimension) {
  output_lines <- system2(
    "python3",
    c(
      file.path(script_directory, "project_instance_dimension.py"),
      "--source", source,
      "--output", output,
      "--dimension", dimension
    ),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(output_lines, "status")
  if (!is.null(status) && status != 0L) {
    stop(sprintf(
      "streaming projection failed for %s: %s",
      dimension,
      paste(output_lines, collapse = " ")
    ))
  }
  fromJSON(tail(output_lines, 1L), simplifyVector = FALSE)
}

expected_artifacts <- function(directory, dataset_id, dimensions) {
  prefix <- file.path(directory, as.character(dataset_id))
  common <- c(
    paste0(prefix, "_dtm.tif"),
    paste0(prefix, "_chm.tif"),
    paste0(prefix, "_tiles.png"),
    paste0(prefix, "_performance.csv"),
    paste0(prefix, "_aoi_conversion.json"),
    paste0(prefix, "_julia_memory_safe_run.json")
  )
  suffixes <- if (length(dimensions) == 0L) "" else paste0("_", dimensions)
  dimension_files <- unlist(lapply(suffixes, function(suffix) c(
    paste0(prefix, suffix, "_results.csv"),
    paste0(prefix, suffix, "_segment_diagnostics.csv"),
    paste0(prefix, suffix, "_tiles.geojson")
  )))
  c(common, dimension_files)
}

validate_incoming_artifacts <- function(directory, dataset_id, dimensions,
                                        memory_budget_gib, source_point_count,
                                        point_cloud_name, sensor, country) {
  matches_label <- function(values, expected) {
    if (identical(expected, "NA")) {
      return(all(is.na(values) | as.character(values) == "NA"))
    }
    all(!is.na(values) & as.character(values) == expected)
  }
  paths <- expected_artifacts(directory, dataset_id, dimensions)
  absent <- paths[!file.exists(paths) | file.info(paths)$size <= 0]
  if (length(absent) > 0L) {
    stop(sprintf(
      "incoming artifact validation failed; missing/empty: %s",
      paste(basename(absent), collapse = ", ")
    ))
  }
  performance <- fread(
    file.path(directory, paste0(dataset_id, "_performance.csv"))
  )
  if (nrow(performance) != 1L ||
      performance$point_count[[1]] != source_point_count ||
      !is.finite(performance$peak_rss_mib[[1]]) ||
      performance$peak_rss_mib[[1]] >= memory_budget_gib * 1024 ||
      !is.finite(performance$cgroup_memory_peak_mib[[1]]) ||
      performance$cgroup_memory_peak_mib[[1]] >= memory_budget_gib * 1024 ||
      !is.finite(performance$temporary_disk_peak_mib[[1]])) {
    stop("incoming artifact validation failed: performance/resource checks failed")
  }
  dtm <- terra::rast(file.path(directory, paste0(dataset_id, "_dtm.tif")))
  chm <- terra::rast(file.path(directory, paste0(dataset_id, "_chm.tif")))
  if (terra::inMemory(dtm) || terra::inMemory(chm) ||
      any(abs(terra::res(dtm) - c(1, 1)) > 1e-9) ||
      any(abs(terra::res(chm) - c(0.5, 0.5)) > 1e-9) ||
      !identical(terra::crs(dtm), terra::crs(chm))) {
    stop("incoming raster resolution, storage mode, or CRS validation failed")
  }
  for (dimension in dimensions) {
    results <- fread(file.path(
      directory,
      sprintf("%s_%s_results.csv", dataset_id, dimension)
    ))
    diagnostics <- fread(file.path(
      directory,
      sprintf("%s_%s_segment_diagnostics.csv", dataset_id, dimension)
    ))
    required_results <- names(empty_result_table())
    required_diagnostics <- names(empty_segment_diagnostics())
    if (!identical(names(results), required_results) ||
        !identical(names(diagnostics), required_diagnostics)) {
      stop(sprintf(
        "incoming CSV schema differs from Julia for %s",
        dimension
      ))
    }
    if (nrow(results) != performance$tile_count[[1]] ||
        any(results$file != point_cloud_name) ||
        !matches_label(results$sensor, sensor) ||
        !matches_label(results$country, country) ||
        any(diagnostics$file != point_cloud_name) ||
        !matches_label(diagnostics$sensor, sensor) ||
        !matches_label(diagnostics$country, country)) {
      stop(sprintf(
        "incoming row count or metadata validation failed for %s",
        dimension
      ))
    }
    tile_features <- st_read(
      file.path(
        directory,
        sprintf("%s_%s_tiles.geojson", dataset_id, dimension)
      ),
      quiet = TRUE,
      stringsAsFactors = FALSE
    )
    if (nrow(tile_features) != nrow(results)) {
      stop(sprintf("incoming tile GeoJSON row count differs for %s", dimension))
    }
  }
  invisible(paths)
}

promote_artifacts <- function(incoming_directory, output_directory, dataset_id) {
  incoming <- list.files(
    incoming_directory,
    full.names = TRUE,
    recursive = FALSE,
    all.files = FALSE
  )
  prefix_pattern <- sprintf("^%s(_|\\.)", dataset_id)
  existing <- list.files(
    output_directory,
    pattern = prefix_pattern,
    full.names = TRUE,
    recursive = FALSE,
    all.files = FALSE
  )
  backup_directory <- tempfile(
    pattern = sprintf(".backup_%s_", dataset_id),
    tmpdir = output_directory
  )
  dir.create(backup_directory)
  promoted <- character()
  success <- FALSE
  on.exit({
    if (!success) {
      unlink(promoted, force = TRUE)
      backup <- list.files(backup_directory, full.names = TRUE)
      for (path in backup) {
        file.rename(path, file.path(output_directory, basename(path)))
      }
    }
    unlink(backup_directory, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  for (path in existing) {
    if (!file.rename(path, file.path(backup_directory, basename(path)))) {
      stop(sprintf("cannot stage existing artifact %s for replacement", path))
    }
  }
  for (path in incoming) {
    target <- file.path(output_directory, basename(path))
    if (!file.rename(path, target)) {
      stop(sprintf("cannot atomically promote %s", basename(path)))
    }
    promoted <- c(promoted, target)
  }
  success <- TRUE
  invisible(promoted)
}

package_versions <- function() {
  packages <- c(
    "lidR", "data.table", "sf", "terra", "rlas", "future", "argparse",
    "jsonlite"
  )
  as.list(setNames(
    vapply(packages, function(package) {
      as.character(packageVersion(package))
    }, character(1)),
    packages
  ))
}

python_package_versions <- function() {
  output <- system2(
    "python3",
    c(
      "-c",
      shQuote(
        paste(
          "import importlib.metadata as m;",
          "print(m.version('laspy'));",
          "print(m.version('lazrs'))"
        )
      )
    ),
    stdout = TRUE
  )
  list(laspy = output[[1]], lazrs = output[[2]])
}

julia_memory_safe_main <- function() {
  arguments <- parse_julia_memory_safe_parameters()
  message("FORESTSTRUCTURE_STAGE stage=preflight status=started")
  point_cloud <- normalizePath(arguments$point_cloud, mustWork = TRUE)
  aoi_geojson <- normalizePath(arguments$aoi_geojson, mustWork = TRUE)
  input_sha256 <- sha256_file(point_cloud)
  job_directory <- tempfile(
    pattern = sprintf("foreststructure_%s_", arguments$dataset_id),
    tmpdir = arguments$temp_dir
  )
  incoming_directory <- tempfile(
    pattern = sprintf(".incoming_%s_", arguments$dataset_id),
    tmpdir = arguments$output_dir
  )
  dir.create(job_directory, recursive = TRUE)
  dir.create(incoming_directory)
  on.exit({
    unlink(job_directory, recursive = TRUE, force = TRUE)
    unlink(incoming_directory, recursive = TRUE, force = TRUE)
  }, add = TRUE)

  staged_point_cloud <- file.path(job_directory, basename(point_cloud))
  if (!file.symlink(point_cloud, staged_point_cloud)) {
    stop("cannot stage original point cloud by local-SSD symbolic link")
  }
  lax_path <- sub("\\.la[sz]$", ".lax", staged_point_cloud, ignore.case = TRUE)
  tryCatch(
    rlas::writelax(staged_point_cloud),
    error = function(error) message(
      "Spatial-index creation failed; continuing with selective scans: ",
      conditionMessage(error)
    )
  )
  if (file.exists(lax_path)) {
    message(sprintf("Built local spatial index %s", basename(lax_path)))
  }

  message("FORESTSTRUCTURE_STAGE stage=aoi_conversion status=started")
  generated_gpkg <- file.path(
    job_directory,
    paste0(tools::file_path_sans_ext(basename(point_cloud)), ".gpkg")
  )
  aoi_provenance <- convert_geojson_to_gpkg(
    aoi_geojson,
    generated_gpkg,
    point_cloud_xy_bounds(staged_point_cloud),
    tile_threads = 1L
  )
  write_json(
    aoi_provenance,
    file.path(
      incoming_directory,
      paste0(arguments$dataset_id, "_aoi_conversion.json")
    ),
    auto_unbox = TRUE,
    pretty = TRUE
  )
  message("FORESTSTRUCTURE_STAGE stage=aoi_conversion status=completed")

  message("FORESTSTRUCTURE_STAGE stage=dimension_projection status=started")
  definitions <- extra_byte_definitions(staged_point_cloud)
  available <- vapply(definitions, function(definition) {
    definition$name
  }, character(1))
  dimensions <- arguments$instance_dimension[
    arguments$instance_dimension %in% available
  ]
  missing <- setdiff(arguments$instance_dimension, dimensions)
  if (length(missing) > 0L) {
    message(sprintf(
      "Skipping missing Instance Dimensions: %s",
      paste(missing, collapse = ", ")
    ))
  }

  dimension_sources <- list()
  selectors <- list()
  projections <- list()
  for (dimension in dimensions) {
    ordinal <- match(dimension, available)
    definition <- definitions[[ordinal]]
    if (ordinal <= 9L) {
      dimension_sources[[dimension]] <- staged_point_cloud
      selector <- paste0("xyz", ordinal)
    } else {
      projection_path <- file.path(
        job_directory,
        sprintf("%s_%s_projected.laz", arguments$dataset_id, dimension)
      )
      projections[[dimension]] <- run_projection(
        staged_point_cloud,
        projection_path,
        dimension
      )
      dimension_sources[[dimension]] <- projection_path
      selector <- "xyz1"
    }
    selectors[[dimension]] <- list(
      requested_dimension = dimension,
      source_ordinal = ordinal,
      source_data_type = definition$data_type,
      effective_selector = selector
    )
    message(sprintf(
      "SELECTOR phase=segment dimension=%s ordinal=%d selector=%s",
      dimension,
      ordinal,
      selector
    ))
  }
  message("SELECTOR phase=dtm selector=xyz")
  message("SELECTOR phase=tile selector=xyz")
  message("FORESTSTRUCTURE_STAGE stage=dimension_projection status=completed")

  thread_count <- suppressWarnings(as.integer(Sys.getenv(
    "FORESTSTRUCTURE_THREADS",
    "20"
  )))
  if (!is.finite(thread_count) || thread_count < 1L) thread_count <- 20L
  catalog_worker_count <- validated_catalog_worker_count(
    Sys.getenv("FORESTSTRUCTURE_CATALOG_WORKERS", "1"),
    thread_count
  )
  message(sprintf(
    "Using validated Julia-memory-safe catalog worker count: %d",
    catalog_worker_count
  ))
  segment_bucket_count <- suppressWarnings(as.integer(Sys.getenv(
    "FORESTSTRUCTURE_SEGMENT_BUCKET_COUNT",
    as.character(SEGMENT_BUCKET_COUNT)
  )))
  if (!is.finite(segment_bucket_count) ||
      segment_bucket_count < 1L ||
      segment_bucket_count > 65536L) {
    stop("FORESTSTRUCTURE_SEGMENT_BUCKET_COUNT must be an integer from 1 to 65536")
  }
  parameters <- list(
    point_cloud = staged_point_cloud,
    dataset_id = arguments$dataset_id,
    aoi = generated_gpkg,
    output_dir = incoming_directory,
    temp_dir = job_directory,
    tile_size = 20,
    grid_search_step = 0.5,
    ptd_resolution = 20,
    dtm_resolution = 1,
    maximum_height = 70,
    voxel_resolution = 0.2,
    vegetation_minimum_height = 0.5,
    chm_resolution = 0.5,
    gap_height_threshold = 3,
    dtm_chunk_size = 60,
    chunk_size = 60,
    dtm_buffer = 20,
    threads = thread_count,
    catalog_workers = catalog_worker_count,
    performance_report = TRUE,
    instance_dimension = arguments$instance_dimension,
    segment_diagnostics = TRUE,
    minimum_tree_voxels = 100L,
    apex_minimum_height = 3,
    minimum_tree_thickness = 0.5,
    minimum_occupied_layers = 3L,
    sensor = arguments$sensor,
    country = arguments$country,
    memory_budget_gib = arguments$memory_budget_gib,
    sequential_instance_dimensions = TRUE,
    segment_catalog_base_selection = JULIA_MEMORY_SAFE_SEGMENT_SELECTION,
    segment_bucket_count = segment_bucket_count,
    dimension_point_clouds = dimension_sources,
    point_cloud_display_name = basename(point_cloud)
  )
  message("FORESTSTRUCTURE_STAGE stage=analysis status=started")
  run_analysis(parameters)
  message("FORESTSTRUCTURE_STAGE stage=analysis status=completed")
  performance <- fread(file.path(
    incoming_directory,
    paste0(arguments$dataset_id, "_performance.csv")
  ))
  temporary_disk_peak_mib <- performance$temporary_disk_peak_mib[[1]] +
    temporary_directory_bytes(job_directory) / 1024^2

  run_provenance <- list(
    status = "candidate",
    mode = "julia-memory-safe",
    rerun_policy = "always_recompute_then_replace_after_validation",
    source_point_cloud = normalizePath(point_cloud, mustWork = TRUE),
    source_point_cloud_sha256 = input_sha256,
    source_point_count = point_count_from_las_header(point_cloud),
    source_is_copc = FALSE,
    requested_instance_dimensions = arguments$instance_dimension,
    processed_instance_dimensions = dimensions,
    missing_instance_dimensions = missing,
    extra_byte_definitions = definitions,
    selectors = selectors,
    projections = projections,
    catalog_workers = catalog_worker_count,
    data_table_threads = DATA_TABLE_THREADS,
    segment_bucket_count = segment_bucket_count,
    memory_budget_gib = arguments$memory_budget_gib,
    parent_peak_rss_mib = performance$peak_rss_mib[[1]],
    cgroup_memory_peak_mib = performance$cgroup_memory_peak_mib[[1]],
    temporary_disk_peak_mib = temporary_disk_peak_mib,
    scientific_parameters = list(
      tile_size = 20,
      grid_search_step = 0.5,
      ptd_resolution = 20,
      dtm_resolution = 1,
      dtm_chunk_size = 60,
      dtm_buffer = 20,
      segment_chunk_size = 60,
      voxel_resolution = 0.2,
      maximum_height = 70,
      vegetation_minimum_height = 0.5,
      chm_resolution = 0.5,
      gap_height_threshold = 3,
      minimum_tree_voxels = 100,
      apex_minimum_height = 3,
      minimum_tree_thickness = 0.5,
      minimum_occupied_layers = 3,
      classify_ground_last_returns = FALSE
    ),
    package_versions = package_versions(),
    python_package_versions = python_package_versions()
  )
  write_json(
    run_provenance,
    file.path(
      incoming_directory,
      paste0(arguments$dataset_id, "_julia_memory_safe_run.json")
    ),
    auto_unbox = TRUE,
    pretty = TRUE,
    null = "null"
  )
  message("FORESTSTRUCTURE_STAGE stage=internal_validation status=started")
  validate_incoming_artifacts(
    incoming_directory,
    arguments$dataset_id,
    dimensions,
    arguments$memory_budget_gib,
    point_count_from_las_header(point_cloud),
    basename(point_cloud),
    arguments$sensor,
    arguments$country
  )
  message("FORESTSTRUCTURE_STAGE stage=internal_validation status=completed")
  run_provenance$status <- "valid"
  write_json(
    run_provenance,
    file.path(
      incoming_directory,
      paste0(arguments$dataset_id, "_julia_memory_safe_run.json")
    ),
    auto_unbox = TRUE,
    pretty = TRUE,
    null = "null"
  )
  message("FORESTSTRUCTURE_STAGE stage=artifact_promotion status=started")
  promoted <- promote_artifacts(
    incoming_directory,
    arguments$output_dir,
    arguments$dataset_id
  )
  message("FORESTSTRUCTURE_STAGE stage=artifact_promotion status=completed")
  message(sprintf(
    "Validated and promoted %d freshly recomputed artifact(s) for dataset %s",
    length(promoted),
    arguments$dataset_id
  ))
  invisible(promoted)
}

tryCatch(
  julia_memory_safe_main(),
  error = function(error) {
    message("julia-memory-safe analysis failed: ", conditionMessage(error))
    quit(status = 1)
  }
)
