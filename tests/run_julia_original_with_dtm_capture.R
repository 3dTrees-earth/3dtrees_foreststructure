arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2L) {
  stop("usage: run_julia_original_with_dtm_capture.R ORIGINAL_SCRIPT DTM_TIF")
}

original_script <- normalizePath(arguments[[1]], mustWork = TRUE)
.julia_dtm_capture_path <- normalizePath(
  dirname(arguments[[2]]),
  mustWork = TRUE
)
.julia_dtm_capture_path <- file.path(
  .julia_dtm_capture_path,
  basename(arguments[[2]])
)

# Evaluate the immutable file's parsed top-level expressions in their original
# order. Immediately after its build_global_dtm() definition, add an exit-only
# tracer that serializes the returned raster without changing that return value.
# The script's AST and source file are never rewritten.
expressions <- parse(file = original_script, keep.source = TRUE)
capture_installed <- FALSE
for (expression in expressions) {
  eval(expression, envir = .GlobalEnv)
  if (!capture_installed &&
      exists("build_global_dtm", envir = .GlobalEnv, inherits = FALSE)) {
    trace(
      "build_global_dtm",
      where = .GlobalEnv,
      exit = quote({
        terra::writeRaster(
          returnValue(),
          .julia_dtm_capture_path,
          overwrite = TRUE,
          datatype = "FLT8S"
        )
      }),
      print = FALSE
    )
    capture_installed <- TRUE
  }
}

if (!capture_installed ||
    !file.exists(.julia_dtm_capture_path) ||
    file.info(.julia_dtm_capture_path)$size <= 0) {
  stop("Julia DTM capture was not written")
}
