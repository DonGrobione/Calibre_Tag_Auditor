# Calibre Tag Auditor
Calibre Tag Auditor exports (updated) book data from Calibre, validates it with Google Gemini, and converts the results directly into an ODS review worksheet with LibreOffice. The generated ODS file serves as a review worksheet: use it to inspect the suggested tag corrections, identify missing or incorrect tags, and apply the corrections back in Calibre.

I started this project because I have several thousand books and lost track of the consistency of my defined tags, especially as metadata downloads introduce new and undefined tags to my library.

## Requirements
- Windows with PowerShell 5.1 or later
- PowerShell module [DonGrobione.Logging](https://github.com/DonGrobione/Logging) version 2.2.0 or later, installed in the default PowerShell module path. This project does not install, bundle, or update it.
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
- `02-CalibreDataLLM-Prompt.txt`: prompt for Gemini, sent as system instruction with every tag audit request.
- `02-CalibreWebProfile-Prompt.txt`: prompt for the web profile requests of books without text (see [Books Without Text](#books-without-text)).
- `02-CalibreContentProfile-Checklist.txt`: the fixed facets of a content profile, inserted into both prompts at the placeholder `{{CONTENT_PROFILE_CHECKLIST}}` (see [Content Profiles](#content-profiles)).
- `Modules/`: helper modules used by the scripts. Each module has a manifest (`.psd1`) that holds its version and its exported functions.
  - `Calibre.Environment`: loads the configuration and resolves the Calibre installation, library, and executables.
  - `Calibre.Console`: writes terminal and log output and converts paths into project-relative display paths.
  - `Calibre.Text`: repairs mojibake (UTF-8 text that was decoded with the wrong code page) in the Gemini responses and the review sheet.
- `Tests/`: Pester tests for the modules and the step scripts.
- `Secrets/`: Gemini API key file (not tracked by Git).
- `01-Export/`, `02-LLM-Result/`, `03-ODS/`: generated files (see [Results](#results)).
- `01-Cache/`: one cached book export per book, reused by `01-Export-CalibreBooks.ps1` (see [Book Export Cache](#book-export-cache)), including the book's content profile written by `02-Process-CalibreDataWithLLM.ps1` (see [Content Profiles](#content-profiles)). Not tracked by Git.
- `CHANGELOG.md`: notable changes and module versions.

## Calibre Configuration
Configure the Calibre export scripts centrally in `01-CalibreExport.config.json`:

- `CalibrePaths`: Ordered list of Calibre Portable installation directories. The first existing path is used.
- `LibraryName`: Name of the Calibre library directory inside the selected Calibre Portable directory. Default: `Calibre Library`.
- `BooksPerFile`: Maximum number of books in each JSON export file. Set to `0` to export all books to one file. Default: `10`. Keep this number low to prevent timeouts or other LLM processing issues. Each file is written as soon as it is full, so the files finished before an interrupted export are kept.
- `ChangedWithinDays`: Exports only books changed within this number of days. Set to `0` to export all books regardless of modification date. Default: `1`. The parameter `-ChangedWithinDays` of `Invoke-CalibreToolsPipeline.ps1` and `01-Export-CalibreBooks.ps1` overrides this value for a single run without changing the file (see [Quick Start](#quick-start)).
- `DebugBookExport`: Set to `true` to ignore `ChangedWithinDays` and export only the 10 most recently changed books, split into files of `BooksPerFile` books. Use it for small test runs. Books without a valid modification date are excluded. Default: `false`.

Depending on the size of your library and number of tags, changing the value of `ChangedWithinDays` may use a lot more tokens. Books without text (e.g. comics) also cause Google Search queries the first time they are checked (see [Books Without Text](#books-without-text)).

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
- `Description`: The book description from the Calibre field `comments`, converted from HTML to plain text. It is sent to Gemini only in the web profile request of a book without text.
- `BookContent`: An excerpt of the preferred EPUB, AZW3, MOBI, or PDF file, with normalized whitespace. A book with up to 30,000 words is included completely. A longer book is sampled: 18,000 words from the start, 6,000 words from the middle, and 6,000 words from the late part, ending at 92% of the text so that afterwords, ads, and previews of other books are left out. The sections are separated by a line `[...]`, so the profile also covers developments that only start later in the book. Empty for a book without text and when the extraction failed.

The export also contains these technical fields, which are not sent to Gemini as they are:

- `Uuid`: Calibre UUID of the book (lower case), used to find the book's cache file.
- `ContentStatus`: `Text` (the book has `BookContent`), `NoText` (no or almost no extractable text, or no supported book file, see [Books Without Text](#books-without-text)), or `Failed` (the extraction failed).
- `ContentHash`: SHA256 hash that identifies what a content profile was written from: the book text for books with text, or the identity metadata (title, author, series, series index, identifiers, description) for books without text.
- `ContentProfile`, `ContentProfileVersion`, `ContentProfileSource`, `ContentProfileSources`, `ContentProfileTagHashes`: the stored content profile of the book, or empty when there is none (see [Content Profiles](#content-profiles)). The source is `Text`, `Web`, or `WebNotFound`; the sources list the cited web pages of a web profile; the tag hashes are fingerprints of the tag definitions that were already checked against the book's source (see [Profile Gaps](#profile-gaps)).

The Calibre field `last_modified` is used only to sort the books, apply the `ChangedWithinDays` filter, and check whether a cached book is still current. The field `formats` is used only to find the book files: the export uses exactly the file paths that Calibre lists for the book and ignores paths outside the library folder. Neither field is included in the exported book JSON files.

## Book Export Cache
Extracting `BookContent` with `ebook-convert.exe` is the slowest part of the book export. `01-Export-CalibreBooks.ps1` therefore stores every exported book in `01-Cache/<uuid>.json`, named after the Calibre UUID of the book. The cache file holds the exported fields plus `CacheVersion` and `LastModified`, and the content profile once `02-Process-CalibreDataWithLLM.ps1` has stored one.

- When a book is exported again and its `last_modified` value in Calibre is unchanged, the content from the cache file is reused and the book is logged with `(cached: <uuid>.json)`, the name of its cache file. Title, authors, tags, and the other metadata are always read fresh from Calibre.
- When the book was changed in Calibre, the content is extracted again and the cache file is overwritten.
- Books whose extraction failed are not cached, so the next run tries again. An outdated cache file of such a book is deleted.
- Books without text (see [Books Without Text](#books-without-text)) are cached with `ContentStatus` `NoText`, so the slow conversion of large image files is not repeated. When you add a text format to such a book in Calibre, its `last_modified` value changes and the book is extracted again.
- `CacheVersion` is the format version of the cache. A cache file with a different or missing version is ignored and rebuilt. The version is increased in the script whenever the content extraction or the cache format changes, so existing cache files never keep content from an older extraction.
- On every run, the cache files of books that are no longer in the Calibre library are deleted, independent of `ChangedWithinDays`. When Calibre returns no books at all, the cleanup is skipped, so a wrong library path cannot empty the cache.

The batch files in `01-Export/` are still written on every run, so `02-Process-CalibreDataWithLLM.ps1` works as before. The summary at the end of the export shows how many books came from the cache, how many were extracted, and how many cache files were removed. To force a new content extraction for all books, delete the files in `01-Cache/`. This also deletes the stored content profiles, including the web profiles of books without text, which then cost search queries again.

## Content Profiles
The book text is about 95% of the input tokens that are sent to Gemini (about 40,000 tokens per book). To avoid sending the same text again on every re-check, Gemini writes a content profile for each book it receives with the full text. The profile is a factual English description of 400 to 700 words, structured in the fixed facets of `02-CalibreContentProfile-Checklist.txt`: form, fiction or non-fiction, franchise, genre, setting, magic and supernatural, science and technology, premise devices (e.g. isekai, reincarnation, time travel), progression and game mechanics, protagonists, relationships, romance and sexual content, conflict, violence, themes, tone, narrative perspective, target audience, and other notable elements. Each facet states the finding, `absent` (the source clearly shows the concept does not occur), or `unknown` (the source does not say).

The facets do not depend on the tag definitions. A profile therefore stays useful when you add or change tags, and Gemini can tell a concept that was checked and found absent from one that the excerpt did not cover. The script logs a warning when a stored profile has fewer than 300 words (`$MinimumProfileWords`).

- `02-Process-CalibreDataWithLLM.ps1` stores the profile in the book's cache file `01-Cache/<uuid>.json`, together with the `ContentHash` of the text it was written from. A profile is stored only when the cache file still holds the same text.
- On the next export of the book, `01-Export-CalibreBooks.ps1` adds the profile to the export as long as the book text has the same `ContentHash`. This also applies when the book was changed in Calibre (e.g. after you applied tag corrections), because the text is extracted again and compared by hash.
- `02-Process-CalibreDataWithLLM.ps1` then sends the profile instead of the full text, which costs about a thousand tokens instead of about 40,000. The log shows per file how many books were sent with full text or with a profile, and how many profiles were stored.
- When the book file changes (the text has a different hash), the full text is sent again and a new profile is written.
- `$ContentProfileVersion` near the top of `02-Process-CalibreDataWithLLM.ps1` is increased whenever the checklist or the profile instructions in a prompt change. Profiles with an older version are ignored and rebuilt. To rebuild all profiles of the exported books at once, use `-FullContent`.
- A change of the excerpt or of the profile version is a one-time cost: every book is extracted again and sent once with its full text (and every book without text is searched once more) the next time it is exported. Afterwards, the profiles are used again.

### Profile Gaps
A profile can still miss a detail that a new or changed tag definition depends on. For each book sent with its profile, Gemini therefore lists every tag whose decision the profile cannot settle: the profile hints that the tag may apply, or that an existing tag may be wrong, but does not say enough to decide. Gemini still decides such a tag as well as the profile allows, so a decision is never dropped only because the tag is a gap, and the script refreshes the book in the same run:

- A book with text is audited again with its full excerpt from the cache. Its results replace the first ones, and its new profile is stored.
- A book without text gets a new web search with the definitions of the open tags as focus questions, and is then audited again with the new web profile. When the search finds nothing new, the existing profile and the first results are kept.

Each profile stores fingerprints of the tag definitions that were already checked against the book's source in `ContentProfileTagHashes`. A profile written from the text records all tags. A web profile records only the tags its targeted searches covered. A gap leads to a refresh only for a tag that is new or whose definition changed since then, so the same gap never costs a second request. The log shows the profile gaps and refreshes per file and in the run summary, and each result file stores them in `profile_gaps` and `profile_refresh`.

The book data and the tag definitions are also sent as compact JSON without indentation, which saves some more tokens.

## Books Without Text
Comics, manga, graphic novels, and art books are often made of images, also in EPUB, PDF, AZW3, or MOBI files, so no text can be extracted. Without evidence, Gemini could only mark such books as uncertain. These books therefore get their content profile from a Google Search instead of the book text.

- `01-Export-CalibreBooks.ps1` sets `ContentStatus` to `NoText` when the extracted text has fewer than 500 words (`$MinimumContentWords`; image files often still hold a copyright or navigation page), or when the book has no EPUB, AZW3, MOBI, or PDF file (e.g. only CBZ or CBR). The log shows a warning for each such book, and the export summary shows their number.
- Before the tag audit of each export file, `02-Process-CalibreDataWithLLM.ps1` sends every book without a current web profile in its own request with the `google_search` tool and the prompt `02-CalibreWebProfile-Prompt.txt`. The request holds the book's title, author, series, series index, identifiers, publisher, year, and Calibre description, but not the tag definitions.
- Gemini first identifies the exact work (by ISBN or ASIN first, then by title, author, series, and volume) and then writes a profile with the same facets as a text profile, only from facts in the search results and the description. Facets the sources do not cover are marked `unknown`. When the facts describe only the series, the profile says so. When the work cannot be identified with confidence, Gemini returns no profile instead of guessing.
- The profile is stored in `01-Cache/<uuid>.json` with `ContentProfileSource` `Web` and the cited web pages in `ContentProfileSources`. The tag audit then uses it like any other profile, marked as a web profile; the audit request itself never searches.
- A book that could not be identified gets a `WebNotFound` marker and is checked without content. It is searched again only when its title, author, series, identifiers, or description change in Calibre, or with `-FullContent`. Adding an ISBN or a description in Calibre is the best way to help the search.
- `-FullContent` writes new web profiles for all books without text in the run.
- A profile gap of a web profile leads to one more, targeted search for that book (see [Profile Gaps](#profile-gaps)).

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

## Google Gemini
`02-Process-CalibreDataWithLLM.ps1` sends each book export file to the Gemini Interactions API (`gemini-3.8-flash`). The prompt used to validate the Calibre exports is set in `02-CalibreDataLLM-Prompt.txt` and sent as system instruction with every request. Model, thinking level (`low`, `medium`, or `high`), timeouts, and retry intervals are set near the top of the script. Requests are retried on HTTP 429, 500, 502, 503, and 504 and on connection failures (DNS lookup, connect, timeout). When Gemini blocks the request of a file for prohibited content (HTTP 400), the books of that file are sent again one at a time, so only the book that triggers the block stays without result; the file is saved with a validation warning that names it. Requests are sent as UTF-8 bytes and responses are decoded as UTF-8, so umlauts and typographic characters do not depend on PowerShell's encoding defaults. A mojibake repair stays in place as a safety net for text that was already garbled at its source.

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

To export a different period for a single run without editing `01-CalibreExport.config.json`, pass `-ChangedWithinDays`. The value from the configuration file stays the default for all runs without the parameter.

```powershell
# Books changed within the last 7 days
.\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 7

# All books
.\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 0
```

`01-Export-CalibreBooks.ps1` accepts the same parameter when it runs on its own.

To send the full book text for every book instead of stored content profiles, pass `-FullContent` (see [Content Profiles](#content-profiles)). `02-Process-CalibreDataWithLLM.ps1` accepts the same switch when it runs on its own.

## Results
After a successful run, the generated files are located here:

- `01-Export`: exported books and tag definitions
- `01-Cache`: cached book exports and content profiles, one file per book (see [Book Export Cache](#book-export-cache) and [Content Profiles](#content-profiles))
- `02-LLM-Result`: Gemini validation results
- `03-ODS`: formatted ODS file for LibreOffice

The ODS file contains the columns `Title`, `Author`, `ProposedAction`, `Tag`, and `Reason`. For `ProposedAction = NO_CHANGES`, `Tag` and `Reason` are empty cells.

## Logging
All scripts log through the DonGrobione.Logging module. Each run writes one log file to `<Documents>\Logs\Calibre_Tag_Auditor\<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log`. When the pipeline runs, all steps share one log file; a step started on its own writes its own log file. The module keeps the 5 newest log files per computer and deletes older ones automatically. The scripts turn off the module's size-based rotation (`Start-Log -MaxFileSizeMB 0`), so a run is never split across several files, however long it takes. The project folder no longer contains log files.

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
- **A book has no `BookContent`:** The book export reads the content from the first EPUB, AZW3, MOBI, or PDF file of a book, in this order. The file paths come from Calibre. If a book has none of these formats, the log contains a warning with the supported formats and the formats that are available for the book. Convert the book to a supported format in Calibre to include its content. If the file contains no or almost no text, such as a comic with images only, the log contains the warning "Only N word(s) of text found", and the book gets a web content profile instead (see [Books Without Text](#books-without-text)).
- **A comic or manga gets no web profile ("No reliable web information found"):** Gemini could not identify the work. Add an ISBN, the correct series and volume, or a description in Calibre; the changed metadata leads to a new search on the next run.
- **A book keeps outdated `BookContent`:** The content is taken from `01-Cache/` as long as Calibre's `last_modified` value of the book is unchanged. Delete the book's file `01-Cache/<uuid>.json`, or all files in `01-Cache/`, to extract the content again.
- **The suggestions for a book seem to miss parts of its content:** The book was probably checked with its content profile, and Gemini reported no profile gap for it. Check the profile in `01-Cache/<uuid>.json`. Run with `-FullContent` to check it against the full text and rebuild its profile, or delete its file `01-Cache/<uuid>.json`.
- **"Content profile of ... has only N words":** Gemini wrote a profile that is shorter than `$MinimumProfileWords`. The profile is stored anyway. If this happens often, check the profile facets in `01-Cache/<uuid>.json`.
- **LibreOffice was not found:** Install LibreOffice in a default location or adjust detection paths.
- **The module DonGrobione.Logging was not found or is too old:** Install version 2.2.0 or later in the default PowerShell module path, or run `Update-DonGrobioneLogging`.
- **No new books appear in the export:** By default, only books changed within the last 24 hours are exported. Run again with a higher `-ChangedWithinDays` value, or adjust `ChangedWithinDays` in `01-CalibreExport.config.json`; `0` exports all books. When no book matches, the pipeline logs a warning, skips the remaining steps, and ends without an error. The results of the previous run in `02-LLM-Result/` and `03-ODS/` are kept.

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