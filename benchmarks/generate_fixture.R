suppressPackageStartupMessages({
  library(lidR)
  library(sf)
})

arguments <- commandArgs(trailingOnly = TRUE)
if (length(arguments) != 4) {
  stop("usage: generate_fixture.R OUTPUT.laz AOI.geojson POINT_COUNT AOI_WIDTH_METRES")
}

output_path <- arguments[[1]]
aoi_path <- arguments[[2]]
point_count <- as.integer(arguments[[3]])
aoi_width <- as.numeric(arguments[[4]])
if (!is.finite(point_count) || point_count < 1000) stop("POINT_COUNT must be at least 1000")
if (!is.finite(aoi_width) || aoi_width < 20) stop("AOI_WIDTH_METRES must be at least 20")

set.seed(1577 + point_count)
origin_x <- 306000
origin_y <- 5094000
aoi_xmin <- origin_x + 10
aoi_ymin <- origin_y + 10

ground <- expand.grid(
  X = seq(origin_x, origin_x + aoi_width + 20, by = 2),
  Y = seq(origin_y, origin_y + aoi_width + 20, by = 2)
)
ground$Z <- 180 + (ground$X - origin_x) * 0.01 +
  (ground$Y - origin_y) * 0.006

canopy_count <- point_count - nrow(ground)
if (canopy_count < 1) stop("POINT_COUNT is too small for the requested AOI")
canopy <- data.frame(
  X = runif(canopy_count, origin_x, origin_x + aoi_width + 20),
  Y = runif(canopy_count, origin_y, origin_y + aoi_width + 20)
)
canopy_ground <- 180 + (canopy$X - origin_x) * 0.01 +
  (canopy$Y - origin_y) * 0.006
canopy$Z <- canopy_ground + 0.7 + rbeta(canopy_count, 2, 4) * 30

points <- rbind(ground, canopy)
points$Intensity <- 100L
points$ReturnNumber <- 1L
points$NumberOfReturns <- 1L
points$Classification <- 1L
instance_id <- c(
  rep.int(0L, nrow(ground)),
  as.integer(
    floor((canopy$X - aoi_xmin) / 20) +
      100 * floor((canopy$Y - aoi_ymin) / 20) + 10001
  )
)
instance_id[instance_id <= 0] <- 1L

las <- LAS(points)
st_crs(las) <- 32632
las <- add_lasattribute(las, instance_id, "PredInstance", "Synthetic benchmark instance ID")
writeLAS(las, output_path)

ring <- matrix(c(
  aoi_xmin, aoi_ymin,
  aoi_xmin + aoi_width, aoi_ymin,
  aoi_xmin + aoi_width, aoi_ymin + aoi_width,
  aoi_xmin, aoi_ymin + aoi_width,
  aoi_xmin, aoi_ymin
), ncol = 2, byrow = TRUE)
aoi <- st_sf(
  role = "include",
  geometry = st_sfc(st_polygon(list(ring)), crs = 32632)
)
st_write(aoi, aoi_path, driver = "GeoJSON", delete_dsn = TRUE, quiet = TRUE)
