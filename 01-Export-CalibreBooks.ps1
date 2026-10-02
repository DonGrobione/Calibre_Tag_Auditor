<#
.SYNOPSIS
    Export Calibre Portable metadata to JSON files.

.DESCRIPTION
    The export is configured through 01-CalibreExport.config.json. See README.md for the configuration and behavior details.
    Uses calibredb.exe from the Calibre Portable installation.
    The first 20,000 words of the primary EPUB, AZW3, MOBI, or PDF file are
    converted to normalized text and included in the BookContent JSON field.
    Each export file is written as soon as it holds BooksPerFile books (or the last book), so memory use stays small and the files finished before an interrupted run are kept.
    Every exported book is also stored in the 01-Cache folder as <uuid>.json, keyed by the Calibre UUID. When the cached last_modified value still matches Calibre, the cached BookContent is reused and ebook-convert.exe is skipped; otherwise the content is extracted again and the cache file is overwritten. Metadata is always read fresh from calibredb. On every run, cache files of books that are no longer in the Calibre library are deleted.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 2.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

.PARAMETER ChangedWithinDays
    Exports only books changed within this number of days; 0 exports all books. Overrides ChangedWithinDays from 01-CalibreExport.config.json for this run without changing the file. When omitted, the value from the configuration is used. Ignored when DebugBookExport is enabled.

.EXAMPLE
    .\01-Export-CalibreBooks.ps1
    Exports the books changed within the number of days configured in 01-CalibreExport.config.json.

.EXAMPLE
    .\01-Export-CalibreBooks.ps1 -ChangedWithinDays 7
    Exports the books changed within the last 7 days.

.NOTES
    Version: 4.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(0, 36500)]
    [int]$ChangedWithinDays
)

# Remember whether the caller overrides the configured ChangedWithinDays value.
$ChangedWithinDaysOverride = $null
if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) {
    $ChangedWithinDaysOverride = $ChangedWithinDays
}

$CalibreEnvironmentModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Environment.psd1"
if (-not (Test-Path -LiteralPath $CalibreEnvironmentModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Environment.psd1'"
}

Import-Module -Name $CalibreEnvironmentModulePath -Force

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

# Start an own log session only when the script is not running inside the pipeline's session. -MaxFileSizeMB 0 turns off size-based rotation, so each run stays in one log file.
$ownsLogSession = -not (Test-LogSession)
if ($ownsLogSession) {
    Start-Log -LogDirectory 'Calibre_Tag_Auditor' -MaxFileSizeMB 0
}

try {
    # Enable strict error handling so problems are reported immediately.
    $ErrorActionPreference = "Stop"

    # Central export settings are maintained in 01-CalibreExport.config.json.
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "01-CalibreExport.config.json"
    $CalibreConfig = Get-CalibreConfiguration -ConfigurationPath $ConfigPath
    $BooksPerFile = $CalibreConfig.BooksPerFile
    $ChangedWithinDays = $CalibreConfig.ChangedWithinDays
    $ChangedWithinDaysSource = 'config'
    if ($null -ne $ChangedWithinDaysOverride) {
        $ChangedWithinDays = $ChangedWithinDaysOverride
        $ChangedWithinDaysSource = 'parameter'
    }
    $DebugBookExport = $CalibreConfig.DebugBookExport

    if ($null -eq $BooksPerFile -or $null -eq $ChangedWithinDays) {
        throw "Calibre configuration '.\\01-CalibreExport.config.json' must define CalibrePaths, LibraryName, BooksPerFile, and ChangedWithinDays."
    }

    if ($DebugBookExport) {
        $BooksPerFile = 5
    }

    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    # Create the export folder and remove older book export files.
    $ExportDir = Join-Path $ScriptDir "01-Export"
    if (-not (Test-Path $ExportDir)) {
        New-Item -Path $ExportDir -ItemType Directory | Out-Null
    }

    Get-ChildItem -Path $ExportDir -Filter "01-Export-CalibreBooks_*.json" -File |
    Remove-Item -Force

    # Create the cache folder that holds one export file per book, keyed by the Calibre UUID.
    $CacheDir = Join-Path -Path $ScriptDir -ChildPath "01-Cache"
    if (-not (Test-Path -LiteralPath $CacheDir -PathType Container)) {
        New-Item -Path $CacheDir -ItemType Directory | Out-Null
    }

    $CalibreEnvironment = Get-CalibreEnvironment -Configuration $CalibreConfig
    $CalibrePortablePath = $CalibreEnvironment.PortablePath
    $LibraryPath = $CalibreEnvironment.LibraryPath
    $CalibredbExe = Get-CalibreExecutable -CalibrePath $CalibrePortablePath -Name 'calibredb.exe'
    $EbookConvertExe = Get-CalibreExecutable -CalibrePath $CalibrePortablePath -Name 'ebook-convert.exe'

    Write-ScriptLog "Found:      $(ConvertTo-DisplayPath -Path $CalibrePortablePath -BasePath $PSScriptRoot)"
    Write-ScriptLog "Tool:       $(ConvertTo-DisplayPath -Path $CalibredbExe.FullName -BasePath $PSScriptRoot)"
    Write-ScriptLog "Converter:  $(ConvertTo-DisplayPath -Path $EbookConvertExe.FullName -BasePath $PSScriptRoot)"
    Write-ScriptLog "Library:    $(ConvertTo-DisplayPath -Path $LibraryPath -BasePath $PSScriptRoot)"
    Write-ScriptLog "Output:     $(ConvertTo-DisplayPath -Path $ExportDir -BasePath $PSScriptRoot)"
    Write-ScriptLog "Cache:      $(ConvertTo-DisplayPath -Path $CacheDir -BasePath $PSScriptRoot)"
    Write-ScriptLog "Books/file: $BooksPerFile"
    Write-ScriptLog "Changed:    $ChangedWithinDays day(s) ($ChangedWithinDaysSource)"
    if ($DebugBookExport) {
        Write-ScriptLog "Debug:      20 books, 5 books/file"
    }

    # Create a timestamp for the output files.
    $ExportDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    # Converts an input object to a JSON string with unescaped UTF-8 unicode characters.
    function ConvertTo-JsonUtf8 {
        param(
            [Parameter(Mandatory = $true)]
            [object]$InputObject,
            [int]$Depth = 10
        )

        $json = $InputObject | ConvertTo-Json -Depth $Depth
        $json = [System.Text.RegularExpressions.Regex]::Replace($json, '\\u([0-9A-Fa-f]{4})', {
            param($match)
            $codePoint = [int]::Parse($match.Groups[1].Value, [System.Globalization.NumberStyles]::HexNumber)
            return [char]$codePoint
        })

        return $json
    }

    # Writes an object to a JSON file using UTF-8 encoding without BOM.
    function Write-JsonFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [object]$InputObject,
            [int]$Depth = 10
        )

        $json = ConvertTo-JsonUtf8 -InputObject $InputObject -Depth $Depth
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
    }

    # Returns $true when the value is a Calibre UUID in the canonical form 8-4-4-4-12 hex digits, so it can safely be used as a file name.
    function Test-CalibreUuid {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [AllowEmptyString()]
            [string]$Uuid
        )

        # \z instead of $, because $ also matches before a trailing line break.
        return ($Uuid -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z')
    }

    # Returns the path of the cache file <uuid>.json in the cache directory, or $null when the UUID is not valid.
    function Get-BookCachePath {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$CacheDirectory,
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [AllowEmptyString()]
            [string]$Uuid
        )

        if (-not (Test-CalibreUuid -Uuid $Uuid)) {
            return $null
        }

        return (Join-Path -Path $CacheDirectory -ChildPath ("{0}.json" -f $Uuid.ToLowerInvariant()))
    }

    # Returns the cached book record when the cache file exists, can be parsed, and was written for the given last_modified value; otherwise $null.
    function Get-CachedBookExport {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$LastModified
        )

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }

        try {
            $Cached = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
        } catch {
            return $null
        }

        if ($null -eq $Cached -or $null -eq $Cached.PSObject.Properties['LastModified'] -or $null -eq $Cached.PSObject.Properties['BookContent']) {
            return $null
        }

        if ([string]$Cached.LastModified -cne $LastModified) {
            return $null
        }

        return $Cached
    }

    # Writes a book record to its cache file as UTF-8 JSON without BOM.
    function Write-BookCacheFile {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [object]$Record
        )

        if ($PSCmdlet.ShouldProcess($Path, 'Write book cache file')) {
            Write-JsonFile -Path $Path -InputObject $Record -Depth 10
        }
    }

    # Deletes the cache files whose UUID file name is not in the given set of library UUIDs and returns the deleted files. Files without a UUID name (e.g. .gitkeep) are kept.
    function Remove-StaleBookCacheFile {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$CacheDirectory,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$LibraryUuids
        )

        if (-not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
            return
        }

        $KnownUuids = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($LibraryUuid in $LibraryUuids) {
            if ($LibraryUuid) {
                [void]$KnownUuids.Add($LibraryUuid)
            }
        }

        foreach ($CacheFile in @(Get-ChildItem -LiteralPath $CacheDirectory -Filter '*.json' -File)) {
            if (-not (Test-CalibreUuid -Uuid $CacheFile.BaseName) -or $KnownUuids.Contains($CacheFile.BaseName)) {
                continue
            }

            if ($PSCmdlet.ShouldProcess($CacheFile.FullName, 'Remove stale book cache file')) {
                Remove-Item -LiteralPath $CacheFile.FullName -Force -ErrorAction Stop
                $CacheFile
            }
        }
    }

    # Query the Calibre library via calibredb, including the modification date used for descending sort order and the optional date filter.
    $JsonOutput = & $CalibredbExe.FullName list `
        --for-machine `
        --fields=id,uuid,title,authors,series,series_index,tags,identifiers,publisher,pubdate,last_modified `
        "--with-library=$LibraryPath"

    if ($LASTEXITCODE -ne 0) {
        throw "calibredb failed (exit code: $LASTEXITCODE). Output: $($JsonOutput -join "`n")"
    }

    $JsonString = $JsonOutput -join "`n"
    $Books = ConvertFrom-Json -InputObject $JsonString

    # Delete cache files of books that are no longer in the library. An empty book list skips the cleanup, so a wrong or empty library cannot wipe the cache.
    $RemovedCacheFileCount = 0
    if (@($Books).Count -eq 0) {
        Write-ScriptLog -Level WARN -Message "calibredb returned no books. The cache cleanup was skipped."
    } else {
        $RemovedCacheFiles = @(Remove-StaleBookCacheFile -CacheDirectory $CacheDir -LibraryUuids @($Books | ForEach-Object { [string]$_.uuid }))
        foreach ($RemovedCacheFile in $RemovedCacheFiles) {
            Write-ScriptLog -Level DEBUG -Message ("Removed cache file of deleted book: {0}" -f $RemovedCacheFile.Name)
        }
        $RemovedCacheFileCount = $RemovedCacheFiles.Count
        Write-ScriptLog ("Cache cleanup: {0} file(s) of deleted books removed" -f $RemovedCacheFileCount)
    }

    # Parse modification dates once so invalid values cannot abort the export.
    # With a filter enabled, only valid dates within the configured period pass.
    $BooksWithDates = @($Books | ForEach-Object {
        $LastModified = [DateTimeOffset]::MinValue
        $HasValidDate = [DateTimeOffset]::TryParse(
            [string]$_.last_modified,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$LastModified)

        [PSCustomObject]@{
            Book          = $_
            LastModified  = $LastModified
            HasValidDate  = $HasValidDate
        }
    })

    if ($DebugBookExport) {
        $Books = @($BooksWithDates |
            Where-Object HasValidDate |
            Sort-Object LastModified -Descending |
            Select-Object -First 20 |
            ForEach-Object Book)
    } elseif ($ChangedWithinDays -eq 0) {
        $Books = @($BooksWithDates | Sort-Object LastModified -Descending | ForEach-Object Book)
    } else {
        $CutoffDate = [DateTimeOffset]::Now.AddDays(-$ChangedWithinDays)
        $Books = @($BooksWithDates |
            Where-Object { $_.HasValidDate -and $_.LastModified -ge $CutoffDate } |
            Sort-Object LastModified -Descending |
            ForEach-Object Book)
    }

    if (-not $Books -or $Books.Count -eq 0) {
        if ($DebugBookExport) {
            Write-ScriptLog -Level WARN -Message "No books with a valid modification date were found in the library. No book export file was written."
        }
        elseif ($ChangedWithinDays -eq 0) {
            Write-ScriptLog -Level WARN -Message "No books were found in the library. No book export file was written."
        }
        else {
            Write-ScriptLog -Level WARN -Message "No books changed within the last $ChangedWithinDays day(s). No book export file was written. Run again with a higher -ChangedWithinDays value (0 exports all books), or change ChangedWithinDays in 01-CalibreExport.config.json."
        }
        return
    }

    Write-ScriptLog ("Books to export: {0}" -f $Books.Count)

    # Index Calibre's ID-based book directories once so content extraction remains efficient for large exports.
    $BookDirectories = @{}
    Get-ChildItem -LiteralPath $LibraryPath -Directory -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '\((\d+)\)$') {
                $BookDirectories[$Matches[1]] = $_
            }
        }

    # Without splitting all books go into one file; otherwise each file holds up to BooksPerFile books.
    $TotalBooks = $Books.Count
    $BooksInFile = $TotalBooks
    if ($BooksPerFile -gt 0 -and $TotalBooks -gt $BooksPerFile) {
        $BooksInFile = $BooksPerFile
    }
    $FileCount = [int][Math]::Ceiling($TotalBooks / $BooksInFile)

    # Supported book formats in order of preference for the content extraction.
    $SupportedBookExtensions = @('.epub', '.azw3', '.mobi', '.pdf')

    # Removes invisible formatting characters and soft hyphens from a string.
    function Clear-ExportText {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }

        if ($Value -is [string]) {
            return ($Value -replace "[\u00AD\u200B\u200C\u200D\uFEFF]", '')
        }

        return $Value
    }

    # Extracts the publication year from a date string if valid.
    function Get-ExportYear {
        param([object]$PubDate)

        $Parsed = [DateTimeOffset]::MinValue
        $HasValidDate = [DateTimeOffset]::TryParse(
            [string]$PubDate,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$Parsed)

        if ($HasValidDate -and $Parsed.Year -gt 1) {
            return $Parsed.Year
        }

        return $null
    }

    # Returns all files in the cached ID-based book directory, or nothing when the book has no directory. PowerShell unrolls an empty array into no output, so callers must wrap the call in @() to get an array.
    function Get-BookFile {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [hashtable]$BookDirectories
        )

        if ($null -eq $Book.id) {
            return @()
        }

        $BookDirectory = $BookDirectories[[string]$Book.id]
        if (-not $BookDirectory) {
            return @()
        }

        return @(Get-ChildItem -LiteralPath $BookDirectory.FullName -File -ErrorAction SilentlyContinue)
    }

    # Returns the first file whose extension appears earliest in the supported extension list, or $null when none matches or no files are given.
    function Get-PrimaryBookFile {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [AllowEmptyCollection()]
            [System.IO.FileInfo[]]$Files,
            [Parameter(Mandatory = $true)]
            [string[]]$SupportedExtensions
        )

        foreach ($Extension in $SupportedExtensions) {
            $Match = $Files | Where-Object { $_.Extension -ieq $Extension } | Select-Object -First 1
            if ($Match) {
                return $Match
            }
        }

        return $null
    }

    # Converts file extensions into a unique, upper-case list without dots in input order (e.g. "EPUB, AZW3"), or "none" when the list is empty.
    function ConvertTo-FormatDisplayText {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [AllowEmptyString()]
            [string[]]$Extensions
        )

        $Formats = @($Extensions |
            Where-Object { $_ } |
            ForEach-Object { $_.TrimStart('.').ToUpperInvariant() } |
            Where-Object { $_ } |
            Select-Object -Unique)

        if ($Formats.Count -eq 0) {
            return 'none'
        }

        return ($Formats -join ', ')
    }

    # Returns the file name of a book export file; the file number is zero-padded to at least two digits or to the digit count of the file count.
    function Get-BookExportFileName {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateRange(1, [int]::MaxValue)]
            [int]$FileNumber,
            [Parameter(Mandatory = $true)]
            [ValidateRange(1, [int]::MaxValue)]
            [int]$FileCount,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$ExportDate
        )

        $PadWidth = [Math]::Max(2, $FileCount.ToString().Length)
        return ("01-Export-CalibreBooks_{0}_{1}.json" -f $FileNumber.ToString("D$PadWidth"), $ExportDate)
    }

    # Converts a book to text, normalizes whitespace, and keeps the first 20,000 words.
    function Get-BookContent {
        param(
            [Parameter(Mandatory = $true)]
            [System.IO.FileInfo]$SourceFile,
            [Parameter(Mandatory = $true)]
            [System.IO.FileInfo]$EbookConvertExe
        )

        $TempDirectory = Join-Path -Path $env:TEMP -ChildPath ("CalibreTagAuditor-" + [Guid]::NewGuid().ToString('N'))
        $TempTextFile = Join-Path -Path $TempDirectory -ChildPath 'book.txt'

        try {
            New-Item -Path $TempDirectory -ItemType Directory -Force | Out-Null
            & $EbookConvertExe.FullName $SourceFile.FullName $TempTextFile 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $TempTextFile -PathType Leaf)) {
                return $null
            }

            $RawText = [System.IO.File]::ReadAllText($TempTextFile)
            $NormalizedLines = @()
            foreach ($Line in ($RawText -split "`r?`n")) {
                $NormalizedLine = ($Line -replace '\s+', ' ').Trim()
                if ($NormalizedLine) {
                    $NormalizedLines += $NormalizedLine
                } elseif ($NormalizedLines.Count -gt 0 -and $NormalizedLines[-1] -ne '') {
                    $NormalizedLines += ''
                }
            }

            $NormalizedText = ($NormalizedLines -join "`n").Trim()
            $Words = @($NormalizedText -split '\s+' | Where-Object { $_ })
            if ($Words.Count -gt 20000) {
                $NormalizedText = $Words[0..19999] -join ' '
            }

            return $NormalizedText
        } finally {
            if (Test-Path -LiteralPath $TempDirectory -PathType Container) {
                Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Transform the raw data into a simple object format and write each export file as soon as it is full, so memory use stays small and finished files survive an interrupted run.
    $BookNumber = 0
    $CachedBookCount = 0
    $ExtractedBookCount = 0
    $FileNumber = 0
    $BatchStartNumber = 1
    $Batch = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($Book in $Books) {
        $BookNumber++

        # identifiers come back as a map (e.g. isbn/amazon/google) joined into a readable string
        $IdentifierText = $null
        if ($Book.identifiers) {
            $IdentifierText = (($Book.identifiers.PSObject.Properties | ForEach-Object {
                "$($_.Name):$($_.Value)"
            }) -join ", ")
        }

        # Reuse the cached content while Calibre's last_modified value is unchanged; otherwise extract it again.
        $LastModifiedText = [string]$Book.last_modified
        $CachePath = Get-BookCachePath -CacheDirectory $CacheDir -Uuid ([string]$Book.uuid)
        $CachedBook = $null
        if ($null -eq $CachePath) {
            Write-ScriptLog -Level WARN -Message ("Book '{0}' has no valid UUID. The cache is not used for this book." -f $Book.title)
        } else {
            $CachedBook = Get-CachedBookExport -Path $CachePath -LastModified $LastModifiedText
        }

        $BookContent = $null
        $IsCacheable = $true
        if ($null -ne $CachedBook) {
            $BookContent = $CachedBook.BookContent
            $CachedBookCount++
            Write-ScriptLog ("Book {0} of {1}: {2} (cached)" -f $BookNumber, $TotalBooks, $Book.title)
        } else {
            $BookFiles = @(Get-BookFile -Book $Book -BookDirectories $BookDirectories)
            $PrimaryBookFile = Get-PrimaryBookFile -Files $BookFiles -SupportedExtensions $SupportedBookExtensions
            if ($PrimaryBookFile) {
                Write-ScriptLog ("Book {0} of {1}: {2}" -f $BookNumber, $TotalBooks, $PrimaryBookFile.Name)
                $ExtractedBookCount++
                try {
                    $BookContent = Get-BookContent -SourceFile $PrimaryBookFile -EbookConvertExe $EbookConvertExe
                    if ($null -eq $BookContent) {
                        $IsCacheable = $false
                        Write-ScriptLog -Level WARN -Message ("Could not extract content from '{0}'." -f $PrimaryBookFile.Name)
                    }
                } catch {
                    $IsCacheable = $false
                    Write-ScriptLog -Level WARN -Message ("Could not extract content from '{0}': {1}" -f $PrimaryBookFile.Name, $_.Exception.Message)
                }
            } else {
                Write-ScriptLog ("Book {0} of {1}: {2}" -f $BookNumber, $TotalBooks, $Book.title)
                $AvailableFormats = ConvertTo-FormatDisplayText -Extensions @($BookFiles | ForEach-Object Extension)
                Write-ScriptLog -Level WARN -Message ("No supported primary book file found for '{0}'. Supported: {1}. Available: {2}." -f `
                    $Book.title, (ConvertTo-FormatDisplayText -Extensions $SupportedBookExtensions), $AvailableFormats)
            }
        }

        $BookRecord = [PSCustomObject]@{
            Title       = Clear-ExportText -Value $Book.title
            Author      = Clear-ExportText -Value $Book.authors
            Series      = Clear-ExportText -Value $Book.series
            SeriesIndex = Clear-ExportText -Value $Book.series_index
            Tags        = Clear-ExportText -Value ($Book.tags -join ", ")
            IDs         = Clear-ExportText -Value $IdentifierText
            Publisher   = Clear-ExportText -Value $Book.publisher
            Year        = Get-ExportYear -PubDate $Book.pubdate
            BookContent = $BookContent
        }
        $Batch.Add($BookRecord)

        # Store newly extracted books in the cache; failed extractions are not cached, so the next run tries again.
        if ($null -eq $CachedBook -and $null -ne $CachePath -and $IsCacheable) {
            $CacheRecord = [PSCustomObject]@{
                Uuid         = ([string]$Book.uuid).ToLowerInvariant()
                LastModified = $LastModifiedText
            }
            foreach ($Property in $BookRecord.PSObject.Properties) {
                $CacheRecord | Add-Member -MemberType NoteProperty -Name $Property.Name -Value $Property.Value
            }
            try {
                Write-BookCacheFile -Path $CachePath -Record $CacheRecord
            } catch {
                Write-ScriptLog -Level WARN -Message ("Could not write cache file '{0}': {1}" -f (ConvertTo-DisplayPath -Path $CachePath -BasePath $PSScriptRoot), $_.Exception.Message)
            }
        }

        if ($Batch.Count -lt $BooksInFile -and $BookNumber -lt $TotalBooks) {
            continue
        }

        $FileNumber++
        $JsonFile = Join-Path -Path $ExportDir -ChildPath (Get-BookExportFileName -FileNumber $FileNumber -FileCount $FileCount -ExportDate $ExportDate)
        Write-JsonFile -Path $JsonFile -InputObject $Batch.ToArray() -Depth 10
        Write-ScriptLog ("File {0}/{1}: Books {2}-{3} ({4}) -> {5}" -f `
            $FileNumber, $FileCount, $BatchStartNumber, $BookNumber, $Batch.Count, (ConvertTo-DisplayPath -Path $JsonFile -BasePath $PSScriptRoot))

        $BatchStartNumber = $BookNumber + 1
        $Batch.Clear()
    }

    Write-Information -MessageData '' -InformationAction Continue
    Write-ScriptLog "Export complete:"
    Write-ScriptLog ("  Books:    {0}" -f $TotalBooks)
    Write-ScriptLog ("  Files:    {0}" -f $FileCount)
    Write-ScriptLog ("  Per file: max {0}" -f $BooksInFile)
    Write-ScriptLog ("  Cached:   {0}" -f $CachedBookCount)
    Write-ScriptLog ("  Extracted: {0}" -f $ExtractedBookCount)
    Write-ScriptLog ("  Cache removed: {0}" -f $RemovedCacheFileCount)
} catch {
    Write-ScriptLog -Level ERROR -Message $_.Exception.Message -ErrorRecord $_
    throw
} finally {
    if ($ownsLogSession) {
        Stop-Log
    }
}