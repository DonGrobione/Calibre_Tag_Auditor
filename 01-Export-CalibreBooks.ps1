<#
.SYNOPSIS
    Export Calibre Portable metadata to JSON files.

.DESCRIPTION
    The export is configured through 01-CalibreExport.config.json. See README.md for the configuration and behavior details.
    Uses calibredb.exe from the Calibre Portable installation.
    The first 20,000 words of the primary EPUB, AZW3, MOBI, or PDF file are
    converted to normalized text and included in the BookContent JSON field.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 1.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

.NOTES
    Version: 3.4
#>

$CalibreEnvironmentModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Environment.psd1"
if (-not (Test-Path -LiteralPath $CalibreEnvironmentModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Environment.psd1'"
}

Import-Module -Name $CalibreEnvironmentModulePath -Force

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 1.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

# Start an own log session only when the script is not running inside the pipeline's session.
$ownsLogSession = -not (Test-LogSession)
if ($ownsLogSession) {
    Start-Log -LogDirectory 'Calibre_Tag_Auditor'
}

try {
    # Enable strict error handling so problems are reported immediately.
    $ErrorActionPreference = "Stop"

    # Central export settings are maintained in 01-CalibreExport.config.json.
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "01-CalibreExport.config.json"
    $CalibreConfig = Get-CalibreConfiguration -ConfigurationPath $ConfigPath
    $BooksPerFile = $CalibreConfig.BooksPerFile
    $ChangedWithinDays = $CalibreConfig.ChangedWithinDays
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
    Write-ScriptLog "Books/file: $BooksPerFile"
    Write-ScriptLog "Changed:    $ChangedWithinDays day(s)"
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

    # Query the Calibre library via calibredb, including the modification date used for descending sort order and the optional date filter.
    $JsonOutput = & $CalibredbExe.FullName list `
        --for-machine `
        --fields=id,title,authors,series,series_index,tags,identifiers,publisher,pubdate,last_modified `
        "--with-library=$LibraryPath"

    if ($LASTEXITCODE -ne 0) {
        throw "calibredb failed (exit code: $LASTEXITCODE). Output: $($JsonOutput -join "`n")"
    }

    $JsonString = $JsonOutput -join "`n"
    $Books = ConvertFrom-Json -InputObject $JsonString

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
        Write-ScriptLog -Level WARN -Message "No books were found in the library."
        return
    }

    # Index Calibre's ID-based book directories once so content extraction remains efficient for large exports.
    $BookDirectories = @{}
    Get-ChildItem -LiteralPath $LibraryPath -Directory -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.Name -match '\((\d+)\)$') {
                $BookDirectories[$Matches[1]] = $_
            }
        }

    $TotalBooks = $Books.Count
    $NeedsSplitting = ($BooksPerFile -gt 0 -and $TotalBooks -gt $BooksPerFile)

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

    # Resolves the preferred supported book file from the cached ID-based book directory.
    function Get-PrimaryBookFile {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [hashtable]$BookDirectories
        )

        if ($null -eq $Book.id) {
            return $null
        }

        $BookDirectory = $BookDirectories[[string]$Book.id]
        if (-not $BookDirectory) {
            return $null
        }

        $FormatOrder = @('.epub', '.azw3', '.mobi', '.pdf')
        $Files = @(Get-ChildItem -LiteralPath $BookDirectory.FullName -File -ErrorAction SilentlyContinue)
        foreach ($Extension in $FormatOrder) {
            $Match = $Files | Where-Object { $_.Extension -ieq $Extension } | Select-Object -First 1
            if ($Match) {
                return $Match
            }
        }

        return $null
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

    # Transform the raw data into a simple object format for JSON export.
    $Results = foreach ($Book in $Books) {
        # identifiers come back as a map (e.g. isbn/amazon/google) joined into a readable string
        $IdentifierText = $null
        if ($Book.identifiers) {
            $IdentifierText = (($Book.identifiers.PSObject.Properties | ForEach-Object {
                "$($_.Name):$($_.Value)"
            }) -join ", ")
        }

        $PrimaryBookFile = Get-PrimaryBookFile -Book $Book -BookDirectories $BookDirectories
        $BookContent = $null
        if ($PrimaryBookFile) {
            try {
                $BookContent = Get-BookContent -SourceFile $PrimaryBookFile -EbookConvertExe $EbookConvertExe
                if ($null -eq $BookContent) {
                    Write-ScriptLog -Level WARN -Message ("Could not extract content from '{0}'." -f $PrimaryBookFile.Name)
                }
            } catch {
                Write-ScriptLog -Level WARN -Message ("Could not extract content from '{0}': {1}" -f $PrimaryBookFile.Name, $_.Exception.Message)
            }
        } else {
            Write-ScriptLog -Level WARN -Message ("No supported primary book file found for '{0}'." -f $Book.title)
        }

        [PSCustomObject]@{
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
    }

    # Write the export data either to a single file or split across multiple files.
    if (-not $NeedsSplitting) {
        $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_01_$ExportDate.json"
        Write-JsonFile -Path $JsonFile -InputObject $Results -Depth 10

        Write-Information -MessageData '' -InformationAction Continue
        Write-ScriptLog "Export complete:"
        Write-ScriptLog ("  Books: {0}" -f $Results.Count)
        Write-ScriptLog ("  File:  {0}" -f (ConvertTo-DisplayPath -Path $JsonFile -BasePath $PSScriptRoot))
    } else {
        $FileCount = [Math]::Ceiling($TotalBooks / $BooksPerFile)
        $PadWidth = [Math]::Max(2, $FileCount.ToString().Length)
        $CurrentFile = 0
        $StartIndex = 0

        while ($StartIndex -lt $TotalBooks) {
            $CurrentFile++
            $EndIndex = [Math]::Min($StartIndex + $BooksPerFile, $TotalBooks) - 1
            $Batch = $Results[$StartIndex..$EndIndex]
            $Suffix = $CurrentFile.ToString("D$PadWidth")
            $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_${Suffix}_$ExportDate.json"

            Write-JsonFile -Path $JsonFile -InputObject $Batch -Depth 10

            Write-ScriptLog ("  File {0}/{1}: Books {2}-{3} ({4}) -> {5}" -f `
                $CurrentFile, $FileCount, ($StartIndex + 1), ($EndIndex + 1), $Batch.Count, (ConvertTo-DisplayPath -Path $JsonFile -BasePath $PSScriptRoot))

            $StartIndex += $BooksPerFile
        }

        Write-Information -MessageData '' -InformationAction Continue
        Write-ScriptLog "Export complete:"
        Write-ScriptLog ("  Books:   {0}" -f $TotalBooks)
        Write-ScriptLog ("  Files:   {0}" -f $FileCount)
        Write-ScriptLog ("  Per file: max {0}" -f $BooksPerFile)
    }
} catch {
    Write-ScriptLog -Level ERROR -Message $_.Exception.Message -ErrorRecord $_
    throw
} finally {
    if ($ownsLogSession) {
        Stop-Log
    }
}