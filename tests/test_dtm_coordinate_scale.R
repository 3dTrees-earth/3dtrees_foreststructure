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
# Preserve that first attempt, but retry the specific lidR integer-conversion
# failure seen with very fine production scales using an in-memory copy.
stopifnot(exists("tin_compatible_xy_scale", inherits = FALSE))
surface_body <- paste(deparse(body(classified_ground_surface)), collapse = "\n")
stopifnot(grepl("tin_compatible_xy_scale", surface_body, fixed = TRUE))

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

fine_ground <- expand.grid(
  X = 226990 + seq(0, 0.09, by = 0.01),
  Y = 378990 + seq(0, 0.09, by = 0.01)
)
fine_ground$Z <- 357
fine_ground$Classification <- 2L
fine_las <- LAS(fine_ground)
fine_las@header@PHB[["X scale factor"]] <- 1e-7
fine_las@header@PHB[["Y scale factor"]] <- 1e-7
fine_coordinates_before <- fine_las@data[, c("X", "Y")]
fine_scale_before <- unlist(
  fine_las@header@PHB[c("X scale factor", "Y scale factor")]
)
fine_dtm <- classified_ground_surface(fine_las, 1)
stopifnot(inherits(fine_dtm, "SpatRaster"))
stopifnot(identical(fine_las@data[, c("X", "Y")], fine_coordinates_before))
stopifnot(identical(
  unlist(fine_las@header@PHB[c("X scale factor", "Y scale factor")]),
  fine_scale_before
))
