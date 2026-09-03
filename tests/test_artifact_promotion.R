local({
  root <- tempfile("artifact_promotion_")
  incoming <- file.path(root, "incoming")
  output <- file.path(root, "output")
  dir.create(incoming, recursive = TRUE)
  dir.create(output)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)

  expected <- file.path(incoming, c("2001_dtm.tif", "2001_chm.tif"))
  stopifnot(all(file.create(expected)))
  sidecars <- file.path(incoming, c(
    "2001_dtm.tif.aux.xml",
    "2001_chm.tif.partial.tif.aux.xml"
  ))
  stopifnot(all(file.create(sidecars)))
  stale_sidecar <- file.path(output, "2001_dtm.tif.aux.xml")
  stopifnot(file.create(stale_sidecar))

  promoted <- promote_artifacts(expected, output, 2001)

  stopifnot(identical(sort(basename(promoted)), sort(basename(expected))))
  stopifnot(all(file.exists(file.path(output, basename(expected)))))
  stopifnot(!any(file.exists(file.path(output, basename(sidecars)))))
  stopifnot(all(file.exists(sidecars)))
})
