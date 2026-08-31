### Strukturindizes aus LiDAR-Punktwolken - FINALE VERSION -------------------
###
###
### Phase 1 - Globales DTM:
###   Bodenklassifikation (PTD) und DTM (TIN) werden einmalig und nahtlos ueber
###   die gesamte Punktwolke gerechnet (LAScatalog-Streaming).
###
### Phase 2 - Globale Segment-Aggregation:
###   Apex und Baumfilter laufen global ueber die gesamte Wolke, gruppiert ueber
###   die eindeutige Segment-ID (PredInstance). Ein Baum, der ueber eine
###   Tile-Grenze ragt, wird vollstaendig und ohne Doppelzaehlung erfasst; die
###   Zuordnung Baum -> Tile geschieht ueber den Apex.
###
### Phase 3 - Voxel- und CHM-basierte Indizes je Tile:
###   Ein 20x20-m-Gitter wird optimal ins Polygon gelegt. Je Tile wird die Wolke
###   gegen das globale DTM hoehennormalisiert und danach voxelisiert.
###   Bodensensitive Indizes laufen auf der vegetationsbereinigten Wolke,
###   CHM-basierte Indizes behalten den Boden.
###
### Ausgabe:
###   results.csv               - Indizes je Tile
###   segment_diagnostics.csv   - eine Zeile je Segment

library(lidR)
library(sf)
library(terra)
library(data.table)

setwd("C:/Users/Julia Gäßler/Documents/Studium/Master/Masterarbeit/Indices/Data/Test2")

# ---- Eingangsordner pro Sensor ----------------------------------------------
data_dirs <- c(TLS = "TLS/",
               MLS = "MLS/",
               ULS = "ULS/")

file_tab <- do.call(rbind, lapply(names(data_dirs), function(s) {
  fs <- list.files(data_dirs[[s]], pattern = "\\.las$|\\.laz$",
                   full.names = TRUE, recursive = TRUE, ignore.case = TRUE)
  if (length(fs) == 0) return(NULL)
  sensor_base <- basename(sub("/+$", "", data_dirs[[s]]))   # "TLS"
  country     <- basename(dirname(fs))                       # Unterordner = Land
  country[country == sensor_base] <- "_root"
  data.frame(path = fs, sensor = s, country = country,
             stringsAsFactors = FALSE)
}))

if (is.null(file_tab) || nrow(file_tab) == 0)
  stop("Keine .las/.laz-Dateien in den angegebenen Ordnern gefunden: ",
       paste(data_dirs, collapse = ", "))

cat("Gefundene Dateien (Sensor x Land):\n")
print(table(file_tab$sensor, file_tab$country))

# ---- Kern-Parameter ---------------------------------------------------------
tile_size   <- 20
search_step <- 0.5   # Feinheit der Offset-Suche in m
ptd_res     <- 20    # Seed-Rasterweite (PTD), fuer Wald 20 empfohlen
dtm_res     <- 1     # Aufloesung des DTM-Rasters in m
max_height  <- 70    # feste Obergrenze in m (Ausreisser raus)

CALC_SEGMENTS <- TRUE

vox_res <- 0.2

veg_min_height <- 0.5  # bodensensitive Indizes: Punkte darunter raus

box_fixed_lower <- 0.2
boxdim_fixed    <- box_fixed_lower * 2^(0:30)
boxdim_fixed    <- boxdim_fixed[boxdim_fixed < tile_size]

chm_res          <- 0.5
height_threshold <- 3

# ---- Baum-Filter ------------------------------------------------------------
min_vox         <- 100    # Mindestzahl gefuellter Voxel
apex_min_height <- 3      # Apex muss > diese Hoehe (m)
min_thickness   <- 0.5    # m, Mindestausdehnung kleinste PCA-Hauptachse
min_zlayer      <- 3      # belegte 1-m-Hoehenschichten

# ---- LAScatalog-Parameter ---------------------------------------------------
# chunk_size steuert nur Tempo/RAM des Streamings, nicht das Ergebnis.
# dtm_buffer faengt Rand-Artefakte von PTD/TIN an den Chunk-Grenzen ab.
chunk_size <- 60
dtm_buffer <- 20

