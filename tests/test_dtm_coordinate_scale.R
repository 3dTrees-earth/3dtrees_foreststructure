ground <- expand.grid(
  X = 292142 + seq(0, 0.009, by = 0.001),
  Y = 6456591 + seq(0, 0.009, by = 0.001)
)
ground$Z <- 0
ground$Classification <- 2L

las <- LAS(ground)
las <- las_reoffset(las, xoffset = 292142, yoffset = 6456591, zoffset = 0)
las <- las_rescale(las, xscale = 0.00025, yscale = 0.00025, zscale = 0.001)

# Julia's upstream implementation passes the classified LAS directly to TIN.
# Guard against reintroducing an in-memory coordinate rescaling adaptation:
# lidR 4.3.2 handles LAS scale and offset internally.
stopifnot(!exists("tin_compatible_xy_scale", inherits = FALSE))
surface_body <- paste(deparse(body(classified_ground_surface)), collapse = "\n")
stopifnot(!grepl("las_rescale|tin_compatible_xy_scale", surface_body))

coordinates_before <- las@data[, c("X", "Y")]
scale_before <- unlist(las@header@PHB[c("X scale factor", "Y scale factor")])
offset_before <- unlist(las@header@PHB[c("X offset", "Y offset")])
dtm <- classified_ground_surface(las, 1)
stopifnot(inherits(dtm, "SpatRaster"))
stopifnot(identical(las@data[, c("X", "Y")], coordinates_before))
stopifnot(identical(
  unlist(las@header@PHB[c("X scale factor", "Y scale factor")]),
  scale_before
))
stopifnot(identical(
  unlist(las@header@PHB[c("X offset", "Y offset")]),
  offset_before
))
