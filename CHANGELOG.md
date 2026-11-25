# Changelog
All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the modules use [Semantic Versioning](https://semver.org/). Module versions are maintained in their manifests (`Modules/*.psd1`); standalone scripts keep their version in their comment-based help block.

## 2026-11-25

### Scripts
- `ChangedWithinDays` now counts calendar days in local time instead of a rolling window of N × 24 hours, so the time of day a run starts no longer changes which books are exported: `0` = all books, `1` = today since 00:00, `2` = today and yesterday, and so on. With tests.
  - `01-Export-CalibreBooks.ps1` 5.3: new function `Get-ChangedSinceDate` returns local midnight of (today − (N − 1)) as cutoff. The startup log line and the no-books warning show the cutoff date.
  - `Invoke-CalibreToolsPipeline.ps1` 1.22: help text for `-ChangedWithinDays` updated.

## 2026-11-05

### Scripts
- Complete token accounting. The totals missed the tokens of interrupted runs and did not record cached or tool use tokens. With tests.
  - `02-Process-CalibreDataWithLLM.ps1` 7.5: every token count now has prompt (input, including the cached part), cached (`total_cached_tokens`, billed at a lower rate), tool use (`total_tool_use_tokens`, search results added to the input), completion (output plus thinking), and total. The total is computed as prompt + tool use + completion instead of being taken from `total_tokens`. The result files store `cached_tokens` and `tool_use_tokens` in `token_usage`, and the per-file and summary log lines show all counts with the total last. New token ledger `02-LLM-Result/LLM-TokenUsage.json`: it is updated after every Gemini response, so it also counts the requests of an export file whose processing was interrupted or repeated, which no result file holds. A new run starts it at 0; `-Resume` continues it (and rebuilds it from the result files when it is missing). New functions `Get-TokenUsageCounter`, `Format-TokenUsage`, `ConvertTo-TokenUsageRecord`, `Add-TokenUsageRecord`, `Initialize-TokenLedger`, `Save-TokenLedger`, and `Add-TokenLedgerUsage`.
  - `Invoke-CalibreToolsPipeline.ps1` 1.21: the summary reads the token counts from the token ledger (from the result files, with a warning, when there is none) and shows the books without audit result, the web search queries, the tokens of interrupted or repeated requests, prompt tokens with their cached part, tool use tokens, completion tokens, and as last line the total, which is the sum of all billed token counts. A new run deletes the ledger of the old run. New functions `Add-TokenUsageCount` and `Get-RunTokenSummary`.

## 2026-11-02

### Modules
- `Calibre.Console` 1.2.0: added `Format-Duration`, which formats a time span as `hh:mm:ss` with the total number of hours (e.g. `31:23:48`). With tests.

### Scripts
- `Invoke-CalibreToolsPipeline.ps1` 1.18 and `02-Process-CalibreDataWithLLM.ps1` 7.2: fixed: runs of 24 hours or longer showed a duration shortened by whole days (a 31:23:48 run was logged as `07:23:48`), because the TimeSpan format `hh` is the hours component (0-23), not the total hours. Both now use `Format-Duration`. The pipeline summary also shows Start and End with the date, so runs over midnight are recognisable.
- `02-Process-CalibreDataWithLLM.ps1` 7.3: books without audit result no longer disappear silently. Every input book without a record (blocked by Gemini for prohibited content, failed request, unparsable response, or left out by the LLM, as in a file that ended with `input=5, output=4` after all retries) is written to the result file as `missing_books` (Title, Author, Reason), logged by title, and listed in the run summary under "Books without audit result". A prohibited content block now logs "Gemini blocked the request for prohibited content (policy filter). The block is not retried." instead of the misleading hint about an invalid API key, model name, or payload. With tests.
- `03-Convert-LLMResults2ODS.ps1` 1.7: every entry in `missing_books` becomes a row with `ProposedAction = NOT_AUDITED` and the reason, so the book can be checked manually; the number of these rows is logged. With tests.
- `Invoke-CalibreToolsPipeline.ps1` 1.19: the summary shows the number of books without audit result. With tests.
- Resume of an interrupted run (Ctrl+C, crash, or power outage) during the LLM step or the ODS conversion. With tests.
  - `Invoke-CalibreToolsPipeline.ps1` 1.20: new switch `-Resume`. After both exports, the pipeline writes the run state file `02-LLM-Result/Pipeline-RunState.json` (run timestamp, start time, FullContent, step, status). A start without `-Resume` finds an unfinished run and asks `[R]esume / [N]ew run / [A]bort`. A resumed run skips the export steps (and the LLM step when it stopped in the ODS conversion) and keeps the original `-FullContent` setting; `-Resume` cannot be combined with `-ChangedWithinDays` or `-FullContent`. A cancelled or failed run logs how to continue it.
  - `02-Process-CalibreDataWithLLM.ps1` 7.4: new switch `-Resume`, which keeps the existing result files and skips every export file with a complete result (status not `error`). Result files are written through a `.tmp` file that is then renamed, so an interruption never leaves a truncated result. A new run removes only `LLM-Result_*.json` instead of every `*.json` file in `02-LLM-Result`.
  - `03-Convert-LLMResults2ODS.ps1` 1.8: reads only `LLM-Result_*.json`, so the run state file is not taken for a result.

## 2026-11-01

### Scripts
- `Invoke-CalibreToolsPipeline.ps1` 1.17: fixed: the pipeline aborted after a successful step with "Script '01-Export-CalibreBooks.ps1' exited with code -1". It checked `$LASTEXITCODE` after each step, but that variable holds the exit code of the last external program the step ran. When `ebook-convert.exe` failed on a book (handled: the book is `Failed`) and every later book came from the cache, the stale -1 stopped the pipeline. A step now fails only by throwing its error, as the step scripts already do. With tests.

## 2026-10-05

### Scripts
- `01-Export-CalibreBooks.ps1` 5.2: the cache file log lines say what happened to the file: `Created file: <uuid>.json` for a new cache file, `Updated file: <uuid>.json` for an overwritten one (e.g. after a title change in Calibre), and `Removed file: <uuid>.json` with the reason `(book no longer in the library)` or `(content extraction failed)`. Before, every write was logged as "Wrote cache file", so a rename looked like new files. With tests.

## 2026-10-04

### Modules
- `Calibre.TagDefinitions` removed, with its tests. The tag definition baseline was only used for one warning, and that warning needed its own module, a baseline file, an export scope file, and extra pipeline logic. The guidance on re-checking the library after a tag definition change stays in the README.

### Scripts
- Log the cache file messages as INFO instead of DEBUG, so the terminal shows them without the `DEBUG:` prefix.
  - `01-Export-CalibreBooks.ps1` 5.1: written and removed cache files (including those of deleted books). A cached book names its cache file in its book line (`Book 1/2326: Title (cached: <uuid>.json)`), without path; the separate "Read cache file" line is removed. With tests.
  - `02-Process-CalibreDataWithLLM.ps1` 7.1: stored content profiles. With tests.
- Content profiles that do not depend on the tag definitions, longer profiles from a sampled excerpt, and automatic refresh of profile gaps. The stored profiles averaged only about 205 words for 163 tags, 96% of the books were cut at the 20,000-word cap so their profiles described only the opening, and both prompts tied each profile to the tag set of the day it was written, so suggestions for new or changed tags could be missed.
  - `01-Export-CalibreBooks.ps1` 5.0: `BookContent` is a sampled excerpt (`$ExcerptSectionWordCounts`): the whole text up to 30,000 words, otherwise 18,000 words from the start, 6,000 from the middle, and 6,000 from the late part (ending at 92% of the text), separated by `[...]` lines. `$BookCacheVersion` 2, so every book is extracted again on its next export, and the new `ContentHash` drops the old text profiles. The export records carry the new field `ContentProfileTagHashes` from the cache. `DebugBookExport` exports the 10 most recently changed books (was 20) and keeps the configured `BooksPerFile` (was fixed at 5). New function `Select-ExcerptText`; `Get-BookContent` takes `-SectionWordCounts`. With tests.
  - `02-Process-CalibreDataWithLLM.ps1` 7.0: both prompts get the fixed profile facets from the new file `02-CalibreContentProfile-Checklist.txt` at the placeholder `{{CONTENT_PROFILE_CHECKLIST}}`, and the script stops when the file or the placeholder is missing. Profiles have 400 to 700 words with `absent` and `unknown` per facet; a text profile with fewer than `$MinimumProfileWords` (300) words is stored with a warning. `$ContentProfileVersion` 2, so all profiles are rebuilt. The audit response has the new key `ProfileGaps`: for books sent with a profile, every tag whose decision the profile cannot settle. Gap tags that are new or changed since the profile was written (compared by the fingerprints in `ContentProfileTagHashes`) refresh the book in the same run: a text book is audited again with its full excerpt, a book without text gets a targeted web search with the open tag definitions as focus questions. The refresh results replace the first results. The web profile request no longer sends the tag definitions. Fixed: the tag definitions were wrapped in a second array by Windows PowerShell 5.1 (`@(ConvertFrom-Json ...)`) and sent to Gemini as `[{"value":[...],"Count":n}]`; they are now sent as a plain array. The result files hold `profile_gaps` and `profile_refresh`, and the run summary shows the gaps and refreshes. New functions `Merge-ContentProfileChecklist`, `Get-TagDefinitionHashTable`, `ConvertTo-TagHashTable`, `Merge-TagHashTable`, `Select-TagDefinition`, `Get-ProfileRefreshCandidate`, and `Merge-RefreshedAuditRecord`; `Request-WebContentProfile` takes `-FocusTagDefinitions` instead of `-TagDefinitions`. With tests.
  - `02-CalibreDataLLM-Prompt.txt` and `02-CalibreWebProfile-Prompt.txt`: use the checklist, explain the excerpt sections and the facet values, and describe the `ProfileGaps` output and the focus questions. A gap tag is still decided from the profile; a refresh replaces that decision. (In a live test, keeping gap tags unchanged dropped a REMOVE that the full-text audit had made, because gaps on unchanged definitions are never refreshed again.)
  - One-time cost after the update: every exported book is extracted again and sent once with its full text, and every book without text is searched once more.
- Remove the warning about tag definitions that changed since the last full-library audit (added on 2026-10-03).
  - `01-Export-CalibreBooks.ps1` 4.10: no longer writes `01-Export/01-Export-Scope.json`.
  - `01-Export-CalibreTags.ps1` 3.7: no longer compares the definitions with the baseline `01-Cache/TagDefinitions.json`.
  - `02-Process-CalibreDataWithLLM.ps1` 6.5: no longer saves the baseline after a full-library run. `Test-TagDefinitionBaselineUpdate` and the error file counter are removed.
  - `Invoke-CalibreToolsPipeline.ps1` 1.16: when no book export file was written, all remaining steps are skipped, including the tag export. `Test-PipelineStepSkipped`, `Get-TagDefinitionChangeWarning`, and `Write-TagDefinitionChangeSummary` are removed. With tests.
- Files left over from earlier runs (`01-Export/01-Export-Scope.json`, `01-Cache/TagDefinitions.json`) are not used any more and can be deleted.

## 2026-10-03

### Modules
- `Calibre.Text` 1.0.0: new module. `Repair-MojibakeText` moved here from `02-Process-CalibreDataWithLLM.ps1` unchanged, so the LLM step and the ODS step use the same strict per-sequence repair. With tests (moved from the LLM step tests, plus a test with Japanese text).
- `Calibre.Environment` 1.3.1: `Get-CalibreConfiguration` reads `01-CalibreExport.config.json` as UTF-8. Before, Windows PowerShell 5.1 read a file without BOM in the ANSI code page, so a non-ASCII path (e.g. `D:\Bücher`) was garbled and not found. With tests.
- `Calibre.TagDefinitions` 1.0.0: new module. `Read-TagDefinitionFile`, `Get-TagDefinitionBaseline`, `Save-TagDefinitionBaseline`, `Compare-TagDefinition`, and `Format-TagDefinitionChange` keep the baseline of the tag definitions of the last full-library audit and report added, removed, and changed tags. Tag names are matched without regard to case, and whitespace-only edits of a note are ignored. Errors carry the IDs `TagDefinitionFileNotFound`, `TagDefinitionFileUnreadable`, and `TagDefinitionBaselineNotWritten`. With tests.

### Scripts
- `02-Process-CalibreDataWithLLM.ps1` 6.4: more resilient Gemini requests. In the run of 2026-10-03, a DNS failure and three prohibited content blocks each left a whole file of 5 books without audit.
  - `Invoke-GeminiRequest` retries connection failures without HTTP response (DNS lookup, connect, send/receive, timeout) with exponential backoff (`$ConnectionRetryBaseSeconds`, `$ConnectionRetryMaxSeconds`), and HTTP 500 and 502 like 503. Before, these failed at once. New function `Get-ConnectionFailureStatus`.
  - When Gemini blocks the request of a file with several books for prohibited content (HTTP 400), the books are sent again one at a time with their original `BookId`. The results are merged into one result file; a book that is blocked again gets no record and is named in `validation_error`, and the file is saved with status `warning`. New functions `Test-ProhibitedContentError`, `ConvertTo-BookAuditPayload`, `Invoke-BookAuditRequest` (the former inline content-validation retry loop), and `Invoke-SingleBookAudit`. With tests.
- Log the cache files that are processed. Before, the log named a cache file only when it could not be written or deleted.
  - `01-Export-CalibreBooks.ps1` 4.9: logs every cache file that is read, written, or deleted as outdated as a DEBUG entry with its project-relative path. With tests.
  - `02-Process-CalibreDataWithLLM.ps1` 6.3: `Update-BookCacheProfile` logs every cache file that receives a content profile as a DEBUG entry with the profile source (`Text`, `Web`, `WebNotFound`), the book title, and the project-relative path. With tests.
- Correct UTF-8 handling throughout the project.
  - Fixed in `01-Export-CalibreBooks.ps1` 4.8: `ConvertTo-JsonUtf8` turned every `\uXXXX` escape back into a character. Control characters (which PowerShell 5.1 writes as `\u0001` etc.) became raw control characters, and a literal backslash-u in the book text (e.g. in a book about regular expressions) became an invalid escape. Both made export and cache files invalid JSON, so such books were extracted again on every run (2 of 2,115 cache files). Now only the escapes for `&`, `'`, `<`, and `>` are turned back, as in `ConvertTo-CompactJson`; PowerShell 5.1 writes all other characters unescaped anyway. The broken cache files are rebuilt on the next export of these books. With tests.
  - Fixed in `03-Convert-LLMResults2ODS.ps1` 1.6: `Repair-Mojibake` and `Repair-JsonText` re-encoded the whole text through ISO-8859-1 as soon as it contained `Ã` or `Â`, and the check ignored case. A correct `ã` or `â` (e.g. "São Paulo") therefore destroyed every character outside ISO-8859-1 in that value (dashes, typographic quotes, Japanese titles became `?`) and turned correct umlauts into `�` in the review sheet. Both now use `Repair-MojibakeText` from `Calibre.Text`; `Repair-Mojibake` is removed. The temporary CSV is written as UTF-8 without BOM, because the LibreOffice import filter sets UTF-8 explicitly. With tests.
  - `01-Export-CalibreTags.ps1` 3.6: the temporary Python script is written as UTF-8 without BOM, Python prints error messages ASCII-only (PowerShell decodes the output with the console code page), and the metadata database path is bound as SQL parameter instead of being embedded in the `ATTACH` statement, so quotes in the library path cannot break it. With tests.
  - `02-Process-CalibreDataWithLLM.ps1`: imports `Calibre.Text` for `Repair-MojibakeText`.
- Web content profiles for books without text. Comics, manga, and graphic novels made of images (also as EPUB, PDF, AZW3, or MOBI) have no extractable text, so Gemini received only title, author, and tags, and could only mark them as uncertain on every run. They were also never cached, so their extraction was repeated on every run.
  - `01-Export-CalibreBooks.ps1` 4.7: new field `ContentStatus` (`Text`, `NoText`, `Failed`). Books with fewer than 500 extracted words (`$MinimumContentWords`) or without a supported book file get `NoText` and no `BookContent`. They are cached again, and their `ContentHash` is the hash of the identity metadata, so a corrected title, ISBN, or description leads to a new web profile. Only failed extractions stay uncached. The Calibre field `comments` is exported as plain-text `Description`. The export records carry `ContentProfileSource` and `ContentProfileSources` from the cache. `$BookCacheVersion` is unchanged, so no book is extracted again; a cached short text is reclassified and its cache file rewritten. New functions `Get-MetadataHash`, `Get-WordCount`, and `ConvertTo-PlainText`, with tests.
  - `02-Process-CalibreDataWithLLM.ps1` 6.2: before the tag audit of each file, every book without text and without a current web profile is sent in its own request with the `google_search` tool and the new prompt `02-CalibreWebProfile-Prompt.txt`. The profile is stored in the cache with `ContentProfileSource` `Web` and the cited sources; an unidentified work gets a `WebNotFound` marker, so it is not searched again until its metadata changes or `-FullContent` is used. The tag audit request never searches; it sends web profiles with `ContentProfileSource` `Web`, also with `-FullContent`. `Update-BookCacheProfile` now takes `-ProfileData` (profile, source, sources) instead of `-ContentProfile`. Search queries are logged per file and in total and stored in `token_usage.web_search_queries`. New functions `Get-GeminiSearchSummary`, `Test-NoTextBook`, `Test-WebProfileRequired`, `ConvertTo-WebProfileRecord`, `ConvertFrom-WebProfileResponse`, `Add-TokenUsage`, `Request-WebContentProfile`, and `Add-BookContentProfile`, with tests. `Invoke-GeminiRequest` takes the optional `-SystemInstruction` and `-UseGoogleSearch`.
  - `02-CalibreDataLLM-Prompt.txt`: explains web profiles and removes the outdated wording about research and tool use ("confirmed by research", "no search query text").
  - `Invoke-CalibreToolsPipeline.ps1` 1.15: the summary shows the number of web search queries, which Google bills per query.
- Warn about changed tag definitions until the whole library was re-checked. Before, edited tag notes changed no book in Calibre, so normal runs never applied them to the existing books, and nothing pointed this out.
  - `01-Export-CalibreTags.ps1` 3.5: compares the exported definitions with the baseline `01-Cache/TagDefinitions.json` and logs added, changed, and removed tags as warnings, with the command to re-check all books (`-ChangedWithinDays 0`, plus `-FullContent` for new tags or changed meanings). The first run saves the current definitions as baseline.
  - `01-Export-CalibreBooks.ps1` 4.6: writes `01-Export/01-Export-Scope.json`, which marks an export of all books (`ChangedWithinDays 0` without `DebugBookExport`) as full library.
  - `02-Process-CalibreDataWithLLM.ps1` 6.1: after a full-library run without error files, saves the used tag definitions as the new baseline, which ends the warning. New function `Test-TagDefinitionBaselineUpdate`, with tests.
  - `Invoke-CalibreToolsPipeline.ps1` 1.14: runs the tag export even when no book was changed, so the warning also appears on quiet days, and repeats the warning at the end of the summary. New functions `Test-PipelineStepSkipped`, `Get-TagDefinitionChangeWarning`, and `Write-TagDefinitionChangeSummary`, with tests.
- Content profiles cut the input tokens of re-checked books: the book text is about 95% of the input (about 28,000 tokens per book), and it was sent again on every re-check, e.g. after tag corrections were applied in Calibre. The last full run used 30.3M prompt tokens for 212 requests.
  - `02-CalibreDataLLM-Prompt.txt`: the response is now an object `{"Results": [...], "ContentProfiles": [...]}`. `Results` holds the result objects as before. `ContentProfiles` holds one factual 150 to 300 word summary per book that was sent with its full text, identified by a request-local `BookId`. Books sent with a profile are checked against the profile, and a concept the profile does not mention is not a reason for REMOVE.
  - `02-Process-CalibreDataWithLLM.ps1` 6.0: sends a book's content profile instead of its text when the export holds a profile of the current `$ContentProfileVersion`, and stores new profiles in `01-Cache/<uuid>.json`, only when that file still holds the same text (`ContentHash`). New switch `-FullContent` sends the full text for every book. The book data and tag definitions are sent as compact JSON, and the `\u00XX` escapes that PowerShell 5.1 writes for `&`, `'`, `<`, and `>` are turned back into characters. The result files get the field `content_profiles`; `records` is unchanged, so `03-Convert-LLMResults2ODS.ps1` needs no change. A plain array response is still accepted. New functions `ConvertTo-CompactJson`, `Test-ContentProfile`, `ConvertTo-BookAnalysisRecord`, `Update-BookCacheProfile`, and `Save-ContentProfile`, with tests.
  - `01-Export-CalibreBooks.ps1` 4.5: the export records hold `Uuid`, `ContentHash` (SHA256 of `BookContent`), `ContentProfile`, and `ContentProfileVersion`. The profile is carried over by content hash, so it survives a changed `last_modified` (e.g. a tag edit) as long as the book text is the same. Cache files written before this version get the hash when they are reused. New functions `Get-ContentHash` and `Get-CachedContentProfile`, with tests.
  - `Invoke-CalibreToolsPipeline.ps1` 1.13: new switch `-FullContent`, forwarded only to `02-Process-CalibreDataWithLLM.ps1`.
- Fixed in `02-Process-CalibreDataWithLLM.ps1` 6.0: when the input JSON of a book export file could not be parsed, the books of the previous file were sent instead.

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