# ============================================================================
# ---- Hilfsfunktionen --------------------------------------------------------
# ============================================================================

# Gitter mit gegebenem Offset bauen (periodisch mit tile_size)
make_grid_at <- function(geom, tile_size, ox, oy) {
  bb <- st_bbox(geom)
  st_make_grid(geom, cellsize = tile_size,
               offset = c(bb["xmin"] - ox, bb["ymin"] - oy))
}

# Wie viele Tiles liegen vollstaendig im Polygon?
count_within <- function(grid, geom) sum(lengths(st_within(grid, geom)) > 0)

# Randtile-Erkennung: markiert ein Tile, wenn nicht alle acht Nachbarpositionen
# ebenfalls gueltige Tiles sind.
compute_edge_flags <- function(tiles_sf, tile_size) {
  cent <- st_coordinates(st_centroid(st_geometry(tiles_sf)))
  ix <- as.integer(round(cent[, 1] / tile_size))
  iy <- as.integer(round(cent[, 2] / tile_size))
  keyset   <- paste(ix, iy, sep = "_")
  has_tile <- function(ax, ay) paste(ax, ay, sep = "_") %in% keyset
  edge <- logical(nrow(tiles_sf))
  for (k in seq_len(nrow(tiles_sf))) {
    nb <- TRUE
    for (dx in c(-1, 0, 1)) {
      for (dy in c(-1, 0, 1)) {
        if (dx == 0 && dy == 0) next
        if (!has_tile(ix[k] + dx, iy[k] + dy)) { nb <- FALSE; break }
      }
      if (!nb) break
    }
    edge[k] <- !nb
  }
  edge
}

# Bias-korrigierter Gini-Koeffizient (Ungleichheitsmass fuer Groessen)
gini <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 2) return(NA_real_)
  if (any(x < 0)) x <- x - min(x)
  x <- sort(x)
  s <- sum(x)
  if (s == 0) return(0)
  G <- (2 * sum(seq_len(n) * x) / (n * s)) - (n + 1) / n
  G * n / (n - 1)
}

# ============================================================================
# ---- Phase 1: nahtloses globales DTM (LAScatalog) ---------------------------
# ============================================================================
# Bodenklassifikation auf der vollen Wolke, DTM per TIN. Der Catalog-Puffer wird
# von rasterize_terrain automatisch weggeschnitten -> kein Kachelsprung.

dtm_chunk_fun <- function(chunk, dtm_res, ptd_res) {
  las <- readLAS(chunk)                       # nutzt opt_select des Catalogs
  if (is.empty(las)) return(NULL)
  las <- classify_ground(las, ptd(res = ptd_res))
  rasterize_terrain(las, res = dtm_res, algorithm = tin())
}

build_global_dtm <- function(ctg, dtm_res, ptd_res, dtm_buffer) {
  opt_chunk_buffer(ctg) <- dtm_buffer
  opt_select(ctg)       <- "xyz0"             # X,Y,Z + Extrabyte 0 = PredInstance
  opt_progress(ctg)     <- FALSE              # Live-Karte aus -> schneller
  out <- catalog_apply(ctg, dtm_chunk_fun,
                       dtm_res = dtm_res, ptd_res = ptd_res,
                       .options = list(automerge = TRUE,
                                       raster_alignment = dtm_res))
  # automerge liefert je nach lidR-Version direkt ein Raster ODER eine Liste:
  if (inherits(out, "list")) {
    out <- Filter(Negate(is.null), out)
    if (length(out) == 0) return(NULL)
    out <- terra::mosaic(terra::sprc(out))
  }
  out
}

# ============================================================================
# ---- Phase 2: globale Segmente ueber die PredInstance-ID --------------------
# ============================================================================
# Pro Chunk (Puffer 0) wird die Wolke gegen das globale DTM normalisiert und je
# Instanz die eindeutige Voxelmenge + die 1-m-Schichten + ein Apex-Kandidat
# zurueckgegeben. Da die Voxel-/Schicht-Indizes global sind (floor(X/vox_res)
# etc.), vereinigen sich identische Voxel an Chunk-Grenzen sauber via unique();
# ein Puffer ist deshalb ueberfluessig und es gibt keine Doppelzaehlung.

