# NPS Water Systems Database — Coordinate Merge

Merges coordinate updates from multiple reviewer copies of the NPS Water
Systems Database back into a single authoritative workbook, while preserving
the original's formatting (merged category header, column widths, styles).

## What it does

Each reviewer works on their own copy of the database and fills in
`source_longitude` / `source_latitude` for rows that were missing or marked
unknown (`U`). This script consolidates those edits into one merged file and
produces an audit trail of every change.

**Merge rule** (applied per coordinate — longitude and latitude are
evaluated independently):

| Original             | Working file          | Action    |
|----------------------|-----------------------|-----------|
| `NA` / `""` / `"NA"` | real number           | ✅ update |
| `NA` / `""` / `"NA"` | `"U"`                 | ✅ update |
| `"U"`                | real number           | ✅ update |
| real number          | different real number | ✅ update |
| anything else        | anything else         | ⏭ skip   |

An empty original accepts anything non-blank (`"U"` counts as a "reviewed
but unknown" marker). A `"U"` original only upgrades to a real number.
A real number is never downgraded. When either coord qualifies, the
**whole row** is copied from the working file into the original.

**Row matching:** composite key of
`park_unit + wsd_system_id + wsd_source_id`. This handles occasional typos
(e.g. `AGFO_WS_005` having source id `AGFO_WS_006_01`) and cross-park
collisions on `_01`.

**Conflict rule:** when two working files update the same row, the file
listed *later* in `working_files` wins.

## Outputs

All written to the same folder as the merged xlsx:

| File | Always written? | Contains |
|---|---|---|
| `NPS_Water_Systems_Database_MERGED.xlsx` | yes | the merged database |
| `merge_change_log.csv` | yes | every overwritten row with before/after coords |
| `duplicate_source_ids_in_original.csv` | only if duplicates exist | rows sharing a `wsd_source_id` |
| `rows_needing_coordinates.csv` | only if rows are unresolved | rows with `NA` coords in the original *and* every working file |

## Requirements

- R ≥ 4.0
- R packages: `openxlsx`, `readxl`, `dplyr`, `rmarkdown`, `knitr`
- RStudio (recommended) for the Knit button

Install packages:

```r
install.packages(c("openxlsx", "readxl", "dplyr", "rmarkdown", "knitr"))
```

## How to run it

1. Clone or download this repo.
2. Put your data files in any folder on your computer (not in the repo —
   xlsx files are git-ignored).
3. **Set up your local config**:
   - Copy `config.example.R` to `config.R` (in the repo folder)
   - Edit `config.R` to point at your data files
   - `config.R` is git-ignored, so your local paths stay on your machine
4. Open `merge_coords.Rmd` in RStudio.
5. Click **Knit** (or run chunks interactively).

Check the console output and the generated CSVs to see what was updated
and what still needs attention.

## Data files

**Don't commit xlsx/csv files to this repo.** They contain internal NPS
data and they change frequently. The `.gitignore` keeps them out. Each
teammate keeps their data in a local folder and points `config.R` at it.

Suggested local layout (outside the repo):

```
D:/your/local/path/Data_Merging_Test/
  ├── NPS_Water_Systems_Database_Joined.xlsx        (original)
  ├── NPS_Water_Systems_Database_Joined_XXX.xlsx    (working copies)
  └── (outputs will be written here after running)
```

## File descriptions

| File | What it is | Tracked in git? |
|---|---|---|
| `merge_coords.Rmd` | the actual merge notebook | yes |
| `config.example.R` | template for per-machine paths | yes |
| `config.R` | your local paths — never committed | no |
| `README.md` | this file | yes |
| `.gitignore` | keeps data, configs, R artifacts out of git | yes |

## Contributing

- When editing the merge rule, update the table in both the README and
  the Overview section of the .Rmd.
- Local paths live in `config.R` (git-ignored), so you don't have to
  worry about overwriting teammates' paths when you push.
- For bugs or rule changes, open an issue describing a concrete
  before/after example.

## Contact

Abdullah — maintainer
