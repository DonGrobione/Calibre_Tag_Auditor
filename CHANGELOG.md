# Changelog
All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the modules use [Semantic Versioning](https://semver.org/). Module versions are maintained in their manifests (`Modules/*.psd1`); standalone scripts keep their version in their comment-based help block.

## 2026-10-02

### Scripts
- `01-Export-CalibreBooks.ps1` 4.4: the book progress uses the same `x/y` numbering as the file progress (`Book 456/2326: Filename.epub` instead of `Book 456 of 2326: ...`), in the terminal and in the log.
- Prevent garbled characters at their source instead of only repairing them; the repair functions stay as a safety net.
  - `02-Process-CalibreDataWithLLM.ps1` 5.3: the Gemini request is sent as UTF-8 bytes, and the response is read with `Invoke-WebRequest -UseBasicParsing` and decoded as UTF-8 by the new function `ConvertFrom-Utf8JsonResponse`. Before, `Invoke-RestMethod` decoded the response with the charset named by the server and fell back to ISO-8859-1 without one, which produces mojibake such as `Ã¼`. API error bodies are read as UTF-8 too.
  - `01-Export-CalibreBooks.ps1` 4.3: `ebook-convert.exe` is called with `--txt-output-encoding=utf-8`, and the text file is read as UTF-8 explicitly. Both were the defaults already, so the extracted text and the cache are unchanged (verified on cached books).
  - Not changed, because it is already safe: `calibredb --for-machine` writes ASCII-only JSON with `\u` escapes, so its output is correct under any console code page (checked with code page 850).
- Fixed in `02-Process-CalibreDataWithLLM.ps1` 5.2: the mojibake repair of the Gemini responses (`Repair-MojibakeText`) could lose or skip text.
  - Garbled text was not repaired when the response also contained correct umlauts (e.g. `BegrÃ¼ndung für` stayed unchanged), because the whole text was converted at once and any correct non-ASCII character made the conversion fail.
  - When a repair succeeded, characters outside ISO-8859-1 elsewhere in the response were silently replaced (`–` became `-`, `’` became `'`, `„“` became `"`).
  - The check for garbled text ignored case, so correct letters such as `â` or `ã` (e.g. "pâté") started an unnecessary repair attempt.
  - The repair now replaces only the garbled character sequences, each by exactly one strictly decoded UTF-8 character, and keeps all other text unchanged. It also repairs garbled punctuation from Windows-1252 such as `â€™` (`’`) and `â€“` (`–`), and text that was garbled twice. The check is case-sensitive. Added tests.
- `01-Export-CalibreBooks.ps1` 4.2: more reliable book files and cache.
  - The book files are read from the calibredb field `formats` instead of scanning the library for folders named `(<id>)`. Empty leftover folders from renamed titles, or several folders with the same book ID, no longer hide the real book file or supply the file of another folder. Paths outside the library folder are ignored. The recursive folder scan of the whole library is gone, which also makes the export start faster. `Get-BookFile` now takes `-LibraryPath` instead of `-BookDirectories`.
  - Books with empty `BookContent` (`""`, e.g. comics with images only) are no longer cached either, and the log warns "No text found". An outdated cache file of a book without content is deleted.
  - Cache files carry a `CacheVersion` (currently 1). Files with a different or missing version are ignored and rebuilt, so all cache files written by 4.0 and 4.1 are rebuilt once on their next export.
- `01-Export-CalibreBooks.ps1` 4.1: books without `BookContent` are no longer cached. Before, a book without a supported book file was cached with `BookContent: null` and kept that value until its `last_modified` changed, even after the cause was fixed (e.g. an empty leftover book folder in the library hid the real one). Such books are now checked again on every run, and existing cache files with `BookContent: null` are treated as missing, so their content is extracted again.
- `01-Export-CalibreBooks.ps1` 4.0: new per-book export cache in `01-Cache/` (git-ignored), so the slow content extraction is not repeated for unchanged books.
  - Every exported book is stored as `01-Cache/<uuid>.json`, named after its Calibre UUID (calibredb now also exports the field `uuid`). The file holds the exported fields plus `Uuid` and `LastModified`.
  - When Calibre's `last_modified` value is unchanged, the cached `BookContent` is reused and `ebook-convert.exe` is skipped; the book is logged with `(cached)`. Metadata is always read fresh from calibredb. Failed extractions are not cached.
  - On every run, cache files of books that are no longer in the library are deleted. The cleanup is skipped when calibredb returns no books.
  - The batch files in `01-Export/` and their format are unchanged, so steps 02 and 03 and the pipeline need no change. The export summary shows the cached, extracted, and removed counts.
  - New functions `Test-CalibreUuid`, `Get-BookCachePath`, `Get-CachedBookExport`, `Write-BookCacheFile`, and `Remove-StaleBookCacheFile`, with tests.
- `01-Export-CalibreBooks.ps1` 3.10: each export file is written as soon as it holds `BooksPerFile` books (or the last book), instead of after all books are processed. Memory use stays small during large exports, and the files finished before an interrupted run are kept. The progress log shows each written file between the book lines. New function `Get-BookExportFileName`, with tests.

## 2026-10-01

### Calibre.Console 1.1.1
- Documentation only: the comment-based help names DonGrobione.Logging 2.2.0 as the required version.

### Scripts
- All scripts turn off the size-based log rotation of DonGrobione.Logging with `Start-Log -MaxFileSizeMB 0`, so a run is never split across several log files. Retention (5 files per computer) is unchanged.
  - DonGrobione.Logging 2.2.0 or later is now required (`-MinimumVersion 2.2.0`), because `-MaxFileSizeMB` was introduced in that version. Update with `Update-DonGrobioneLogging`.
  - `Invoke-CalibreToolsPipeline.ps1` 1.12, `01-Export-CalibreBooks.ps1` 3.9, `01-Export-CalibreTags.ps1` 3.4, `02-Process-CalibreDataWithLLM.ps1` 5.1, `03-Convert-LLMResults2ODS.ps1` 1.5.
  - Documentation: log file names follow the module's format `<HOSTNAME>_yyyy-MM-dd_HH-mm-ss.log`.
- Fixed in `01-Export-CalibreBooks.ps1` 3.8: the export stopped with "Cannot bind argument to parameter 'Files' because it is null" at the first book without a book directory in the library. `Get-BookFile` returns an empty array in that case, which PowerShell unrolls into `$null`. The export loop now wraps the result in `@()`, and `Get-PrimaryBookFile` accepts `$null`, so such books get the "No supported primary book file found" warning with `Available: none` and the export continues. Added regression tests.
- New parameter `-ChangedWithinDays` for `Invoke-CalibreToolsPipeline.ps1` 1.11 and `01-Export-CalibreBooks.ps1` 3.7. It overrides `ChangedWithinDays` from `01-CalibreExport.config.json` for a single run, so the configuration file no longer has to be edited for a different period. Without the parameter, the configured value is used as before.
  - The pipeline forwards the parameter only to `01-Export-CalibreBooks.ps1` (new function `Get-StepScriptParameter`, with tests).
  - The export logs whether the value comes from the configuration or the parameter, for example `Changed: 7 day(s) (parameter)`. The warning for an empty export suggests the parameter.
  - The value must be between 0 and 36500; `0` exports all books. `DebugBookExport` still ignores it.
- `01-Export-CalibreBooks.ps1` 3.6: more progress information in the terminal and the log.
  - The number of books to export is logged before the content extraction starts.
  - Every book is logged with its progress, for example `Book 2 of 300: Filename.epub`. Books without a supported file are logged with their title.
  - The warning "No supported primary book file found" lists the supported formats and the formats available for the book, for example `Supported: EPUB, AZW3, MOBI, PDF. Available: CBZ.`
  - `Get-PrimaryBookFile` now selects from a file list and a list of supported extensions; the new function `Get-BookFile` reads the book directory. The new function `ConvertTo-FormatDisplayText` formats the extension lists. Added `Tests/01-Export-CalibreBooks.Tests.ps1`.
- `02-Process-CalibreDataWithLLM.ps1` 5.0: switched from the Mistral API to the Google Gemini Interactions API with the model `gemini-3.8-flash`.
  - The API key is read from the `APIKey` property of the JSON file `Secrets/Gemini_API.json.key` (new function `Get-GeminiApiKey`). `Secrets/Mistral_API.key` and `Secrets/Mistral_Agent_Id.txt` are no longer used.
  - Gemini needs no agent, so `Test-MistralAgent`, `Remove-MistralAgent`, `New-MistralAgent`, and `Get-MistralAgentId` were removed. The prompt is sent as `system_instruction` with every request instead of being repeated in the input.
  - `Invoke-MistralRequest` and `Get-MistralResponseText` were replaced by `Invoke-GeminiRequest` and `Get-GeminiResponseText`. The retry behavior for 429/503/504 and for invalid responses is unchanged. Responses with a status other than `completed` are logged as a warning.
  - Temperature and top-p are no longer set, as Google recommends for Gemini 3.8 Flash. The thinking level (default `medium`) is configurable in the script.
  - Token usage: completion tokens now include Gemini's thinking tokens, because they are billed as output.
  - The result files contain the field `model` instead of `agent_id`.
- Fixed: the pipeline failed in `02-Process-CalibreDataWithLLM.ps1` with "Missing required export file(s)" when no book changed within `ChangedWithinDays`.
  - `Invoke-CalibreToolsPipeline.ps1` 1.10: when `01-Export-CalibreBooks.ps1` writes no book export file, the pipeline skips the remaining steps, prints a short summary, and exits with code 0 (new function `Test-BookExportFile`, with tests).
  - `01-Export-CalibreBooks.ps1` 3.5: the warning names the actual reason (no books changed within the configured days, empty library, or no valid modification dates in debug mode) instead of always reporting "No books were found in the library."

## 2026-09-26

### Calibre.Environment 1.3.0
- Added the module manifest `Modules/Calibre.Environment.psd1` with explicit exports. The version moved from the comment-based help block into the manifest.
- Errors are now raised with `$PSCmdlet.ThrowTerminatingError()` and carry an error ID (for example `CalibreConfigurationNotFound`, `CalibreLibraryNotFound`) and an error category. The error messages are unchanged.
- Fixed: `Get-CalibreConfiguration` accepted a configuration without `CalibrePaths`, because `@($null)` counts as one entry. Empty entries are now removed, and a configuration without a usable path is rejected.
- `Get-CalibreEnvironment` skips empty installation paths instead of failing on them.

### Calibre.Console 1.1.0
- Added the module manifest `Modules/Calibre.Console.psd1` with explicit exports. The version moved from the comment-based help block into the manifest.
- Fixed: `ConvertTo-DisplayPath` failed parameter validation for an empty or `$null` path. It now returns an empty string, as its implementation intended.

### Scripts
- All scripts import the modules through their manifests instead of the `.psm1` files.
- `01-Export-CalibreBooks.ps1` 3.4 and `01-Export-CalibreTags.ps1` 3.3: the configuration is loaded inside the error-handling block, so configuration errors are written to the log and stop the script.

- Fixed all PSScriptAnalyzer warnings in the scripts:
  - Blank console lines use `Write-Information` instead of `Write-Host`. The pipeline's error prompt uses `Read-Host -Prompt` and is no longer yellow.
  - `02-Process-CalibreDataWithLLM.ps1` 4.4: `Test-AgentExists` was renamed to `Test-MistralAgent`. `Remove-MistralAgent` and `New-MistralAgent` support `-WhatIf`/`-Confirm`.
  - `03-Convert-LLMResults2ODS.ps1` 1.4: renamed `Convert-JsonValues`, `Get-BookRecordsFromJsonFiles`, `ConvertTo-CsvRows` and `Invoke-LibreOfficeCsvToOds` to `Convert-JsonValue`, `Get-BookRecordFromJsonFile`, `ConvertTo-CsvRow` and `Invoke-LibreOfficeConversion`. The JSON check in `Repair-JsonText` moved into `Test-JsonText`, which replaces the empty catch blocks. `Set-ConfigItemValue` supports `-WhatIf`/`-Confirm`.
  - `Invoke-CalibreToolsPipeline.ps1` 1.9.
- Fixed in `03-Convert-LLMResults2ODS.ps1`: `ConvertTo-CsvRow` never used the fallback properties `Titel`, `Autor`, `Action`, `Aktion`, and `Begründung`, because an empty `PSObject.Properties.Match()` result counts as `$true`. LLM results that use these names now fill the review sheet instead of leaving the cells empty.

### Project
- Added Pester tests in `Tests/` for both modules and for the changed functions of the 02 and 03 scripts (Pester v4-compatible syntax). The script tests parse the script and load only the functions under test, so the workflow does not run.
- Added this changelog.
