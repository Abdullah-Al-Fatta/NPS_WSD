# =============================================================================
# config.example.R
# =============================================================================
# This is the TEMPLATE that gets committed to git. To use the merge notebook:
#
#   1. Copy this file to "config.R" (in the same folder as merge_coords.Rmd)
#   2. Edit the paths below to point at YOUR copy of the data
#   3. Save -- config.R is git-ignored, so your local edits won't be pushed
#
# Use forward slashes in paths even on Windows (R handles this fine).
#
# Running interactively (Ctrl+Enter) rather than knitting? If you hit
# "config.R not found", run this once in the console first:
#
#   setwd("C:/path/to/your/repo/Scratch")
#
# or install rstudioapi so auto-detection works:
#
#   install.packages("rstudioapi")
# =============================================================================

# Path to the original (authoritative) workbook.
original_file <- "C:/path/to/your/data/NPS_Water_Systems_Database_Joined.xlsx"

# One entry per reviewer. The order matters: when two files update the same
# row, the LAST file in this list wins.
working_files <- c(
  "C:/path/to/your/data/NPS_Water_Systems_Database_Joined_AAF.xlsx",
  "C:/path/to/your/data/NPS_Water_Systems_Database_Joined_KRR.xlsx",
  "C:/path/to/your/data/NPS_Water_Systems_Database_Joined_LAS.xlsx"
)

# Where to write the merged workbook. The diagnostic CSVs
# (merge_change_log.csv, duplicate_source_ids_in_original.csv,
# rows_needing_coordinates.csv) land in the same folder.
output_file <- "C:/path/to/your/data/NPS_Water_Systems_Database_MERGED.xlsx"