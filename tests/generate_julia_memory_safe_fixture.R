suppressPackageStartupMessages({
  library(lidR)
  library(sf)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 2L) {
  stop("usage: generate_julia_memory_safe_fixture.R OUTPUT.laz AOI.geojson")
}
set.seed(150)

ground <- expand.grid(X = seq(1000, 1040, by = 1), Y = seq(2000, 2040, by = 1))
ground$Z <- 100 + (ground$X - 1000) * 0.01 + (ground$Y - 2000) * 0.01
canopy <- data.frame(
  X = runif(12000, 1000, 1040),
  Y = runif(12000, 2000, 2040)
)
canopy$Z <- 101 + rbeta(nrow(canopy), 2, 4) * 25
points <- rbind(ground, canopy)
points$Intensity <- 100L
points$ReturnNumber <- 1L
points$NumberOfReturns <- 1L
points$Classification <- 1L
instance <- c(rep.int(0L, nrow(ground)), ifelse(canopy$X < 1020, 11L, 22L))

las <- LAS(points)
for (index in seq_len(10L)) {
  las <- add_lasattribute(
    las,
    rep.int(index, nrow(points)),
    sprintf("filler_%02d", index),
    "Unrelated synthetic ExtraByte"
  )
}
for (dimension in c("PredInstance", "PredInstance_SAT", "PredInstance_FM")) {
  las <- add_lasattribute(
    las,
    instance,
    dimension,
    "Identical synthetic instance identifier"
  )
}
writeLAS(las, arguments[[1]])

ring <- matrix(c(
  1000, 2000,
  1040, 2000,
  1040, 2040,
  1000, 2040,
  1000, 2000
), ncol = 2, byrow = TRUE)
st_write(
  st_sf(geometry = st_sfc(st_polygon(list(ring)))),
  arguments[[2]],
  driver = "GeoJSON",
  delete_dsn = TRUE,
  quiet = TRUE
)
