suppressPackageStartupMessages({
  # jsonlite writes durable machine-readable comparison evidence.
  library(jsonlite)
  # terra reads raster geometry, masks, and cells using the production stack.
  library(terra)
})

# Accept one label, oracle TIFF, candidate TIFF, and report path.
arguments <- commandArgs(trailingOnly = TRUE)
# Reject ambiguous invocation before opening potentially large rasters.
if (length(arguments) != 4L) {
  stop(
    "usage: compare_valid_updated_raster.R LABEL EXPECTED_TIF ACTUAL_TIF REPORT_JSON"
  )
}

# The label distinguishes DTM from CHM in messages and JSON.
label <- arguments[[1]]
# Open both TIFFs lazily; terra does not need to materialize geometry metadata.
expected <- rast(arguments[[2]])
actual <- rast(arguments[[3]])
# Scientific parity requires identical CRS, extent, dimensions, and resolution
# before cell indices can be compared meaningfully.
geometry_equal <- compareGeom(
  expected,
  actual,
  crs = TRUE,
  ext = TRUE,
  rowcol = TRUE,
  res = TRUE,
  stopOnError = FALSE
)
# Stop immediately on geometry mismatch because cells no longer correspond.
if (!isTRUE(geometry_equal)) {
  stop(sprintf("%s geometry differs from valid_updated", label))
}

# Read cell vectors in terra's deterministic raster order.
expected_values <- values(expected, mat = FALSE)
actual_values <- values(actual, mat = FALSE)
# Compare NA masks independently: NA-versus-value is a scientific difference.
expected_na <- is.na(expected_values)
actual_na <- is.na(actual_values)
mask_equal <- identical(expected_na, actual_na)
# Numeric comparisons apply only where both rasters have populated values.
comparable <- !expected_na & !actual_na
# Use exact inequality; the acceptance contract deliberately has zero tolerance.
differing <- which(expected_values[comparable] != actual_values[comparable])
# Retain magnitude diagnostics for failures without weakening the verdict.
absolute_differences <- abs(
  expected_values[comparable] - actual_values[comparable]
)
# Both the populated mask and every mutually populated value must match.
valid <- mask_equal && length(differing) == 0L
# Assemble full geometry/cell evidence for review and automated parsing.
report <- list(
  status = if (valid) "valid" else "invalid",
  label = label,
  comparison = "zero-tolerance cell equality",
  geometry_equal = TRUE,
  cells = ncell(expected),
  expected_populated_cells = sum(!expected_na),
  actual_populated_cells = sum(!actual_na),
  differing_mask_cells = sum(expected_na != actual_na),
  differing_cells = length(differing),
  # Empty comparable sets have a defined zero difference summary.
  mean_absolute_difference = if (length(absolute_differences)) {
    mean(absolute_differences)
  } else {
    0
  },
  maximum_absolute_difference = if (length(absolute_differences)) {
    max(absolute_differences)
  } else {
    0
  },
  resolution = as.numeric(res(expected))
)
# Write the report before failing so mismatches remain diagnosable.
write_json(report, arguments[[4]], auto_unbox = TRUE, pretty = TRUE)
# A nonzero exit propagates through the shell acceptance harness.
if (!valid) {
  stop(sprintf(
    paste0(
      "%s differs from valid_updated in %d mask cell(s) and ",
      "%d mutually populated cell(s)"
    ),
    label, sum(expected_na != actual_na), length(differing)
  ))
}
# Emit one concise success line while counts/details remain in JSON.
message(sprintf(
  "%s valid_updated alignment passed: %d cells, zero differences",
  label,
  ncell(expected)
))