seg_chunk_fun <- function(chunk, dtm, vox_res, max_height) {
  las <- readLAS(chunk)
  if (is.empty(las)) return(NULL)
  if (!"PredInstance" %in% names(las@data)) return(NULL)
  las <- normalize_height(las, dtm)
  dt  <- as.data.table(las@data)[PredInstance > 0 & Z >= 0 & Z <= max_height,
                                 .(X, Y, Z, PredInstance)]
  if (!nrow(dt)) return(NULL)

  # Apex-Kandidat je Instanz in DIESEM Chunk (globaler Apex spaeter)
  ap <- dt[dt[, .I[which.max(Z)], by = PredInstance]$V1,
           .(PredInstance, apex_x = X, apex_y = Y, apex_z = Z)]

  dt[, `:=`(vx = floor(X / vox_res),
            vy = floor(Y / vox_res),
            vz = floor(Z / vox_res))]

  list(
    vox  = unique(dt[, .(PredInstance, vx, vy, vz)]),
    zl   = unique(dt[, .(PredInstance, zlayer = floor(Z))]),  # 1-m-Schichten
    apex = ap
  )
}

accumulate_segments <- function(ctg, dtm, vox_res, max_height) {
  opt_chunk_buffer(ctg) <- 0                  # KEIN Puffer noetig
  opt_select(ctg)       <- "xyz0"
  opt_progress(ctg)     <- FALSE              # Live-Karte aus -> schneller
  res <- catalog_apply(ctg, seg_chunk_fun,
                       dtm = dtm, vox_res = vox_res, max_height = max_height,
                       .options = list(automerge = FALSE))
  res <- Filter(Negate(is.null), res)
  if (length(res) == 0) return(NULL)

  # Hinweis Speicher: das rbindlist + unique unten ist der RAM-Peak der
  # Pipeline. vox_all ist durch die Zahl der belegten Voxel begrenzt (also die
  # Oberflaeche der Struktur, nicht die Punktzahl).
  vox_all  <- unique(rbindlist(lapply(res, `[[`, "vox")))
  zl_all   <- unique(rbindlist(lapply(res, `[[`, "zl")))
  apex_all <- rbindlist(lapply(res, `[[`, "apex"))
  apex_all <- apex_all[apex_all[, .I[which.max(apex_z)], by = PredInstance]$V1]

  list(vox = vox_all, zl = zl_all, apex = apex_all)
}

# ---- Aus den globalen Tabellen die Segment-Kennzahlen + Filter bauen --------
finalize_seg_tab <- function(acc, vox_res,
                             min_vox, apex_min_height, min_thickness, min_zlayer) {
  vox_all  <- acc$vox
  zl_all   <- acc$zl
  apex_all <- acc$apex

  # n_vox + Volumen (vox_all ist bereits eindeutig je vx,vy,vz)
  vox_per_seg <- vox_all[, .(n_vox = .N), by = PredInstance]
  vox_per_seg[, vox_volume := n_vox * vox_res^3]

  # Kronenflaeche = projizierte eindeutige (vx,vy)-Zellen
  crown_per_seg <- vox_all[, .(crown_area = uniqueN(data.table(vx, vy)) * vox_res^2),
                           by = PredInstance]

  # belegte 1-m-Schichten
  zlayer_per_seg <- zl_all[, .(n_zlayer = uniqueN(zlayer)), by = PredInstance]

  # PCA-Ausdehnung auf den eindeutigen Voxelzentren (orientierungsunabhaengig)
  ext_per_seg <- vox_all[, {
    if (.N >= 3) {
      P   <- as.matrix(.SD) * vox_res
      sc  <- prcomp(P, center = TRUE)$x
      rng <- apply(sc, 2, function(v) diff(range(v)))
      .(pc_ext1 = rng[1], pc_ext2 = rng[2], pc_ext3 = rng[3])
    } else {
      .(pc_ext1 = NA_real_, pc_ext2 = NA_real_, pc_ext3 = NA_real_)
    }
  }, by = PredInstance, .SDcols = c("vx", "vy", "vz")]

  seg_tab <- Reduce(
    function(a, b) merge(a, b, by = "PredInstance", all = TRUE),
    list(apex_all, vox_per_seg, crown_per_seg, zlayer_per_seg, ext_per_seg)
  )

  # Filter: Groesse UND Form
  seg_tab[, `:=`(
    pass_vox    = n_vox    >= min_vox,
    pass_apex   = apex_z   >  apex_min_height,
    pass_thick  = !is.na(pc_ext3) & pc_ext3 >= min_thickness,
    pass_zlayer = n_zlayer >= min_zlayer
  )]
  seg_tab[, is_tree := pass_vox & pass_apex & pass_thick & pass_zlayer]
  seg_tab[, fail_reason := paste0(
    ifelse(!pass_vox,    "vox ",  ""),
    ifelse(!pass_apex,   "apex ", ""),
    ifelse(!pass_thick,  "dick ", ""),
    ifelse(!pass_zlayer, "zlay ", ""))]

  seg_tab
}

