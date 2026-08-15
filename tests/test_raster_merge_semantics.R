local({
  work_directory <- tempfile("foreststructure_vrt_test_")
  dir.create(work_directory)
  on.exit(unlink(work_directory, recursive = TRUE, force = TRUE), add = TRUE)

  write_test_raster <- function(name, values, crs = "") {
    path <- file.path(work_directory, paste0(name, ".tif"))
    raster <- terra::rast(xmin = 0, xmax = 2, ymin = 0, ymax = 1, res = 1)
    terra::values(raster) <- values
    if (nzchar(crs)) terra::crs(raster) <- crs
    terra::writeRaster(raster, path, overwrite = TRUE)
    path
  }

  first_path <- write_test_raster("first", c(1, 1))
  second_path <- write_test_raster("second", c(3, 3))
  empty_no_crs_path <- write_test_raster(
    "empty_no_crs",
    c(NA_real_, NA_real_)
  )
  empty_path <- write_test_raster(
    "empty",
    c(NA_real_, NA_real_),
    "EPSG:4326"
  )
  empty_raster <- terra::rast(empty_path)

  result <- build_chunk_virtual_raster(
    list(first_path, second_path, empty_path),
    work_directory,
    "TEST"
  )

  # The CHM path preserves lidR 4.3.2's disk-backed GDAL VRT semantics. Later
  # populated chunk rasters win in overlaps; CHM values must never be averaged.
  stopifnot(!terra::inMemory(result))
  stopifnot(identical(as.numeric(terra::values(result)), c(3, 3)))
  stopifnot(!any(as.numeric(terra::values(result)) == 2))
  stopifnot(terra::same.crs(result, empty_raster))

  empty_result <- build_chunk_virtual_raster(
    list(empty_no_crs_path, empty_path),
    work_directory,
    "EMPTY"
  )
  stopifnot(!terra::inMemory(empty_result))
  stopifnot(all(is.na(as.numeric(terra::values(empty_result)))))

  fallback_result <- build_chunk_virtual_raster(
    list(first_path, second_path),
    work_directory,
    "FALLBACK",
    terra::crs(empty_raster)
  )
  stopifnot(!terra::inMemory(fallback_result))
  stopifnot(terra::same.crs(fallback_result, empty_raster))
  point_cloud_path <- file.path(work_directory, "fallback_bounds.las")
  point_cloud <- LAS(data.frame(
    X = c(0.25, 1.75),
    Y = c(0.25, 0.75),
    Z = c(1, 2)
  ))
  writeLAS(point_cloud, point_cloud_path)
  covering_fallback <- cover_virtual_raster(
    fallback_result,
    point_cloud_path,
    1,
    work_directory,
    "FALLBACK"
  )
  streamed_fallback_path <- file.path(work_directory, "fallback_streamed.tif")
  stream_virtual_raster(
    covering_fallback,
    streamed_fallback_path,
    "FALLBACK"
  )
  streamed_fallback <- terra::rast(streamed_fallback_path)
  stopifnot(terra::same.crs(streamed_fallback, empty_raster))

  conflicting_path <- write_test_raster(
    "conflicting",
    c(NA_real_, NA_real_),
    "EPSG:3857"
  )
  conflicting <- tryCatch(
    {
      build_chunk_virtual_raster(
        list(empty_path, conflicting_path),
        work_directory,
        "CONFLICTING"
      )
      FALSE
    },
    error = function(error) grepl(
      "conflicting CRS metadata",
      conditionMessage(error),
      fixed = TRUE
    )
  )
  stopifnot(conflicting)
})
