suppressPackageStartupMessages({
  library(lidR)
  library(sf)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 3) {
  stop("usage: generate_fixture.R OUTPUT.laz SEGMENTED_OUTPUT.laz OUTPUT.gpkg")
}

set.seed(1573)

ground <- expand.grid(
  X = seq(306675, 306725, by = 1),
  Y = seq(5094475, 5094525, by = 1)
)
ground$Z <- 178 + (ground$X - 306675) * 0.015 +
  (ground$Y - 5094475) * 0.01

canopy_count <- 12000
canopy <- data.frame(
  X = runif(canopy_count, 306675, 306725),
  Y = runif(canopy_count, 5094475, 5094525)
)
canopy_ground <- 178 + (canopy$X - 306675) * 0.015 +
  (canopy$Y - 5094475) * 0.01
canopy$Z <- canopy_ground + 0.7 + rbeta(canopy_count, 2, 4) * 24

# Give both cross-column synthetic segments a deterministic apex inside the
# audited 40 m square. The remaining points still make each segment cross an
# Analysis Tile boundary, so apex assignment can be tested without ambiguity.
south <- which(canopy$Y < 5094500)
north <- which(canopy$Y >= 5094500)
south_apex <- south[[which.min(
  (canopy$X[south] - 306695)^2 + (canopy$Y[south] - 5094495)^2
)]]
north_apex <- north[[which.min(
  (canopy$X[north] - 306705)^2 + (canopy$Y[north] - 5094505)^2
)]]
canopy$Z[c(south_apex, north_apex)] <-
  canopy_ground[c(south_apex, north_apex)] + c(31, 32)

points <- rbind(ground, canopy)
points$Intensity <- as.integer(100)
points$ReturnNumber <- as.integer(1)
points$NumberOfReturns <- as.integer(1)
points$Classification <- as.integer(1)

write_fixture <- function(path, attributes = list()) {
  las <- LAS(points)
  st_crs(las) <- 32632
  for (name in names(attributes)) {
    las <- add_lasattribute(
      las,
      as.integer(attributes[[name]]),
      name,
      sprintf("Synthetic %s instance identifier", name)
    )
  }
  writeLAS(las, path)
}

write_fixture(arguments[[1]])

ground_count <- nrow(ground)
pred_instance <- c(
  rep.int(0L, ground_count),
  ifelse(canopy$Y < 5094500, 101L, 202L)
)
tree_alias <- c(rep.int(0L, ground_count), rep.int(303L, canopy_count))
write_fixture(
  arguments[[2]],
  list(PredInstance = pred_instance, TreeAlias = tree_alias)
)

ring <- function(xmin, ymin, xmax, ymax) {
  matrix(c(
    xmin, ymin,
    xmax, ymin,
    xmax, ymax,
    xmin, ymax,
    xmin, ymin
  ), ncol = 2, byrow = TRUE)
}
inclusion <- st_sf(
  role = "include",
  geometry = st_sfc(st_polygon(list(ring(306680, 5094480, 306720, 5094520))), crs = 32632)
)
exclusion <- st_sf(
  role = "exclude",
  geometry = st_sfc(st_polygon(list(ring(306681, 5094481, 306699, 5094499))), crs = 32632)
)
st_write(inclusion, arguments[[3]], layer = "include", quiet = TRUE)
st_write(exclusion, arguments[[3]], layer = "exclude", append = TRUE, quiet = TRUE)