# ============================================================================
# ---- Ergebnis-Tabellen initialisieren ---------------------------------------
# ============================================================================
results <- data.frame(
  file              = character(),
  sensor            = character(),
  country           = character(),
  tile_id           = integer(),
  tile_xmin         = numeric(),
  tile_ymin         = numeric(),
  edge_tile         = logical(),
  n_tiles_plot      = integer(),
  vox_filled        = integer(),
  vox_total         = integer(),
  veg_density       = numeric(),
  zsd               = numeric(),
  zskew             = numeric(),
  zkurt             = numeric(),
  zq90              = numeric(),
  box_dim_fixed     = numeric(),
  vci               = numeric(),
  rumple            = numeric(),
  gap_fraction      = numeric(),
  chm_sd            = numeric(),
  chm_cv            = numeric(),
  height_max        = numeric(),
  height_mean       = numeric(),
  n_seg_total       = integer(),   # Segmente mit Apex in DIESEM Tile (vor Filter)
  n_trees           = integer(),   # Baeume, deren Apex in DIESEM Tile liegt
  tree_height_max   = numeric(),
  tree_height_mean  = numeric(),
  tree_height_gini  = numeric(),
  tree_crownarea_mean = numeric(),
  tree_crownarea_max  = numeric(),
  tree_crownarea_gini = numeric(),
  tree_volume_mean  = numeric(),
  tree_volume_max   = numeric(),
  tree_volume_gini  = numeric()
)

seg_diag_all <- data.frame()

