## =============================================================================
## find_missing_coords.R
## Search NPS Buildings, USGWD wells, and POIs for sources with missing coordinates
## Reads the WSD spreadsheet directly — only processes sources where
## source_longitude/source_latitude are NA or U in SE and PW regions
## =============================================================================

source("setup.R")
library(mapview)
library(readxl)
library(janitor)
library(tigris)

mapviewOptions(basemaps = c("CartoDB.Positron", "OpenStreetMap",
                            "Esri.WorldImagery", "Esri.WorldShadedRelief"))

# --- Config -------------------------------------------------------------------
usgwd_dir <- "data/all/Water_Supply/USGWD-Tabular"
wsd_path  <- "data/Water_Supply_Systems/NPS_Water_Systems_Database_Joined.xlsx"

# --- Read WSD and find missing-coordinate sources -----------------------------
source_table <- read_excel(wsd_path, sheet = 1, skip = 1)

# Identify rows with missing coordinates (NA, U, blank)
is_missing <- function(x) {
  is.na(x) | trimws(as.character(x)) %in% c("", "U", "u", "NA", "NaN")
}

missing_sources <- source_table %>%
  dplyr::filter(
    region %in% c("Southeast Region", "Pacific West Region"),
    is_missing(source_longitude) | is_missing(source_latitude)
  )

cat("Found", nrow(missing_sources), "sources with missing coordinates in SE + PW regions\n")

# --- State name lookup (for USGWD file naming) -------------------------------
state_lookup <- tigris::states() %>%
  st_drop_geometry() %>%
  dplyr::select(STUSPS, NAME) %>%
  dplyr::mutate(usgwd_name = gsub(" ", "_", NAME))

# --- Build search terms from water_system_name and point_of_use ---------------
build_search_terms <- function(system_name, point_of_use, fmss_system_name) {
  terms <- c()
  
  # Clean system name: remove prefixes like "Tent DELETE -", "DELETE -", etc.
  clean_name <- system_name
  clean_name <- gsub("^Tent\\.?\\s*(DELETE|DELTE)\\s*-?\\s*", "", clean_name, ignore.case = TRUE)
  clean_name <- gsub("^DELETE\\s*-?\\s*", "", clean_name, ignore.case = TRUE)
  
  # Remove common suffixes
  clean_name <- gsub("Water (Dist(ribution|\\.)?|System).*$", "", clean_name, ignore.case = TRUE)
  clean_name <- gsub(",\\s*[A-Z]{2,4}$", "", clean_name)
  clean_name <- gsub("PWSID\\s*#.*$", "", clean_name, ignore.case = TRUE)
  clean_name <- gsub("\\(PLANNED\\)", "", clean_name, ignore.case = TRUE)
  clean_name <- gsub("EXCESS$", "", clean_name, ignore.case = TRUE)
  
  # Remove unit prefixes like "CC -", "OA -", "OH -", "PH UTIL", etc.
  clean_name <- gsub("^[A-Z]{2,4}\\s*(-|UTIL)\\s*", "", clean_name)
  
  clean_name <- trimws(clean_name)
  
  # Split into individual words and keep meaningful ones (3+ chars)
  words <- unlist(strsplit(clean_name, "\\s+"))
  words <- words[nchar(words) >= 3]
  generic <- c("water", "system", "well", "the", "and", "for", "area", "non",
               "potable", "irrigation", "pump", "dist", "distribution",
               "emergency", "tent", "delete", "delte", "util")
  words <- words[!tolower(words) %in% generic]
  
  if (length(words) > 0) {
    terms <- c(terms, clean_name)
    if (length(words) <= 3) {
      terms <- c(terms, words)
    } else {
      terms <- c(terms, words[1:3])
    }
  }
  
  # Add point_of_use keywords if available
  if (!is.na(point_of_use) && !point_of_use %in% c("U", "u", "")) {
    pou_words <- unlist(strsplit(as.character(point_of_use), "\\s+"))
    pou_words <- pou_words[nchar(pou_words) >= 4]
    pou_words <- pou_words[!tolower(pou_words) %in% generic]
    if (length(pou_words) > 0) {
      terms <- c(terms, pou_words[1:min(3, length(pou_words))])
    }
  }
  
  # Add FMSS system name keywords if different from system name
  if (!is.na(fmss_system_name) && nchar(as.character(fmss_system_name)) > 2) {
    fmss_clean <- gsub("Water (Dist(ribution|\\.)?|System).*$", "", as.character(fmss_system_name), ignore.case = TRUE)
    fmss_clean <- trimws(fmss_clean)
    if (nchar(fmss_clean) >= 3 && !tolower(fmss_clean) %in% tolower(terms)) {
      terms <- c(terms, fmss_clean)
    }
  }
  
  unique(terms[nchar(terms) >= 2])
}


