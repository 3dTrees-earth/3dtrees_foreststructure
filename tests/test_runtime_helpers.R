# Focused smoke tests for runtime configuration and degenerate DTM inputs.
# tests/test_container.sh sources the production entry point before this file.

suppressPackageStartupMessages({
  stopifnot(requireNamespace("future", quietly = TRUE))
  stopifnot(requireNamespace("geometry", quietly = TRUE))
  library(lidR)
})

stopifnot(packageVersion("lidR") == "4.3.2")
stopifnot("ptd" %in% getNamespaceExports("lidR"))

original_data_table_threads <- data.table::getDTthreads()
configure_catalog_worker()
configured_data_table_threads <- data.table::getDTthreads()
stopifnot(
  configured_data_table_threads >= 1L,
  configured_data_table_threads <= DATA_TABLE_THREADS
)
data.table::setDTthreads(original_data_table_threads)

dtm_body <- paste(deparse(body(write_global_dtm)), collapse = "\n")
stopifnot(grepl("cover_virtual_raster", dtm_body, fixed = TRUE))

original_workers <- future::nbrOfWorkers()
original_lidr_threads <- lidR::get_lidr_threads()
on.exit(lidR::set_lidr_threads(original_lidr_threads), add = TRUE)
lidR::set_lidr_threads(2L)
configured_workers <- with_catalog_workers(
  2L,
  "smoke-test",
  {
    lidR::set_lidr_threads(1L)
    future::nbrOfWorkers()
  }
)
stopifnot(configured_workers == 2L)
stopifnot(future::nbrOfWorkers() == original_workers)
stopifnot(lidR::get_lidr_threads() == 2L)

no_ground <- lidR::LAS(data.frame(
  X = c(0, 1, 0),
  Y = c(0, 0, 1),
  Z = c(10, 11, 12),
  Classification = c(1L, 1L, 1L)
))
stopifnot(is.null(classified_ground_surface(no_ground, 1)))

insufficient_ground <- lidR::LAS(data.frame(
  X = c(0, 1),
  Y = c(0, 1),
  Z = c(10, 11),
  Classification = c(2L, 2L)
))
stopifnot(is.null(classified_ground_surface(insufficient_ground, 1)))

one_point <- lidR::LAS(data.frame(X = 1, Y = 1, Z = 1))
stopifnot(!las_has_nondegenerate_xy(one_point))
nondegenerate <- lidR::LAS(data.frame(
  X = c(0, 1, 0),
  Y = c(0, 0, 1),
  Z = c(1, 1, 1)
))
stopifnot(las_has_nondegenerate_xy(nondegenerate))