# ============================================================================
# ---- Hauptschleife ueber Dateien (eine Datei = ein Plot) --------------------
# ============================================================================
for (fi in seq_len(nrow(file_tab))) {

  f       <- file_tab$path[fi]
  sensor  <- file_tab$sensor[fi]
  country <- file_tab$country[fi]

  cat("\nProcessing:", basename(f),
      "  [Sensor:", sensor, "| Land:", country, "]\n")
  fbase <- tools::file_path_sans_ext(basename(f))

  poly_file <- file.path(dirname(f), paste0(fbase, ".gpkg"))
  if (!file.exists(poly_file)) {
    cat("  -> No GeoPackage found, skipping\n"); next
  }

  # ---- Polygon + Tile-Gitter (vor der DTM-Berechnung) ------------------------
  # Das Gitter wird optimal ins Polygon gelegt. Passt danach kein einziges Tile
  # vollstaendig ins Polygon, kann es kein gefuelltes 20x20-m-Tile geben und die
  # Datei wird uebersprungen - noch bevor das teure globale DTM gerechnet wird.
  polygon <- st_read(poly_file, quiet = TRUE)
  st_crs(polygon) <- NA                        # rein planar in lokalen Metern
  polygon   <- st_make_valid(polygon)
  poly_geom <- st_union(polygon)               # auf eine Geometrie reduzieren

  # Optimalen Gitter-Offset suchen (max. vollstaendig enthaltene Tiles)
  offsets <- seq(0, tile_size - search_step, by = search_step)
  best <- list(n = -1L, ox = 0, oy = 0)
  for (ox in offsets) for (oy in offsets) {
    grid <- make_grid_at(poly_geom, tile_size, ox, oy)
    n    <- count_within(grid, poly_geom)
    if (n > best$n) best <- list(n = n, ox = ox, oy = oy)
  }
  cat(sprintf("  Bester Offset: ox = %.1f m, oy = %.1f m | enthaltene Tiles: %d\n",
              best$ox, best$oy, best$n))

  grid_best   <- make_grid_at(poly_geom, tile_size, best$ox, best$oy)
  keep        <- lengths(st_within(grid_best, poly_geom)) > 0
  tiles_valid <- st_sf(tile_id = seq_len(sum(keep)), geometry = grid_best[keep])
  cat("  Valid tiles:", nrow(tiles_valid), "\n")
  if (nrow(tiles_valid) == 0) {
    cat("  -> Kein vollstaendiges Tile im Polygon, skipping\n"); next
  }

  edge_flags   <- compute_edge_flags(tiles_valid, tile_size)
  n_tiles_plot <- nrow(tiles_valid)

  # ---- Catalog fuer DIESE eine Datei -----------------------------------------
  # .lax-Raumindex einmalig bauen, falls noch nicht vorhanden. Ohne Index
  # scannt jeder raeumliche Read (-inside je Tile in Phase 3) die ganze Datei;
  # mit Index sind diese Reads deutlich schneller.
  lax <- sub("\\.la[sz]$", ".lax", f, ignore.case = TRUE)
  if (!file.exists(lax)) {
    cat("  .lax-Index wird gebaut (einmalig pro Datei) ...\n")
    tryCatch(rlas::writelax(f),
             error = function(e)
               cat("    Index-Bau fehlgeschlagen:", conditionMessage(e), "\n"))
  }

  ctg <- readLAScatalog(f)
  opt_chunk_size(ctg) <- chunk_size

  # ===== Phase 1: nahtloses globales DTM =====================================
  cat("  Phase 1: globales DTM ...\n")
  dtm <- build_global_dtm(ctg, dtm_res = dtm_res, ptd_res = ptd_res,
                          dtm_buffer = dtm_buffer)
  if (is.null(dtm)) {
    cat("  -> DTM leer (keine Bodenpunkte?), skipping\n"); next
  }

  # ===== Phase 2: globale Segment-/Apex-Aggregation ==========================
  seg_tab <- NULL
  if (CALC_SEGMENTS) {
    cat("  Phase 2: globale Segmente ueber PredInstance ...\n")
    acc <- accumulate_segments(ctg, dtm, vox_res = vox_res,
                               max_height = max_height)
    if (!is.null(acc)) {
      seg_tab <- finalize_seg_tab(acc, vox_res,
                                  min_vox, apex_min_height, min_thickness, min_zlayer)
      cat(sprintf("  Segmente im Plot: %d | als Baum: %d | verworfen: %d\n",
                  nrow(seg_tab), sum(seg_tab$is_tree, na.rm = TRUE),
                  sum(!seg_tab$is_tree, na.rm = TRUE)))

      # ---- Apex -> Tile (global eindeutig); NA = ausserhalb aller Tiles -----
      tile_bb <- t(vapply(seq_len(nrow(tiles_valid)),
                          function(i) st_bbox(tiles_valid[i, ]), numeric(4)))
      colnames(tile_bb) <- c("xmin", "ymin", "xmax", "ymax")
      assign_tile <- function(ax, ay) {
        hit <- which(ax >= tile_bb[, "xmin"] & ax < tile_bb[, "xmax"] &
                       ay >= tile_bb[, "ymin"] & ay < tile_bb[, "ymax"])
        if (length(hit)) tiles_valid$tile_id[hit[1]] else NA_integer_
      }
      seg_tab[, tile_id := mapply(assign_tile, apex_x, apex_y)]

      # ---- Kalibrierungs-Log (eine Zeile je Segment, global) ----------------
      seg_diag_all <- rbind(seg_diag_all, data.frame(
        file         = basename(f),
        sensor       = sensor,
        country      = country,
        tile_id      = seg_tab$tile_id,
        PredInstance = seg_tab$PredInstance,
        n_vox        = seg_tab$n_vox,
        apex_z       = round(seg_tab$apex_z,  4),
        pc_ext1      = round(seg_tab$pc_ext1, 4),
        pc_ext2      = round(seg_tab$pc_ext2, 4),
        pc_ext3      = round(seg_tab$pc_ext3, 4),
        n_zlayer     = seg_tab$n_zlayer,
        pass_vox     = seg_tab$pass_vox,
        pass_apex    = seg_tab$pass_apex,
        pass_thick   = seg_tab$pass_thick,
        pass_zlayer  = seg_tab$pass_zlayer,
        is_tree      = seg_tab$is_tree,
        apex_in_tile = !is.na(seg_tab$tile_id)
      ))

      rm(acc); gc()
    }
  }

  # ===== Phase 3: Voxel- und CHM-Indizes pro Tile (gegen das globale DTM) =====
  n_tiles <- nrow(tiles_valid)

  for (t in seq_len(n_tiles)) {

    tile_bbox <- st_bbox(tiles_valid[t, ])

    xmin_t <- tile_bbox["xmin"]; xmax_t <- tile_bbox["xmax"]
    ymin_t <- tile_bbox["ymin"]; ymax_t <- tile_bbox["ymax"]

    # Nur das Tile-Innere lesen - kein grosser Lesepuffer noetig, weil das DTM
    # bereits global vorliegt.
    las_tile <- readLAS(f, select = "xyz0",
      filter = sprintf("-inside %f %f %f %f", xmin_t, ymin_t, xmax_t, ymax_t))
    if (is.empty(las_tile)) { cat("  Tile", t, "| no points, skipping\n"); next }

    # ERST normalisieren, DANN voxelisieren: so liegt das Voxelgitter im
    # gelaendeunabhaengigen Z-ueber-Grund und ist mit dem Segment-Gitter aus
    # Phase 2 konsistent (dort wird ebenfalls normalize_height vor
    # floor(Z / vox_res) angewandt). Die Rohpunkte werden genau einmal angefasst.
    las_tile <- normalize_height(las_tile, dtm)
    las_tile <- filter_poi(las_tile, Z >= 0, Z <= max_height)
    if (is.empty(las_tile)) { cat("  Tile", t, "| empty after norm\n"); rm(las_tile); gc(); next }

    vox_all <- voxelize_points(las_tile, res = vox_res)   # mit Boden, normalisiertes Gitter
    rm(las_tile); gc()
    if (is.empty(vox_all)) { cat("  Tile", t, "| empty after voxelize\n"); rm(vox_all); gc(); next }

    ##########################################################################
    ###   VOXELBASIERTE INDIZES  (Boden raus: Z > veg_min_height)          ###
    ##########################################################################

    # ---- Vegetationsvoxel (Boden raus) fuer die bodensensitiven Indizes ----
    vox_veg <- filter_poi(vox_all, Z > veg_min_height)
    if (is.empty(vox_veg)) {
      cat("  Tile", t, "| no vegetation above", veg_min_height, "m, skipping\n")
      rm(vox_all); gc(); next
    }
    vox_veg_dt <- as.data.table(vox_veg@data)

    # ---- Vegetationsdichte (Zaehler aus Vegetation, Nenner konstant) ----
    vox_filled  <- nrow(vox_veg_dt)
    vox_total <- round((tile_size / vox_res)^2 * ((max_height - veg_min_height) / vox_res))
    veg_density <- vox_filled / vox_total

    # ---- z-Metriken ueber die Vegetationsvoxel ----
    cm    <- cloud_metrics(vox_veg, func = .stdmetrics_z)
    zsd   <- cm$zsd; zskew <- cm$zskew; zkurt <- cm$zkurt; zq90 <- cm$zq90

    # ---- Box-Dimension (festes Boxen-Set, plotuebergreifend) ----
    # Box-Counting durch ganzzahliges Vergroebern der Voxelindizes statt durch
    # wiederholtes voxelize_points(): wegen floor(floor(X/vox_res)/k) =
    # floor(X/(k*vox_res)) sind die Belegungszahlen bei Boxweite k*vox_res
    # identisch - nur ohne die ~30 Re-Voxelisierungen der Rohwolke.
    Vveg <- unique(vox_veg_dt[, .(vx = floor(X / vox_res),
                                  vy = floor(Y / vox_res),
                                  vz = floor(Z / vox_res))])
    box_count <- function(D, k) uniqueN(D[, .(vx %/% k, vy %/% k, vz %/% k)])
    ks             <- round(boxdim_fixed / vox_res); ks <- ks[ks >= 1]  # 1,2,4,...,64
    vox_counts_fix <- vapply(ks, function(k) box_count(Vveg, k), numeric(1))
    log_inv_r_fix  <- log(1 / (ks * vox_res)); log_counts_fix <- log(vox_counts_fix)
    box_dim_fixed  <- coef(lm(log_counts_fix ~ log_inv_r_fix))[2]

    # ---- Vertical Complexity Index (feste 1-m-Schichten) ----
    breaks       <- seq(0, max_height, by = 1)
    layers       <- cut(vox_veg_dt$Z, breaks = breaks, include.lowest = TRUE)
    layer_counts <- table(factor(layers, levels = levels(layers)))
    p         <- layer_counts / sum(layer_counts)
    p_nonzero <- p[p > 0]
    shannon   <- -sum(p_nonzero * log(p_nonzero))
    vci       <- shannon / log(length(layer_counts))

    ##########################################################################
    ###   CHM-BASIERTE INDIZES  (mit Boden)                                ###
    ##########################################################################

    # ---- EIN CHM (chm_res = 0.5 m) fuer Rumple, Gap Fraction und chm_sd/cv ----
    # Aus der voxelisierten Wolke MIT Boden (Luecken zaehlen als niedrige Flaeche).
    chm      <- rasterize_canopy(vox_all, res = chm_res, algorithm = p2r())
    rumple   <- rumple_index(chm)
    chm_vals <- terra::values(chm)
    n_total  <- sum(!is.na(chm_vals))
    n_gap    <- sum(chm_vals < height_threshold, na.rm = TRUE)
    gap_fraction <- if (n_total > 0) n_gap / n_total else NA
    chm_mean <- mean(chm_vals, na.rm = TRUE)
    chm_sd   <- if (n_total > 1) sd(chm_vals, na.rm = TRUE) else NA
    chm_cv   <- if (!is.na(chm_sd) && !is.na(chm_mean) && chm_mean > 0) chm_sd / chm_mean else NA

    # Hoehenkennzahlen ueber die Voxelzentren (mit Boden) statt der Rohpunkte
    height_max  <- round(max(vox_all@data$Z,  na.rm = TRUE), 4)
    height_mean <- round(mean(vox_all@data$Z, na.rm = TRUE), 4)

    rm(vox_veg, vox_veg_dt, Vveg, chm); gc()

    ##########################################################################
    ###   SEGMENTBASIERTE KENNZAHLEN  (Lookup aus globalem seg_tab, Phase 2) ###
    ##########################################################################

    # n_seg_total = alle Segmente mit Apex in DIESEM Tile (vor dem Filter),
    # direkt vergleichbar mit n_trees (nach dem Filter).
    n_seg_total       <- NA_integer_
    n_trees_valid     <- NA
    tree_height_max   <- NA; tree_height_mean  <- NA; tree_height_gini  <- NA
    tree_crownarea_mean <- NA; tree_crownarea_max <- NA; tree_crownarea_gini <- NA
    tree_volume_mean  <- NA; tree_volume_max   <- NA; tree_volume_gini  <- NA

    if (CALC_SEGMENTS && !is.null(seg_tab)) {
      in_tile     <- seg_tab[tile_id == tiles_valid$tile_id[t]]
      n_seg_total <- nrow(in_tile)
      trees       <- in_tile[is_tree == TRUE]
      n_trees_valid <- nrow(trees)
      if (n_trees_valid > 0) {
        tree_height_max  <- round(max(trees$apex_z),  4)
        tree_height_mean <- round(mean(trees$apex_z), 4)
        tree_height_gini <- if (n_trees_valid > 1) round(gini(trees$apex_z), 4) else NA
        tree_crownarea_mean <- round(mean(trees$crown_area), 4)
        tree_crownarea_max  <- round(max(trees$crown_area),  4)
        tree_crownarea_gini <- if (n_trees_valid > 1) round(gini(trees$crown_area), 4) else NA
        tree_volume_mean <- round(mean(trees$vox_volume), 4)
        tree_volume_max  <- round(max(trees$vox_volume),  4)
        tree_volume_gini <- if (n_trees_valid > 1) round(gini(trees$vox_volume), 4) else NA
      }
    }

    # ---- Ergebniszeile -----------------------------------------------------
    results <- rbind(results, data.frame(
      file              = basename(f),
      sensor            = sensor,
      country           = country,
      tile_id           = tiles_valid$tile_id[t],
      tile_xmin         = tile_bbox["xmin"],
      tile_ymin         = tile_bbox["ymin"],
      edge_tile         = edge_flags[t],
      n_tiles_plot      = n_tiles_plot,
      vox_filled        = vox_filled,
      vox_total         = vox_total,
      veg_density       = round(veg_density, 4),
      zsd               = round(zsd,     4),
      zskew             = round(zskew,   4),
      zkurt             = round(zkurt,   4),
      zq90              = round(zq90,    4),
      box_dim_fixed     = round(box_dim_fixed, 4),
      vci               = round(vci,     4),
      rumple            = round(rumple,  4),
      gap_fraction      = round(gap_fraction, 4),
      chm_sd            = round(chm_sd, 4),
      chm_cv            = round(chm_cv, 4),
      height_max        = height_max,
      height_mean       = height_mean,
      n_seg_total       = n_seg_total,
      n_trees           = n_trees_valid,
      tree_height_max   = tree_height_max,
      tree_height_mean  = tree_height_mean,
      tree_height_gini  = tree_height_gini,
      tree_crownarea_mean = tree_crownarea_mean,
      tree_crownarea_max  = tree_crownarea_max,
      tree_crownarea_gini = tree_crownarea_gini,
      tree_volume_mean  = tree_volume_mean,
      tree_volume_max   = tree_volume_max,
      tree_volume_gini  = tree_volume_gini
    ))

    cat("  Tile", t, "/", n_tiles, "| land:", country, "| edge:", edge_flags[t],
        "| veg_density:", round(veg_density, 4),
        "| VCI:", round(vci, 4), "| gap_fr:", round(gap_fraction, 4),
        "| n_trees:", n_trees_valid,
        "| vox_vol_mean:",
        ifelse(is.na(tree_volume_mean), "NA", round(tree_volume_mean, 2)), "\n")

    rm(vox_all); gc()
  }

  rm(dtm, seg_tab); gc()
  cat("  -> Done:", basename(f), "\n")
}

# ============================================================================
# ---- Export -----------------------------------------------------------------
# ============================================================================
write.csv(results, "results.csv", row.names = FALSE)
cat("\nDone! Results saved to results.csv\n")

if (nrow(seg_diag_all) > 0) {
  write.csv(seg_diag_all, "segment_diagnostics.csv", row.names = FALSE)
  cat("Segment-Diagnose (alle Segmente, global) -> segment_diagnostics.csv\n")
  cat(sprintf("Segmente gesamt: %d | als Baum gewertet: %d | verworfen: %d\n",
              nrow(seg_diag_all), sum(seg_diag_all$is_tree),
              sum(!seg_diag_all$is_tree)))
  cat("  davon an der PCA-Dicke gescheitert:",
      sum(!seg_diag_all$pass_thick), "\n")
  cat("  davon an n_zlayer gescheitert:    ",
      sum(!seg_diag_all$pass_zlayer), "\n")
}

