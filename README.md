# Calibre Tools

This repository contains PowerShell scripts for exporting Calibre library metadata, extracting tag definitions, validating exported data with an LLM agent, and converting validated LLM results to CSV.

## Project structure

- `Invoke-CalibreToolsPipeline.ps1` - Run the full pipeline in sequence: clears old LLM results, executes all scripts below in order, and waits for Enter on failures so errors remain visible.
- `01-Export-CalibreBooks.ps1` - Export Calibre book metadata into JSON files in `01-Export`.
- `01-Export-CalibreTags.ps1` - Export Calibre tag definitions into JSON files in `01-Export`.
- `02-Process-CalibreDataWithLLM.ps1` - Validate exported Calibre data with the Mistral LLM agent, using the external prompt file `02-CalibreDataLLM-Prompt.txt`, repair mojibake in LLM responses, compare unique books from input vs. output, and save valid JSON wrapper results in `02-LLM-Result`.
- `03-Convert-LLMResultsToCsv.ps1` - Convert JSON results from `02-LLM-Result` into a single timestamped CSV file in `03-CSV`, using `|` as delimiter and UTF-8 with BOM while preserving umlauts and special characters.
- `02-CalibreDataLLM-Prompt.txt` - External prompt file used by the LLM agent.
- `.copilot/project-rules.md` - Project rules and coding standards.
- `.secrets/` - Directory for API keys and credentials (not committed to version control).
- `01-Export/` - Generated Calibre export JSON files.
- `02-LLM-Result/` - Generated LLM validation JSON results.
- `03-CSV/` - Generated CSV output.

## Usage

Run the full pipeline in one step:

```powershell
.\Invoke-CalibreToolsPipeline.ps1
```

Or run each script individually:

1. Run `01-Export-CalibreBooks.ps1` to export book metadata.
2. Run `01-Export-CalibreTags.ps1` to export tag definitions.
3. Ensure `.secrets/Mistral_API.txt` contains your Mistral API key.
4. Run `02-Process-CalibreDataWithLLM.ps1` to validate the exports with Mistral.
5. Run `03-Convert-LLMResultsToCsv.ps1` to merge result JSON files into a CSV.

## Notes

- The LLM prompt must remain in `02-CalibreDataLLM-Prompt.txt`.
- `02-Process-CalibreDataWithLLM.ps1` creates a fresh Mistral agent at script start, reusing no previous agent instance.
- Each file in `02-LLM-Result` is a valid JSON wrapper with metadata fields such as `source_file`, `status`, `records`, `parse_error`, and validation fields for record counts and unique books (`input_book_count`, `input_unique_book_count`, `output_record_count`, `output_unique_book_count`, `record_count_match`, `unique_book_count_match`, `validation_error`).
- Input-vs-output validation is performed per book export file; duplicates for the same book are collapsed before comparison, and mismatches are kept in output metadata and shown in terminal warnings.
- The CSV converter repairs malformed input text before export so German umlauts and special characters survive the pipeline.
- All PowerShell scripts use top-level error handling and are compatible with PowerShell 5.1.
- The output folder names are versioned and consistent across scripts:
  - `01-Export`
  - `02-LLM-Result`
  - `03-CSV`

## Requirements

- PowerShell 5.1 or newer
- Mistral API key stored in `.secrets/Mistral_API.txt`
- Calibre Portable installation paths configured in the export scripts
- Python (bundled with Calibre Portable) — used internally by `01-Export-CalibreTags.ps1` via `calibre-debug.exe`; no separate Python installation required

## Contributing

- Follow the rules documented in `.copilot/project-rules.md`.
- Update the comment-based help block and version in each script after modifications.
- Update this `README.md` whenever script behavior, output format, or required files change.
- Keep prompt text only in external `.txt` prompt files.
