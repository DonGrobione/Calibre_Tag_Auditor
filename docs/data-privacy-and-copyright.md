# Data, Privacy And Copyright
This project is a tool you run yourself on your own library with your own API key. It runs no service, and it collects or sends nothing to the project author.

## What is sent to the LLM provider
- The tag audit request (`02-Process-CalibreDataWithLLM.ps1`) sends the tag definitions (tag names and their Calibre notes) and, per book, title, author, series, series index, and the current tags.
- For each book it also sends either the stored content profile (a factual summary of the book) or a text excerpt extracted from the book file. The excerpt is sent when the book has no current content profile yet, when `-FullContent` is set, or when a profile is refreshed because of new or changed tag definitions.
- For books without text (e.g. comics), a separate request sends identifying metadata (such as title, author, series, identifiers, publisher, year, and the Calibre description) and lets the model run web searches to identify the work. This request contains no book text and no tag definitions.

## How the provider handles the data
Whether the provider stores your requests, uses them to train or improve its models, or lets people review them depends on the provider, your plan, and its current terms. Before you process copyrighted book text, read your provider's terms and use a plan that does not allow training on your data.

## What stays on your computer
- `01-Export/` and `01-Cache/` hold the text excerpts and content profiles of your books, `02-LLM-Result/` and `03-ODS/` hold the audit results, and `Secrets/` holds your API key. All of them are git-ignored. Do not commit, share, or publish their contents.
- The log files in `<Documents>\Logs\Calibre_Tag_Auditor` contain book titles and authors.

## Copyright
The project contains no book content and processes only the books of the library you configure. You are responsible for being allowed to process your books this way, for example under the license terms of purchased e-books and the copyright law of your country. The project does not remove DRM. If `ebook-convert.exe` cannot read a book file, the book gets `ContentStatus` `Failed`, and none of its text is sent.

## Limiting what is sent
- Without `-FullContent`, a book that already has a current content profile is sent with its profile instead of its text.
- `ChangedWithinDays` (or the `-ChangedWithinDays` parameter) and `DebugBookExport` limit which books are exported and sent.
