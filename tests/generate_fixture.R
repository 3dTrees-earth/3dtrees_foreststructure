suppressPackageStartupMessages({
  library(lidR)
  library(sf)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 1) {
  stop("usage: generate_fixture.R OUTPUT.laz")
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

points <- rbind(ground, canopy)
points$Intensity <- as.integer(100)
points$ReturnNumber <- as.integer(1)
points$NumberOfReturns <- as.integer(1)
points$Classification <- as.integer(1)

las <- LAS(points)
st_crs(las) <- 32632
writeLAS(las, arguments[[1]])

