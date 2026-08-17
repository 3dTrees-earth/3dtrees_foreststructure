local({
  ring <- rbind(
    c(0, 0),
    c(4, 0),
    c(4, 3),
    c(0, 3),
    c(0, 0)
  )
  expected <- st_sfc(st_polygon(list(ring)), crs = NA_crs_)

  # Rotating the start or reversing the direction preserves the exact open
  # vertex inventory and must be accepted.
  rotated_ring <- rbind(ring[3:4, , drop = FALSE], ring[1:2, , drop = FALSE], ring[3, ])
  rotated <- st_sfc(st_polygon(list(rotated_ring)), crs = NA_crs_)
  reversed <- st_sfc(st_polygon(list(ring[nrow(ring):1L, ])), crs = NA_crs_)
  stopifnot(isTRUE(assert_geometry_identical(expected, rotated, "rotated")))
  stopifnot(isTRUE(assert_geometry_identical(expected, reversed, "reversed")))

  # A ring rewrite may change floating area accumulation without changing any
  # coordinate. The exact vertex and topology checks remain authoritative.
  large_ring <- ring + matrix(c(1e7, 5e6), nrow(ring), 2L, byrow = TRUE)
  large_expected <- st_sfc(st_polygon(list(large_ring)), crs = NA_crs_)
  large_reversed <- st_sfc(
    st_polygon(list(large_ring[nrow(large_ring):1L, ])),
    crs = NA_crs_
  )
  stopifnot(isTRUE(assert_geometry_identical(
    large_expected,
    large_reversed,
    "large reversed"
  )))

  # Topological equality alone would accept an extra collinear vertex. The
  # conversion gate must reject it because the coordinate inventory changed.
  extra_vertex_ring <- rbind(
    c(0, 0), c(2, 0), c(4, 0), c(4, 3), c(0, 3), c(0, 0)
  )
  extra_vertex <- st_sfc(st_polygon(list(extra_vertex_ring)), crs = NA_crs_)
  stopifnot(isTRUE(st_equals(expected, extra_vertex, sparse = FALSE)[[1, 1]]))
  extra_vertex_rejected <- tryCatch(
    {
      assert_geometry_identical(expected, extra_vertex, "extra vertex")
      FALSE
    },
    error = function(error) grepl(
      "changed normalized geometry, area, or bounds",
      conditionMessage(error),
      fixed = TRUE
    )
  )
  stopifnot(extra_vertex_rejected)

  moved_ring <- ring
  moved_ring[2L, 1L] <- 4.01
  moved <- st_sfc(st_polygon(list(moved_ring)), crs = NA_crs_)
  moved_rejected <- tryCatch(
    {
      assert_geometry_identical(expected, moved, "moved vertex")
      FALSE
    },
    error = function(error) grepl(
      "changed normalized geometry, area, or bounds",
      conditionMessage(error),
      fixed = TRUE
    )
  )
  stopifnot(moved_rejected)
})
