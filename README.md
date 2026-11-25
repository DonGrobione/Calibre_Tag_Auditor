# Calibre Tag Auditor
Calibre Tag Auditor exports (updated) book data from Calibre, validates it with Google Gemini, and converts the results directly into an ODS review worksheet with LibreOffice. The generated ODS file serves as a review worksheet: use it to inspect the suggested tag corrections, identify missing or incorrect tags, and apply the corrections back in Calibre.

>I started this project because I have several thousand books and lost track of the consistency of my defined tags, especially as metadata downloads introduce new and undefined tags to my library.

## Requirements
- Windows with PowerShell 5.1 or later
- PowerShell module [DonGrobione.Logging](https://github.com/DonGrobione/Logging) version 2.2.0 or later, installed in the default PowerShell module path. This project does not install, bundle, or update it.
- LibreOffice (current standard installation; headless conversion support required)
- Calibre's embedded Python is used for the tag export step. No separate system Python installation is required for ODS conversion
- A Google Gemini API key with access to the configured model (`gemini-3.8-flash`), stored in `Secrets/Gemini_API.json.key` (see [Google Gemini](docs/google-gemini.md))
- Calibre Portable or a fixed installation. I use the portable version and sync it across devices via cloud storage.
- Every Calibre tag must have a definition in the tag notes.
- Optional, for development: Pester 3.4 or 4.x to run the tests in `Tests/` (see [Tests](docs/tests.md)).

## Quick Start
1. Open `01-CalibreExport.config.json` and change `CalibrePaths` with the path where your Calibre is located and update `LibraryName` with the name of your library. All other settings are described in [Calibre Configuration](docs/calibre-configuration.md).
2. Store your Gemini API key in `Secrets/Gemini_API.json.key` as a JSON file with the property `APIKey` (see [Google Gemini](docs/google-gemini.md)):

```json
{
    "APIKey": "<your Gemini API key>"
}
```

3. Open PowerShell in the project directory.
4. Run the complete workflow:

```powershell
.\Invoke-CalibreToolsPipeline.ps1
```

The script exports books and tags, validates the data with Gemini, and then creates the ODS review file.

To export a different period for a single run without editing `01-CalibreExport.config.json`, pass `-ChangedWithinDays`. The value from the configuration file stays the default for all runs without the parameter.

```powershell
# Books changed today or on the previous 6 calendar days
.\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 7

# All books
.\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 0
```

`01-Export-CalibreBooks.ps1` accepts the same parameter when it runs on its own.

A run over many books can take many hours and use a lot of tokens, especially the first run, which creates the content profiles. See [Calibre Configuration](docs/calibre-configuration.md) for an example and [Token Usage](docs/token-usage.md) for the token summary.

To send the full book text for every book instead of stored content profiles, pass `-FullContent` (see [Content Profiles](docs/content-profiles.md)). `02-Process-CalibreDataWithLLM.ps1` accepts the same switch when it runs on its own.

### Run Individual Steps
The complete workflow is normally sufficient. For troubleshooting, run the steps individually in this order:

1. `01-Export-CalibreBooks.ps1`
2. `01-Export-CalibreTags.ps1`
3. `02-Process-CalibreDataWithLLM.ps1`
4. `03-Convert-LLMResults2ODS.ps1`

## Cancel And Resume A Run
A full run can take a long time. You can cancel it with Ctrl+C and continue it later; a crash or power outage is handled the same way.

```powershell
# Continue the last run where it stopped
.\Invoke-CalibreToolsPipeline.ps1 -Resume
```

- Once both export steps have finished, the pipeline writes the run state file `02-LLM-Result/Pipeline-RunState.json`. It records the run timestamp, the start time, the `-FullContent` setting, and the step the run is in (`02-Process` or `03-Convert`). After the ODS conversion, the run is marked `Completed`.
- When you start the pipeline without `-Resume` and the last run is unfinished, it shows the progress (e.g. `210 of 472 export file(s) processed`) and asks: `[R]esume`, start a `[N]ew run` (discards the unfinished results), or `[A]bort`. An empty answer aborts and keeps the unfinished run.
- A resumed run skips both export steps and continues with the export files of the original run, its tag definitions, and its `-FullContent` setting. `-Resume` therefore cannot be combined with `-ChangedWithinDays` or `-FullContent`. If the run stopped during the ODS conversion, only the conversion runs again.
- The LLM step keeps the existing result files and skips every export file that already has a complete result. Result files with status `error` (e.g. a failed request) are processed again. At most the export file that was in progress when the run stopped is sent to Gemini again.
- Result files are written to `LLM-Result_<nn>_<timestamp>.tmp` first and then renamed to `.json`, so an interruption never leaves a truncated result file. Leftover `.tmp` files are deleted at the next start.
- An interruption during the export steps cannot be resumed; the next start simply runs a new export, which takes only seconds.
- The LLM step continues the token ledger of the earlier sessions, so the token and search query totals in the pipeline summary cover the whole run, including the requests of the export file that was interrupted. The duration shown is the duration of the current session.

## Results
After a successful run, the generated files are located here:

- `01-Export`: exported books and tag definitions
- `01-Cache`: cached book exports and content profiles, one file per book (see [Book Export Cache](docs/book-export-cache.md) and [Content Profiles](docs/content-profiles.md))
- `02-LLM-Result`: Gemini validation results
- `03-ODS`: formatted ODS file for LibreOffice

The ODS file contains the columns `Title`, `Author`, `ProposedAction`, `Tag`, and `Reason`. For `ProposedAction = NO_CHANGES`, `Tag` and `Reason` are empty cells. A book that the LLM step could not audit (e.g. blocked by Gemini for prohibited content) gets one row with `ProposedAction = NOT_AUDITED`, an empty `Tag`, and the reason in `Reason`.

## Books Without Text
Comics, manga, graphic novels, and art books are often made of images, also in EPUB, PDF, AZW3, or MOBI files, so no text can be extracted. Without evidence, Gemini could only mark such books as uncertain. These books therefore get their content profile from a Google Search instead of the book text.

- `01-Export-CalibreBooks.ps1` sets `ContentStatus` to `NoText` when the extracted text has fewer than 500 words (`$MinimumContentWords`; image files often still hold a copyright or navigation page), or when the book has no EPUB, AZW3, MOBI, or PDF file (e.g. only CBZ or CBR). The log shows a warning for each such book, and the export summary shows their number.
- Before the tag audit of each export file, `02-Process-CalibreDataWithLLM.ps1` sends every book without a current web profile in its own request with the `google_search` tool and the prompt `02-CalibreWebProfile-Prompt.txt`. The request holds the book's title, author, series, series index, identifiers, publisher, year, and Calibre description, but not the tag definitions.
- Gemini first identifies the exact work (by ISBN or ASIN first, then by title, author, series, and volume) and then writes a profile with the same facets as a text profile, only from facts in the search results and the description. Facets the sources do not cover are marked `unknown`. When the facts describe only the series, the profile says so. When the work cannot be identified with confidence, Gemini returns no profile instead of guessing.
- The profile is stored in `01-Cache/<uuid>.json` with `ContentProfileSource` `Web` and the cited web pages in `ContentProfileSources`. The tag audit then uses it like any other profile, marked as a web profile; the audit request itself never searches.
- A book that could not be identified gets a `WebNotFound` marker and is checked without content. It is searched again only when its title, author, series, identifiers, or description change in Calibre, or with `-FullContent`. Adding an ISBN or a description in Calibre is the best way to help the search.
- `-FullContent` writes new web profiles for all books without text in the run.
- A profile gap of a web profile leads to one more, targeted search for that book (see [Profile Gaps](docs/content-profiles.md#profile-gaps)).

Google bills grounded requests per executed search query (for Gemini 3 models, 5,000 queries per month are free, then about $14 per 1,000), and one request can run several queries. The log shows the search queries per file and in total, and each result file stores them in `token_usage.web_search_queries`. Because profiles and markers are cached, each book is normally searched only once.

## Changing Tag Definitions
The tag definitions are read fresh from Calibre on every run, so Gemini always uses the current wording. Editing a tag note, however, does not change any book in Calibre, so a normal run (`ChangedWithinDays 1`) applies new definitions only to the books that were changed anyway. To apply them to the whole library, run with `-ChangedWithinDays 0`.

| Change | Effect | What to do |
|---|---|---|
| Wording clarified, same concept | The content profiles usually cover it | `-ChangedWithinDays 0` |
| Meaning changed, or a new tag with a new concept | The content profiles cover the fixed facets; when a profile lacks a needed detail, the profile gap refreshes the book with its full text or a targeted web search in the same run | `-ChangedWithinDays 0` |
| Tag removed | Books that still carry the tag keep it as an undefined tag | Delete the tag in Calibre too (Tag browser). This changes the affected books, so they are re-checked on the next run |
| Tag renamed in Calibre | The note stays attached to the tag; the affected books change and are re-checked | Nothing |
| New tag without a note | The tag export only contains tags with a note, so the tag counts as undefined | Write the note first |

## Documentation
Detailed documentation is in the `docs/` folder:

- [Project Structure](docs/project-structure.md): purpose of every file and folder in the project.
- [Calibre Configuration](docs/calibre-configuration.md): all settings in `01-CalibreExport.config.json`.
- [Exported Calibre Fields](docs/exported-calibre-fields.md): the fields of the book export and how the book text is sampled.
- [Book Export Cache](docs/book-export-cache.md): how extracted book content is cached in `01-Cache/` and when it is extracted again.
- [Content Profiles](docs/content-profiles.md): the book summaries that replace the full text on later runs, and profile gaps.
- [Google Gemini](docs/google-gemini.md): model, retries, blocked books, the API key file, and Gemini links.
- [Token Usage](docs/token-usage.md): the token summary at the end of a run.
- [Logging](docs/logging.md): where log files are written and how the logging module is updated.
- [Common Issues](docs/common-issues.md): solutions for frequent problems.
- [Tests](docs/tests.md): how to run the Pester tests.
- [Data, Privacy And Copyright](docs/data-privacy-and-copyright.md): what is sent to the LLM provider and what stays on your computer.

## AI Usage
This codebase was created and is maintained with assistance from AI tools.

The workflow also sends exported Calibre book data to an external LLM provider to validate it against the tag definitions. Review the generated suggestions before applying them. See [Data, Privacy And Copyright](docs/data-privacy-and-copyright.md) for what is sent.

## Independent Project Notice
This project is independent and is not affiliated with, sponsored by, endorsed by, or part of the official Calibre project or its developers.

## License
This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE) for the full terms.