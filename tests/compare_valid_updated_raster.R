suppressPackageStartupMessages({
  library(jsonlite)
  library(terra)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 4L) {
  stop(
    "usage: compare_valid_updated_raster.R LABEL EXPECTED_TIF ACTUAL_TIF REPORT_JSON"
  )
}

label <- arguments[[1]]
expected <- rast(arguments[[2]])
actual <- rast(arguments[[3]])
geometry_equal <- compareGeom(
  expected,
  actual,
  crs = TRUE,
  ext = TRUE,
  rowcol = TRUE,
  res = TRUE,
  stopOnError = FALSE
)
if (!isTRUE(geometry_equal)) {
  stop(sprintf("%s geometry differs from valid_updated", label))
}

expected_values <- values(expected, mat = FALSE)
actual_values <- values(actual, mat = FALSE)
expected_na <- is.na(expected_values)
actual_na <- is.na(actual_values)
mask_equal <- identical(expected_na, actual_na)
comparable <- !expected_na & !actual_na
differing <- which(expected_values[comparable] != actual_values[comparable])
absolute_differences <- abs(
  expected_values[comparable] - actual_values[comparable]
)
valid <- mask_equal && length(differing) == 0L
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
write_json(report, arguments[[4]], auto_unbox = TRUE, pretty = TRUE)
if (!valid) {
  stop(sprintf(
    paste0(
      "%s differs from valid_updated in %d mask cell(s) and ",
      "%d mutually populated cell(s)"
    ),
    label, sum(expected_na != actual_na), length(differing)
  ))
}
message(sprintf(
  "%s valid_updated alignment passed: %d cells, zero differences",
  label,
  ncell(expected)
))
