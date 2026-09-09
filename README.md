# Calibre Tag Auditor
Calibre Tag Auditor exports (updated) book data from Calibre, validates it with Mistral, and converts the results directly into an ODS review worksheet with LibreOffice. The generated ODS file serves as a review worksheet: use it to inspect the suggested tag corrections, identify missing or incorrect tags, and apply the corrections back in Calibre.

I started this project, because I have several thousand books and lost track and consistency with my defined tags. Especially as metadata downloads introduce new and undefined tags to my library.

## Requirements
- Windows with PowerShell 5.1 or later
- LibreOffice (current standard installation; headless conversion support required)
- Calibre's embedded Python is used for the tag export step
- No separate system Python installation is required for ODS conversion
- A Mistral account with access to the configured model (`mistral-large-latest`) and an API key stored in `.secrets/Mistral_API.txt`
- Calibre Portable or fixed installation. I use the portable version and sync it across devices via cloud storage.
- Every Calibre tag must have a definition in the tag notes.

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

The Calibre field `last_modified` is used only to sort the books and apply the `ChangedWithinDays` filter. It is not included in the exported book JSON files.

## Mistral
The prompt used to validate the Calibre exports is set in `02-CalibreDataLLM-Prompt.txt`.

### Documentation
- https://docs.mistral.ai/models/model-cards/mistral-large-3-25-12
- https://mistral.ai/pricing/api/?capabilities=text-to-text

### Mistral Links
- Admin Center Subscriptions: https://admin.mistral.ai/subscription
- API-Keys: https://console.mistral.ai/observability/traces?profile_dialog=api-keys
- Mistral Status: https://status.mistral.ai/

## Quick Start
1. Open `01-CalibreExport.config.json` and change `CalibrePaths` with the path where your Calibre is located and update `LibraryName` with the name of your library.
2. Place your Mistral API key in `.secrets/Mistral_API.txt`.
3. Open PowerShell in the project directory.
4. Run the complete workflow:

```powershell
.\Invoke-CalibreToolsPipeline.ps1
```

The script exports books and tags, validates the data with Mistral, and then creates the ODS review file.

## Results
After a successful run, the generated files are located here:

- `01-Export`: exported books and tag definitions
- `02-LLM-Result`: Mistral validation results
- `03-ODS`: formatted ODS file for LibreOffice
- `Logs`: logs for troubleshooting

The ODS file contains the columns `Title`, `Author`, `ProposedAction`, `Tag`, and `Reason`. For `ProposedAction = NO_CHANGES`, `Tag` and `Reason` are empty cells.

## Run Individual Steps
The quick start is normally sufficient. For troubleshooting, run the steps individually in this order:

1. `01-Export-CalibreBooks.ps1`
2. `01-Export-CalibreTags.ps1`
3. `02-Process-CalibreDataWithLLM.ps1`
4. `03-Convert-LLMResults2ODS.ps1`

## Common Issues
- **Calibre is not found:** Update `CalibrePaths` in `01-CalibreExport.config.json`.
- **The Mistral request failed:** Check the API key in `.secrets/Mistral_API.txt`.
- **LibreOffice was not found:** Install LibreOffice in a default location or adjust detection paths.
- **No new books appear in the export:** By default, only books changed within the last 24 hours are exported. Adjust `ChangedWithinDays` in `01-CalibreExport.config.json`; `0` exports all books.

## AI Usage
This codebase was created with assistance from AI tools.

The workflow also uses the Mistral API to validate exported Calibre book data against tag definitions. The book data processed by this step is sent to Mistral. Review the generated suggestions before applying them and ensure that sending this data complies with your privacy requirements.

## Independent Project Notice

This project is an independent personal tool and is not affiliated with, sponsored by, endorsed by, or part of the official Calibre project or its developers.

## License
This project is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0) license. See [LICENSE](LICENSE) for the full terms.