## =============================================================================
## Helper: search buildings + POIs for a search term
## =============================================================================
search_bldg <- function(bldg_all, search_str) {
  bldg_all %>%
    st_transform(4326) %>%
    st_centroid() %>%
    dplyr::mutate(
      X = sf::st_coordinates(.)[, 1],
      Y = sf::st_coordinates(.)[, 2]
    ) %>%
    dplyr::filter(
      grepl(search_str, MAPLABEL, ignore.case = TRUE) |
        grepl(search_str, BLDGNAME, ignore.case = TRUE) |
        grepl(search_str, BLDGALTNAM, ignore.case = TRUE) |
        grepl(search_str, BLDGTYPE, ignore.case = TRUE)
    )
}

search_pois_df <- function(pois_all, search_str) {
  pois_all %>%
    dplyr::filter(
      grepl(search_str, MAPLABEL, ignore.case = TRUE) |
        grepl(search_str, NOTES, ignore.case = TRUE)
    )
}


## =============================================================================
## Main loop: iterate by unique park_unit
## =============================================================================
results <- tibble(
  wsd_source_id       = character(),
  park_unit            = character(),
  water_system_name    = character(),
  match_source         = character(),
  match_name           = character(),
  search_term          = character(),
  longitude            = numeric(),
  latitude             = numeric(),
  Coordinate_System    = character(),
  source_location_refs = character(),
  confidence           = character()
)

# Cache: avoid re-downloading buildings/boundary for same park
cache_pb       <- list()
cache_bldg     <- list()
cache_pois     <- list()
cache_usgwd    <- list()

parks_to_process <- unique(missing_sources$park_unit)

for (park_code in parks_to_process) {
  
  park_rows  <- missing_sources %>% dplyr::filter(park_unit == park_code)
  state_abbr <- unique(park_rows$state)[1]
  state_info <- state_lookup %>% dplyr::filter(STUSPS == state_abbr)
  
  cat("\n========================================\n")
  cat("Processing:", park_code, "| State:", state_abbr, "\n")
  cat("Sources to find:", nrow(park_rows), "\n")
  cat("========================================\n")
  
  # --- Get park boundary and AOI (cached) ---
  if (is.null(cache_pb[[park_code]])) {
    tryCatch({
      cache_pb[[park_code]] <- getParkBoundary(park_code) %>% st_transform(4326)
    }, error = function(e) {
      cat("  ERROR getting park boundary:", e$message, "\n")
    })
  }
  pb <- cache_pb[[park_code]]
  if (is.null(pb)) next
  aoi <- pb %>% st_buffer(10000)
  
  # --- Get buildings (cached) ---
  if (is.null(cache_bldg[[park_code]])) {
    cache_bldg[[park_code]] <- tryCatch(
      getBuildings(park_boundary = pb),
      error = function(e) { cat("  ERROR getting buildings:", e$message, "\n"); NULL }
    )
  }
  bldg_all <- cache_bldg[[park_code]]
  if (!is.null(bldg_all)) cat("  Buildings loaded:", nrow(bldg_all), "\n")
  
  # --- Get POIs (cached) ---
  if (is.null(cache_pois[[park_code]])) {
    cache_pois[[park_code]] <- tryCatch(
      get_pois(aoi),
      error = function(e) { cat("  ERROR getting POIs:", e$message, "\n"); NULL }
    )
  }
  pois_all <- cache_pois[[park_code]]
  if (!is.null(pois_all)) cat("  POIs loaded:", nrow(pois_all), "\n")
  
  # --- Load USGWD for state (cached) ---
  if (nrow(state_info) > 0 && is.null(cache_usgwd[[state_abbr]])) {
    usgwd_file <- file.path(usgwd_dir, paste0("USGWD_", state_info$usgwd_name[1], ".csv"))
    if (file.exists(usgwd_file)) {
      tryCatch({
        cache_usgwd[[state_abbr]] <- load_csv(usgwd_file, "Longitude", "Latitude", crs = 4269) %>%
          add_wgs_coords()
      }, error = function(e) {
        cat("  ERROR loading USGWD:", e$message, "\n")
      })
    } else {
      cat("  USGWD file not found:", usgwd_file, "\n")
    }
  }
  usgwd_wells <- NULL
  if (!is.null(cache_usgwd[[state_abbr]])) {
    usgwd_wells <- cache_usgwd[[state_abbr]] %>% st_filter(aoi)
    cat("  USGWD wells in AOI:", nrow(usgwd_wells), "\n")
  }
  
  # --- Search each missing source ---
  for (i in 1:nrow(park_rows)) {
    row <- park_rows[i, ]
    src_id       <- row$wsd_source_id
    sys_name     <- as.character(row$water_system_name)
    pou          <- as.character(row$point_of_use)
    fmss_name    <- as.character(row$fmss_system_name)
    
    search_terms <- build_search_terms(sys_name, pou, fmss_name)
    
    cat("\n  Source:", src_id, "\n")
    cat("    System:", sys_name, "\n")
    cat("    Search terms:", paste(search_terms, collapse = " | "), "\n")
    
    found <- FALSE
    
    for (term in search_terms) {
      
      # Search buildings
      if (!is.null(bldg_all) && nrow(bldg_all) > 0) {
        bldg_hits <- tryCatch(search_bldg(bldg_all, term), error = function(e) NULL)
        if (!is.null(bldg_hits) && nrow(bldg_hits) > 0) {
          cat("    BUILDINGS HIT for '", term, "':", nrow(bldg_hits), "matches\n")
          for (j in 1:min(nrow(bldg_hits), 3)) {
            hit <- bldg_hits[j, ]
            cat("      ->", hit$MAPLABEL, "| type:", hit$BLDGTYPE,
                "| X:", hit$X, "Y:", hit$Y, "\n")
            results <- results %>%
              add_row(
                wsd_source_id       = src_id,
                park_unit            = park_code,
                water_system_name    = sys_name,
                match_source         = "NPS Buildings",
                match_name           = as.character(hit$MAPLABEL),
                search_term          = term,
                longitude            = hit$X,
                latitude             = hit$Y,
                Coordinate_System    = "WGS 84",
                source_location_refs = paste0("Buildings, ", hit$MAPLABEL),
                confidence           = NA_character_
              )
          }
          found <- TRUE
        }
      }
      
      # Search POIs
      if (!is.null(pois_all) && nrow(pois_all) > 0) {
        poi_hits <- tryCatch(search_pois_df(pois_all, term), error = function(e) NULL)
        if (!is.null(poi_hits) && nrow(poi_hits) > 0) {
          cat("    POI HIT for '", term, "':", nrow(poi_hits), "matches\n")
          for (j in 1:min(nrow(poi_hits), 3)) {
            hit <- poi_hits[j, ]
            cat("      ->", hit$MAPLABEL, "| X:", hit$longitude_wgs84,
                "Y:", hit$latitude_wgs84, "\n")
            results <- results %>%
              add_row(
                wsd_source_id       = src_id,
                park_unit            = park_code,
                water_system_name    = sys_name,
                match_source         = "NPS POIs",
                match_name           = as.character(hit$MAPLABEL),
                search_term          = term,
                longitude            = hit$longitude_wgs84,
                latitude             = hit$latitude_wgs84,
                Coordinate_System    = "WGS 84",
                source_location_refs = paste0("POIs, ", hit$MAPLABEL),
                confidence           = NA_character_
              )
          }
          found <- TRUE
        }
      }
    }
    
    # Report USGWD (for manual mapview review, not auto-matched)
    if (!is.null(usgwd_wells) && nrow(usgwd_wells) > 0) {
      cat("    USGWD wells in AOI:", nrow(usgwd_wells),
          "(open mapview for manual matching)\n")
    }
    
    if (!found) {
      cat("    NO MATCH found in buildings or POIs\n")
      results <- results %>%
        add_row(
          wsd_source_id       = src_id,
          park_unit            = park_code,
          water_system_name    = sys_name,
          match_source         = "NONE",
          match_name           = NA_character_,
          search_term          = paste(search_terms, collapse = ", "),
          longitude            = NA_real_,
          latitude             = NA_real_,
          Coordinate_System    = NA_character_,
          source_location_refs = "U",
          confidence           = NA_character_
        )
    }
  }
}


