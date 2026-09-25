# Calibre Tag Auditor Project Memory

## Project Overview
Collection of PowerShell scripts for managing Calibre Portable library data, including book export, tag extraction, LLM validation with Mistral, and ODS spreadsheet creation.

## Current State
- Core scripts follow English comment help blocks, regular comments, output messages, and top-level error handling.
- All temporary files are stored strictly under `$env:TEMP` and deleted after execution.
- `.copilot/` directory strictly contains only `.copilot/project-rules.md` and `.copilot/repo-memory.md`.

## Scripts Inventory
1. **01-Export-CalibreBooks.ps1** - Exports book metadata from Calibre Portable to JSON files in `01-Export/`.
2. **01-Export-CalibreTags.ps1** - Extracts tag notes from Calibre SQLite databases and creates JSON tag definitions in `01-Export/`.
3. **02-Process-CalibreDataWithLLM.ps1** - Validates book exports against tag definitions using Mistral API agents and writes JSON results in `02-LLM-Result/`.
4. **03-Convert-LLMResults2ODS.ps1** - Merges LLM JSON results and converts them to formatted ODS files in `03-ODS/` via LibreOffice.
5. **Invoke-CalibreToolsPipeline.ps1** - Orchestrates the entire pipeline run from export to ODS creation.

## Compliance Notes
- `01-Export-CalibreBooks.ps1`: Complies with script handling rules and uses temporary files under `$env:TEMP`.
- `01-Export-CalibreTags.ps1`: Uses temporary Python script under `$env:TEMP` and cleans up in `finally` block.
- `02-Process-CalibreDataWithLLM.ps1`: Uses `$ErrorActionPreference = 'Stop'` and top-level try/catch.
- `03-Convert-LLMResults2ODS.ps1`: Uses `$ErrorActionPreference = 'Stop'` and top-level try/catch.
- `Invoke-CalibreToolsPipeline.ps1`: Orchestrates subscripts without duplicate log entries.

## Conventions
- PowerShell version: 5.1+
- Encoding: UTF-8 with BOM for `.ps1` and `.psm1` files.
- Temporary files: Must be created under `$env:TEMP` and removed after use.
- JSON export location: `01-Export/` directory.
- LLM results location: `02-LLM-Result/` directory.
- ODS output location: `03-ODS/` directory.

## Dependencies
- PowerShell module DonGrobione.Logging >= 1.2.0 (external, default module path; update with `Update-DonGrobioneLogging`).
- Calibre Portable (`calibredb.exe`, `calibre-debug.exe`).
- Mistral API (for LLM validation).
- LibreOffice (`soffice.exe`, for headless CSV to ODS conversion).

## Encoding Gotcha
- All `.ps1` and `.psm1` files in the repo are saved as UTF-8 with BOM (`EF BB BF`) because scripts contain non-ASCII literals (e.g. `'Ã|Â'`, `Begründung`).
- When creating or fully rewriting a `.ps1` or `.psm1` file, verify/re-apply the UTF-8 BOM afterwards.

## Logging and Orchestration
- Logging migrated from the project's own logging modules (daily log files in the project folder) to DonGrobione.Logging. Logs: `<Documents>\Logs\Calibre_Tag_Auditor\<HOSTNAME>_yyyy-MM-dd_HHmmss.log`, one file per run, 5 files per host kept by `Start-Log`.
- `Invoke-CalibreToolsPipeline.ps1` owns the log session; child scripts start their own session only when `Test-LogSession` is `$false`.
- `Write-ScriptLog` (`Modules\Calibre.Console.psm1`) replaces the former `Write-Host`/`Write-Warning`/`Write-Error` aliases. It never terminates; the former aliased `Write-Error` was also non-terminating because module functions do not inherit the caller's `$ErrorActionPreference`.
- Duplicate log entries bug fix: Child scripts log and rethrow their own errors. `Invoke-CalibreToolsPipeline.ps1` catch block prints via `Microsoft.PowerShell.Utility\Write-Error -ErrorAction Continue` and calls `exit 1` instead of rethrowing.
