<#
.SYNOPSIS
    Export Calibre Portable metadata to JSON files.

.DESCRIPTION
    The export is configured through 01-CalibreExport.config.json. See README.md for the configuration and behavior details.
    Uses calibredb.exe from the Calibre Portable installation.
    Script output (info, warnings, and errors) is written both to terminal and to the central log via Modules\Write-Log.psm1. A finally block removes the logging aliases before the script exits so they cannot leak into the calling shell.

.NOTES
    Version: 3.0
#>

$CalibreEnvironmentModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Environment.psm1"
if (-not (Test-Path -LiteralPath $CalibreEnvironmentModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Environment.psm1'"
}

Import-Module -Name $CalibreEnvironmentModulePath -Force

# Central export settings and their descriptions are maintained in 01-CalibreExport.config.json.
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


# Import central logging. Write-HostAndLog/WarningAndLog/ErrorAndLog live in the module
# and mirror terminal output into the central log file.
$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '.\\Modules\\Write-Log.psm1'"
}

Import-Module -Name $WriteLogModulePath -Force

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

try {
    # Enable strict error handling so problems are reported immediately.
    $ErrorActionPreference = "Stop"

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

    Write-Host "Found:      $(ConvertTo-DisplayPath -Path $CalibrePortablePath -BasePath $PSScriptRoot)"
    Write-Host "Tool:       $(ConvertTo-DisplayPath -Path $CalibredbExe.FullName -BasePath $PSScriptRoot)"
    Write-Host "Library:    $(ConvertTo-DisplayPath -Path $LibraryPath -BasePath $PSScriptRoot)"
    Write-Host "Output:     $(ConvertTo-DisplayPath -Path $ExportDir -BasePath $PSScriptRoot)"
    Write-Host "Books/file: $BooksPerFile"
    Write-Host "Changed:    $ChangedWithinDays day(s)"
    if ($DebugBookExport) {
        Write-Host "Debug:      20 books, 5 books/file"
    }

    # Create a timestamp for the output files.
    $ExportDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

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

    # Query the Calibre library via calibredb, including the modification date
    # used for descending sort order and the optional date filter.
    $JsonOutput = & $CalibredbExe.FullName list `
        --for-machine `
        --fields=title,authors,series,series_index,tags,identifiers,publisher,pubdate,last_modified `
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
        Write-Warning "No books were found in the library."
        return
    }

    $TotalBooks = $Books.Count
    $NeedsSplitting = ($BooksPerFile -gt 0 -and $TotalBooks -gt $BooksPerFile)

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

    # Transform the raw data into a simple object format for JSON export.
    $Results = foreach ($Book in $Books) {
        # identifiers come back as a map (e.g. isbn/amazon/google) joined into a readable string
        $IdentifierText = $null
        if ($Book.identifiers) {
            $IdentifierText = (($Book.identifiers.PSObject.Properties | ForEach-Object {
                "$($_.Name):$($_.Value)"
            }) -join ", ")
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
        }
    }

    # Write the export data either to a single file or split across multiple files.
    if (-not $NeedsSplitting) {
        $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_01_$ExportDate.json"
        Write-JsonFile -Path $JsonFile -InputObject $Results -Depth 10

        Write-Host ""
        Write-Host "Export complete:"
        Write-Host ("  Books: {0}" -f $Results.Count)
        Write-Host ("  File:  {0}" -f (ConvertTo-DisplayPath -Path $JsonFile -BasePath $PSScriptRoot))
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

            Write-Host ("  File {0}/{1}: Books {2}-{3} ({4}) -> {5}" -f `
                $CurrentFile, $FileCount, ($StartIndex + 1), ($EndIndex + 1), $Batch.Count, (ConvertTo-DisplayPath -Path $JsonFile -BasePath $PSScriptRoot))

            $StartIndex += $BooksPerFile
        }

        Write-Host ""
        Write-Host "Export complete:"
        Write-Host ("  Books:   {0}" -f $TotalBooks)
        Write-Host ("  Files:   {0}" -f $FileCount)
        Write-Host ("  Per file: max {0}" -f $BooksPerFile)
    }
} catch {
    Write-Error $_.Exception.Message
    throw
} finally {
    # Remove the logging aliases so they cannot leak into the caller's scope.
    Remove-Item -Path Alias:Write-Host, Alias:Write-Warning, Alias:Write-Error -ErrorAction SilentlyContinue
}