## =============================================================================
## Export results
## =============================================================================
cat("\n\n========== RESULTS SUMMARY ==========\n")
cat("Total search results:", nrow(results), "\n")
cat("Sources with matches:", results %>% filter(match_source != "NONE") %>%
      distinct(wsd_source_id) %>% nrow(), "\n")
cat("Sources with no matches:", results %>% filter(match_source == "NONE") %>%
      distinct(wsd_source_id) %>% nrow(), "\n")

write_csv(results, "missing_coords_search_results.csv")
cat("\nResults saved to: missing_coords_search_results.csv\n")


## =============================================================================
## Interactive review: uncomment, set park_code, and run to view in mapview
## =============================================================================
review_park <- "BICY"

pb  <- getParkBoundary(review_park) %>% st_transform(4326)
aoi <- pb %>% st_buffer(10000)
bldg_all    <- getBuildings(park_boundary = pb)
pois_all    <- get_pois(aoi)

st <- tigris::states() %>% filter(STUSPS %in% pb$STATE)
usgwd_file  <- file.path(usgwd_dir, paste0("USGWD_", gsub(" ", "_", st$NAME[1]), ".csv"))
usgwd_wells <- load_csv(usgwd_file, "Longitude", "Latitude", crs = 4269) %>%
  add_wgs_coords() %>% st_filter(aoi)

# Load WSD sources for this park
wsd_park <- source_table %>%
  dplyr::mutate(source_longitude = as.numeric(source_longitude),
                source_latitude = as.numeric(source_latitude)) %>%
  drop_na(source_longitude, source_latitude) %>%
  st_as_sf(coords = c("source_longitude", "source_latitude"), crs = 4326, remove = FALSE) %>%
  dplyr::filter(park_unit == review_park)

mapview(pb, col.regions = "seagreen", layer.name = "Park Boundary") +
  mapview(bldg_all %>% st_centroid(), col.regions = "tomato", cex = 5, layer.name = "Buildings") +
  mapview(pois_all, col.regions = "orange", cex = 5, layer.name = "POIs") +
  mapview(usgwd_wells, col.regions = "dodgerblue", cex = 4, layer.name = "USGWD") +
  mapview(wsd_park, col.regions = "navy", cex = 8, layer.name = "WSD Sources")