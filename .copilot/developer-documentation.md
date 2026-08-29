# Calibre Tools Developer Documentation

## Pipeline

`Invoke-CalibreToolsPipeline.ps1` runs the scripts in this order:

1. `01-Export-CalibreBooks.ps1`
2. `01-Export-CalibreTags.ps1`
3. `02-Process-CalibreDataWithLLM.ps1`
4. `03-Convert-LLMResultsToCsv.ps1`
5. `04-Convert-CSVtoODS.ps1`

Before starting, the pipeline removes previous JSON files from `02-LLM-Result`. Each child script logs its own errors and marks rethrown exceptions so the pipeline does not create duplicate error log entries.

## Inputs and Outputs

- Book exports are written to `01-Export/01-Export-CalibreBooks_<sequence>_<timestamp>.json`.
- Tag definitions are written to `01-Export/02-Export-CalibreTags_<timestamp>.json`.
- The LLM processor reads the current book exports and the latest tag export. It writes one JSON wrapper per book export to `02-LLM-Result`.
- A result wrapper contains processing metadata, `records`, the original `raw_response`, parsing diagnostics, and unique-book count validation fields.
- The CSV converter reads `records` and exports only `Titel`, `Autor`, `Vorgeschlagene_Änderung`, and `Begründung` as UTF-8 CSV with `|` as delimiter.
- The ODS converter processes timestamped CSV files, uses LibreOffice with the pipe delimiter, and writes `04-ODS_Convert_<timestamp>.ods` to `04-ODS`.

## External Dependencies

- Calibre Portable supplies `calibredb.exe` and `calibre-debug.exe`.
- The tag export uses Calibre's embedded Python to query the Calibre databases.
- The ODS formatter requires a separate `python` or `py` command available on `PATH`.
- The LLM processor reads the API key from `.secrets/Mistral_API.txt` and its instructions from `02-CalibreDataLLM-Prompt.txt`.

## Maintenance Rules

- Keep comment-based help and version information current whenever a PowerShell script changes.
- Keep LLM instructions in external `.txt` files.
- Create temporary artifacts only in `$env:TEMP` and remove them after use.
- Keep the README focused on user tasks; record technical contracts and implementation behavior in this document.