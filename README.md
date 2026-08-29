# Calibre Tools

Calibre Tools exports updated book data from Calibre, validates it with Mistral, and creates CSV and ODS files.

## Requirements

- Windows with PowerShell 5.1 or later
- Calibre Portable with a library named `Calibre Library`
- LibreOffice
- Python available through the `python` or `py` command
- A Mistral API key in `.secrets/Mistral_API.txt`

The Calibre installation paths are configured in both export scripts. Update them if Calibre is installed elsewhere.

## AI Usage

This codebase was created with assistance from AI tools.

The workflow also uses the Mistral API to validate exported Calibre book data against tag definitions. The book data processed by this step is sent to Mistral. Review the generated suggestions before applying them and ensure that sending this data complies with your privacy requirements.

### Mistral Documentation
https://docs.mistral.ai/models/model-cards/mistral-large-3-25-12
https://mistral.ai/pricing/api/?capabilities=text-to-text

### Mistral Links
Admin Center: https://admin.mistral.ai/organization/connectors
API-Keys: https://console.mistral.ai/observability/traces?profile_dialog=api-keys

## Quick Start

1. Place your Mistral API key in `.secrets/Mistral_API.txt`.
2. Open PowerShell in the project directory.
3. Run the complete workflow:

```powershell
.\Invoke-CalibreToolsPipeline.ps1
```

The script exports books and tags, validates the data with Mistral, and then creates CSV and ODS files.

## Results

After a successful run, the generated files are located here:

- `01-Export`: exported books and tag definitions
- `02-LLM-Result`: Mistral validation results
- `03-CSV`: combined CSV file
- `04-ODS`: formatted ODS file for LibreOffice
- `Logs`: logs for troubleshooting

The ODS file contains the columns `Titel`, `Autor`, `Vorgeschlagene_Änderung`, and `Begründung`.

## Run Individual Steps

The quick start is normally sufficient. For troubleshooting, run the steps individually in this order:

1. `01-Export-CalibreBooks.ps1`
2. `01-Export-CalibreTags.ps1`
3. `02-Process-CalibreDataWithLLM.ps1`
4. `03-Convert-LLMResultsToCsv.ps1`
5. `04-Convert-CSVtoODS.ps1`

## Common Issues

- **Calibre was not found:** Update the configured Calibre paths in the export scripts.
- **The Mistral request failed:** Check the API key in `.secrets/Mistral_API.txt`.
- **LibreOffice or Python was not found:** Install the missing application and make sure Python can be started with `python` or `py`.
- **No new books appear in the export:** By default, only books changed within the last 24 hours are exported. Adjust `$ChangedWithinDays` in `01-Export-CalibreBooks.ps1` if necessary; `0` exports all books.

## License

This project is licensed for private use only. See [LICENSE](LICENSE) for the full terms.