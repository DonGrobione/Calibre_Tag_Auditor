# Calibre Tools Project Memory

## Project Overview
Collection of PowerShell scripts for managing Calibre Portable library data, including book export, tag extraction, LLM validation, and CSV conversion.

## Current State
- Core scripts have been updated to English help blocks, output messages, and top-level error handling.
- `.tmp/` is used for temporary files and is ignored by version control.
- The repository still uses numeric script prefixes (`1_`, `2_`, `3_`, `4_`) by project convention.
- `.secrets/` is present and currently holds plain-text API files; migrating secrets to `.psd1` remains a follow-up task.

## Scripts Inventory
1. **1_Calibre_Buchexport.ps1** - Exports book metadata from Calibre to JSON files
2. **2_Calibre_Tag_Export.ps1** - Extracts tag notes from `.calnotes/notes.db` and creates JSON output
3. **3_LLM_Calibre_ableich.ps1** - Validates book exports against tag definitions using the Mistral API
4. **4_Ergebnis_csv_convert.ps1** - Converts JSON files in `Ergebnis` to a single CSV output, stripping Markdown
5. **Convert-ResultJsonToCsv.ps1** - Converts JSON files from `Ergebnis` into separate CSV files with delimiter and output controls

## Compliance Notes
- `1_Calibre_Buchexport.ps1`: complies with script handling rules; no temp files needed.
- `2_Calibre_Tag_Export.ps1`: uses `.tmp/` for generated Python script and avoids inline logging dependency.
- `3_LLM_Calibre_ableich.ps1`: now uses `$ErrorActionPreference = 'Stop'` and retains top-level try/catch.
- `4_Ergebnis_csv_convert.ps1`: now uses `$ErrorActionPreference = 'Stop'` and a top-level try/catch wrapper.
- `Convert-ResultJsonToCsv.ps1`: now uses `$ErrorActionPreference = 'Stop'` and top-level error handling.
- Secrets migration to `.psd1` is still recommended to fully satisfy project security best practices.

## Conventions
- PowerShell version: 5.1+
- Encoding: UTF8
- Temporary files must be created under `$env:TEMP` and removed after use; do not write temporary artifacts to the script root or output directories.
- CSV delimiter: semicolon (";")
- JSON export location: Export/ directory
- LLM results location: Ergebnis/ directory
- API keys stored in .secrets/ (to be migrated to Secrets/)

## Dependencies
- Calibre Portable (calibredb.exe, calibre-debug.exe)
- Mistral API (for LLM validation)
- Python (embedded in Calibre Portable, for SQLite queries)

## Notes
- The 4_Ergebnis_csv_convert.ps1 script is the simplest and a good candidate for first refactoring
- All existing scripts need significant refactoring to comply with project rules
- No git repository exists for this project currently
