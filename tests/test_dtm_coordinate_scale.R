ground <- expand.grid(
  X = 227000 + seq(0, 0.009, by = 0.001),
  Y = 385000 + seq(0, 0.009, by = 0.001)
)
ground$Z <- 0
ground$Classification <- 2L

las <- LAS(ground)
las@header@PHB[["X scale factor"]] <- 1e-6
las@header@PHB[["Y scale factor"]] <- 1e-6
las@header@PHB[["Z scale factor"]] <- 1e-6
las@header@PHB[["X offset"]] <- 227000
las@header@PHB[["Y offset"]] <- 385000
las@header@PHB[["Z offset"]] <- 0

dtm <- classified_ground_surface(las, 1)
stopifnot(inherits(dtm, "SpatRaster"))
