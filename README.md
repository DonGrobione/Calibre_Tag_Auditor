# Calibre Tools

This repository contains PowerShell scripts for exporting Calibre library metadata, extracting tag definitions, validating exported data with an LLM agent, and converting validated LLM results to CSV.

## Project structure

- `01-Export-CalibreBooks.ps1` - Export Calibre book metadata into JSON files in `01-Export`.
- `02-Export-CalibreTags.ps1` - Export Calibre tag definitions into JSON files in `01-Export`.
- `03-Process-CalibreDataWithLLM.ps1` - Validate exported Calibre data with the Mistral LLM agent, using the external prompt file `03-CalibreDataLLM-Prompt.txt`, and save results in `02-LLM-Result`.
- `04-Convert-LLMResultsToCsv.ps1` - Convert JSON results from `02-LLM-Result` into a single timestamped CSV file in `03-CSV`, using `|` as delimiter and UTF-8 with BOM.
- `03-CalibreDataLLM-Prompt.txt` - External prompt file used by the LLM agent.
- `.copilot/project-rules.md` - Project rules and coding standards.
- `.secrets/` - Directory for API keys and credentials (not committed to version control).
- `01-Export/` - Generated Calibre export JSON files.
- `02-LLM-Result/` - Generated LLM validation JSON results.
- `03-CSV/` - Generated CSV output.

## Usage

1. Run `01-Export-CalibreBooks.ps1` to export book metadata.
2. Run `02-Export-CalibreTags.ps1` to export tag definitions.
3. Ensure `.secrets/Mistral_API.txt` contains your Mistral API key and `.secrets/Mistral_Agent_Id.txt` can be created or updated by the LLM script.
4. Run `03-Process-CalibreDataWithLLM.ps1` to validate the exports with Mistral.
5. Run `04-Convert-LLMResultsToCsv.ps1` to merge result JSON files into a CSV.

## Notes

- The LLM prompt must remain in `03-CalibreDataLLM-Prompt.txt`.
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

## Contributing

- Follow the rules documented in `.copilot/project-rules.md`.
- Update the comment-based help block and version in each script after modifications.
- Keep prompt text only in external `.txt` prompt files.
