tile_worker_plan <- function(requested_threads, tile_count) {
  requested_threads <- max(1L, as.integer(requested_threads))
  list(
    process_workers = 1L,
    threads_per_worker = requested_threads
  )
}

validate_tile_rows <- function(tile_indices, rows) {
  valid_rows <- sum(vapply(
    rows,
    function(row) {
      !is.null(row) && !inherits(row, "try-error") && NROW(row) == 1L
    },
    logical(1)
  ))
  if (length(rows) != length(tile_indices) || valid_rows != length(tile_indices)) {
    stop(sprintf(
      "tile worker results incomplete: expected %d rows, received %d valid rows",
      length(tile_indices),
      valid_rows
    ))
  }
  invisible(rows)
}

collect_tile_rows <- function(
    tile_indices,
    calculate_row,
    tile_workers,
    parallel_runner = parallel::mclapply) {
  if (length(tile_indices) > 0L && tile_workers > 1L) {
    rows <- parallel_runner(
      tile_indices,
      calculate_row,
      mc.cores = tile_workers,
      mc.preschedule = FALSE,
      mc.set.seed = FALSE
    )
  } else {
    rows <- lapply(tile_indices, calculate_row)
  }
  validate_tile_rows(tile_indices, rows)
  if (length(rows)) {
    data.table::rbindlist(rows, use.names = TRUE, fill = TRUE)
  } else if (exists("empty_result_table", mode = "function", inherits = TRUE)) {
    empty_result_table()
  } else {
    data.table::data.table()
  }
}
