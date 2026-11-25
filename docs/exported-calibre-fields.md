# Exported Calibre Fields
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
- `ContentStatus`: `Text` (the book has `BookContent`), `NoText` (no or almost no extractable text, or no supported book file, see [Books Without Text](../README.md#books-without-text)), or `Failed` (the extraction failed).
- `ContentHash`: SHA256 hash that identifies what a content profile was written from: the book text for books with text, or the identity metadata (title, author, series, series index, identifiers, description) for books without text.
- `ContentProfile`, `ContentProfileVersion`, `ContentProfileSource`, `ContentProfileSources`, `ContentProfileTagHashes`: the stored content profile of the book, or empty when there is none (see [Content Profiles](content-profiles.md)). The source is `Text`, `Web`, or `WebNotFound`; the sources list the cited web pages of a web profile; the tag hashes are fingerprints of the tag definitions that were already checked against the book's source (see [Profile Gaps](content-profiles.md#profile-gaps)).

The Calibre field `last_modified` is used only to sort the books, apply the `ChangedWithinDays` filter, and check whether a cached book is still current. The field `formats` is used only to find the book files: the export uses exactly the file paths that Calibre lists for the book and ignores paths outside the library folder. Neither field is included in the exported book JSON files.
