# Calibre Configuration
Configure the Calibre export scripts centrally in `01-CalibreExport.config.json`:

- `CalibrePaths`: Ordered list of Calibre Portable installation directories. The first existing path is used.
- `LibraryName`: Name of the Calibre library directory inside the selected Calibre Portable directory. Default: `Calibre Library`.
- `BooksPerFile`: Maximum number of books in each JSON export file. Set to `0` to export all books to one file. Default: `10`. Keep this number low to prevent timeouts or other LLM processing issues. Each file is written as soon as it is full, so the files finished before an interrupted export are kept.
- `ChangedWithinDays`: Exports only books changed within this number of calendar days (local time): `0` = all books, `1` = today since 00:00, `2` = today and yesterday, and so on. The cutoff is local midnight of (today − (N − 1)), so the time of day the run starts does not matter. Default: `1`. The parameter `-ChangedWithinDays` of `Invoke-CalibreToolsPipeline.ps1` and `01-Export-CalibreBooks.ps1` overrides this value for a single run without changing the file (see [Quick Start](../README.md#quick-start)).
- `DebugBookExport`: Set to `true` to ignore `ChangedWithinDays` and export only the 10 most recently changed books, split into files of `BooksPerFile` books. Use it for small test runs. Books without a valid modification date are excluded. Default: `false`.

Depending on the size of your library and number of tags, changing the value of `ChangedWithinDays` may use a lot more tokens. Books without text (e.g. comics) also cause Google Search queries the first time they are checked (see [Books Without Text](../README.md#books-without-text)).

>A full run on my library (~2300 books), including the creation of all content profiles, took about 37 hours and cost a considerable amount in tokens.
