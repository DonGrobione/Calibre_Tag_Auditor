# Calibre Tag Auditor
Calibre Tag Auditor exports (updated) book data from Calibre, validates it with Google Gemini, and converts the results directly into an ODS review worksheet with LibreOffice. The generated ODS file serves as a review worksheet: use it to inspect the suggested tag corrections, identify missing or incorrect tags, and apply the corrections back in Calibre.

I started this project because I have several thousand books and lost track of the consistency of my defined tags, especially as metadata downloads introduce new and undefined tags to my library.

## Requirements
- Windows with PowerShell 5.1 or later
- PowerShell module [DonGrobione.Logging](https://github.com/DonGrobione/Logging) version 1.2.0 or later, installed in the default PowerShell module path. This project does not install, bundle, or update it.
- LibreOffice (current standard installation; headless conversion support required)
- Calibre's embedded Python is used for the tag export step
- No separate system Python installation is required for ODS conversion
- A Google Gemini API key with access to the configured model (`gemini-3.8-flash`), stored in `Secrets/Gemini_API.json.key` (see [Google Gemini](#google-gemini))
- Calibre Portable or a fixed installation. I use the portable version and sync it across devices via cloud storage.
- Every Calibre tag must have a definition in the tag notes.
- Optional, for development: Pester 3.4 or 4.x to run the tests in `Tests/` (see [Tests](#tests)).

## Project Structure
- `Invoke-CalibreToolsPipeline.ps1`: runs the complete workflow.
- `01-Export-CalibreBooks.ps1`, `01-Export-CalibreTags.ps1`, `02-Process-CalibreDataWithLLM.ps1`, `03-Convert-LLMResults2ODS.ps1`: the individual workflow steps (see [Run Individual Steps](#run-individual-steps)).
- `01-CalibreExport.config.json`: Calibre export configuration (see [Calibre Configuration](#calibre-configuration)).
- `02-CalibreDataLLM-Prompt.txt`: prompt for Gemini, sent as system instruction with every request.
- `Modules/`: helper modules used by the scripts. Each module has a manifest (`.psd1`) that holds its version and its exported functions.
  - `Calibre.Environment`: loads the configuration and resolves the Calibre installation, library, and executables.
  - `Calibre.Console`: writes terminal and log output and converts paths into project-relative display paths.
- `Tests/`: Pester tests for the modules and the step scripts.
- `Secrets/`: Gemini API key file (not tracked by Git).
- `01-Export/`, `02-LLM-Result/`, `03-ODS/`: generated files (see [Results](#results)).
- `CHANGELOG.md`: notable changes and module versions.

## Calibre Configuration
Configure the Calibre export scripts centrally in `01-CalibreExport.config.json`:

- `CalibrePaths`: Ordered list of Calibre Portable installation directories. The first existing path is used.
- `LibraryName`: Name of the Calibre library directory inside the selected Calibre Portable directory. Default: `Calibre Library`.
- `BooksPerFile`: Maximum number of books in each JSON export file. Set to `0` to export all books to one file. Default: `10`. Keep this number low to prevent timeouts or other LLM processing issues.
- `ChangedWithinDays`: Exports only books changed within this number of days. Set to `0` to export all books regardless of modification date. Default: `1`.
- `DebugBookExport`: Set to `true` to ignore `ChangedWithinDays` and export the 20 most recently changed books in four JSON files with five books per file. Books without a valid modification date are excluded. Default: `false`.

Depending on the size of your library and number of tags, changing the value of `ChangedWithinDays` may use a lot more tokens, especially if many web calls or searches are required.

## Exported Calibre Fields
The book export contains the following fields from Calibre:

- `Title`: Book title
- `Author`: Author or authors
- `Series`: Series name
- `SeriesIndex`: Position of the book within the series
- `Tags`: Calibre tags, combined into a comma-separated value
- `IDs`: Available identifiers, such as ISBN, Amazon, or Google IDs
- `Publisher`: Publisher name
- `Year`: Publication year, extracted from the publication date
- `BookContent`: The first 20,000 words from the preferred EPUB, AZW3, MOBI, or PDF file, with normalized whitespace. Content extraction failures result in an empty value for that book.

The Calibre field `last_modified` is used only to sort the books and apply the `ChangedWithinDays` filter. It is not included in the exported book JSON files.

## Google Gemini
`02-Process-CalibreDataWithLLM.ps1` sends each book export file to the Gemini Interactions API (`gemini-3.8-flash`). The prompt used to validate the Calibre exports is set in `02-CalibreDataLLM-Prompt.txt` and sent as system instruction with every request. Model, thinking level (`low`, `medium`, or `high`), timeouts, and retry intervals are set near the top of the script.

The API key file `Secrets/Gemini_API.json.key` is a JSON file. The script reads only the property `APIKey`; other properties are ignored:

```json
{
    "APIKey": "<your Gemini API key>"
}
```

### Documentation
- Gemini 3.8 Flash: https://ai.google.dev/gemini-api/docs/latest-model
- Interactions API reference: https://ai.google.dev/api/interactions-api
- Pricing: https://ai.google.dev/gemini-api/docs/pricing
- API keys: https://aistudio.google.com/docs/api-keys

### Gemini Links
- API keys: https://aistudio.google.com/apikey
- Billing: https://aistudio.google.com/billing

## Quick Start
1. Open `01-CalibreExport.config.json` and change `CalibrePaths` with the path where your Calibre is located and update `LibraryName` with the name of your library.
2. Store your Gemini API key in `Secrets/Gemini_API.json.key` (see [Google Gemini](#google-gemini)).
3. Open PowerShell in the project directory.
4. Run the complete workflow:

```powershell
.\Invoke-CalibreToolsPipeline.ps1
```

The script exports books and tags, validates the data with Gemini, and then creates the ODS review file.

## Results
After a successful run, the generated files are located here:

- `01-Export`: exported books and tag definitions
- `02-LLM-Result`: Gemini validation results
- `03-ODS`: formatted ODS file for LibreOffice

The ODS file contains the columns `Title`, `Author`, `ProposedAction`, `Tag`, and `Reason`. For `ProposedAction = NO_CHANGES`, `Tag` and `Reason` are empty cells.

## Logging
All scripts log through the DonGrobione.Logging module. Each run writes one log file to `<Documents>\Logs\Calibre_Tag_Auditor\<HOSTNAME>_yyyy-MM-dd_HHmmss.log`. When the pipeline runs, all steps share one log file; a step started on its own writes its own log file. The module keeps the 5 newest log files per computer and deletes older ones automatically. The project folder no longer contains log files.

Terminal output shows the same messages; warnings and errors are prefixed with `WARN:` or `ERROR:`.

To update the logging module:

```powershell
Update-DonGrobioneLogging
```

## Run Individual Steps
The quick start is normally sufficient. For troubleshooting, run the steps individually in this order:

1. `01-Export-CalibreBooks.ps1`
2. `01-Export-CalibreTags.ps1`
3. `02-Process-CalibreDataWithLLM.ps1`
4. `03-Convert-LLMResults2ODS.ps1`

## Common Issues
- **Calibre is not found:** Update `CalibrePaths` in `01-CalibreExport.config.json`.
- **The Gemini request failed:** Check that `Secrets/Gemini_API.json.key` is valid JSON with the property `APIKey` and that the key is valid. The API response body is written to the log.
- **LibreOffice was not found:** Install LibreOffice in a default location or adjust detection paths.
- **The module DonGrobione.Logging was not found or is too old:** Install version 1.2.0 or later in the default PowerShell module path, or run `Update-DonGrobioneLogging`.
- **No new books appear in the export:** By default, only books changed within the last 24 hours are exported. Adjust `ChangedWithinDays` in `01-CalibreExport.config.json`; `0` exports all books. When no book matches, the pipeline logs a warning, skips the tag export, Gemini, and ODS steps, and ends without an error. The results of the previous run in `02-LLM-Result/` and `03-ODS/` are kept.

## Tests
The Pester tests in `Tests/` cover the modules and the helper functions of the step scripts. They mock all external calls and need neither Calibre nor Gemini nor LibreOffice. They use Pester v4-compatible syntax (`Should Be`), which Pester 5 no longer supports. Windows PowerShell 5.1 ships with Pester 3.4.0, which runs the tests:

```powershell
Import-Module Pester -RequiredVersion 3.4.0
Invoke-Pester -Path .\Tests
```

If Pester 4.x is installed, `Import-Module Pester -MaximumVersion 4.99` works as well.

## AI Usage
This codebase was created with assistance from AI tools.

The workflow also uses the Google Gemini API to validate exported Calibre book data against tag definitions. The book data processed by this step is sent to Google. Requests are sent with `store` disabled, so the interactions are not kept for later retrieval; data use for model training depends on your Gemini API plan. Review the generated suggestions before applying them and ensure that sending this data complies with your privacy requirements.

## Independent Project Notice

This project is an independent personal tool and is not affiliated with, sponsored by, endorsed by, or part of the official Calibre project or its developers.

## License
This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE) for the full terms.