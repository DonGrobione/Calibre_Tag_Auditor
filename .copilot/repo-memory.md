# Calibre Tools Project Memory

## Project Overview
Collection of PowerShell scripts for managing Calibre Portable library data, including book export, tag extraction, LLM validation, and CSV conversion.

## Current State
- 4 main scripts exist (all German language, violating rule #4)
- No Modules directory exists (Write-Log.psm1 missing)
- No Secrets directory (only .secrets with .txt files)
- No README.md documentation
- Scripts use numeric prefixes (1_, 2_, 3_, 4_) instead of Approved Verbs
- Scripts contain exit statements in subscripts (violating rule #4.7)

## Scripts Inventory
1. **1_Calibre_Buchexport.ps1** - Exports book metadata from Calibre to JSON files
2. **2_Calibre_Tag_Export.ps1** - Extracts tag notes from .calnotes/notes.db and links with metadata.db
3. **3_LLM_Calibre_ableich.ps1** - Validates book exports against tag definitions using Mistral API
4. **4_Ergebnis_csv_convert.ps1** - Converts JSON files in Ergebnis directory to CSV format

## Required Actions (Priority Order)
1. Create Modules/Write-Log.psm1 module
2. Convert all scripts to English (comments, help blocks, output messages, variable names)
3. Rename scripts to use PowerShell Approved Verbs
4. Add proper comment-based help blocks to all scripts
5. Add top-level try/catch error handling to all scripts
6. Remove exit statements from subscripts
7. Create Secrets/ directory and migrate secrets to .psd1 files
8. Create and maintain README.md documentation
9. Add input validation at boundaries

## Conventions
- PowerShell version: 5.1+
- Encoding: UTF8
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
