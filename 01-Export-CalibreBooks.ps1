<#
.SYNOPSIS
    Export Calibre Portable metadata to JSON files.

.DESCRIPTION
    Exports title, author, series, series index, and tags from a Calibre Portable
    library into one or more JSON files in the 01-Export directory. Books are
    sorted by last modification date, newest first. By default, books modified
    within the last day are exported. Set $ChangedWithinDays to a value greater
    than 0 to change the number of days. Set it to 0 to export all books.
    The output file names include a timestamp and sequence number when split.
    Uses calibredb.exe from the Calibre Portable installation.
    Script output (info, warnings, and errors) is written both to terminal and
    to the central log via Modules\Write-Log.psm1. Errors are marked as already
    logged before rethrowing so wrapper scripts can avoid duplicate log entries.

.NOTES
    Version: 2.7
#>

# Central export settings and their descriptions are maintained in 01-CalibreExport.config.json.
$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "01-CalibreExport.config.json"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Required configuration file not found: '$ConfigPath'"
}

try {
    $CalibreConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "Unable to read Calibre configuration '$ConfigPath': $($_.Exception.Message)"
}

$CalibrePaths = @($CalibreConfig.CalibrePaths)
$LibraryName = [string]$CalibreConfig.LibraryName
$BooksPerFile = $CalibreConfig.BooksPerFile
$ChangedWithinDays = $CalibreConfig.ChangedWithinDays

if ($CalibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($LibraryName) -or
    $null -eq $BooksPerFile -or $null -eq $ChangedWithinDays) {
    throw "Calibre configuration '$ConfigPath' must define CalibrePaths, LibraryName, BooksPerFile, and ChangedWithinDays."
}


# Import central logging and enable script-scoped output wrappers.
# The wrappers keep terminal behavior but additionally create structured log entries.
$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '$WriteLogModulePath'"
}

Import-Module -Name $WriteLogModulePath -Force

# Prefix every log line with the current script name to simplify troubleshooting
# when multiple scripts write into one shared logfile.
$ScriptLogName = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { 'UnknownScript' } else { Split-Path -Path $PSCommandPath -Leaf }
$ScriptLogPrefix = "[$ScriptLogName]"

function Write-HostAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator
    )

    $joinSeparator = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    $message = (($Object | ForEach-Object { [string]$_ }) -join $joinSeparator)
    Write-Log -Message "$ScriptLogPrefix $message" -Info
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Write-WarningAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -Warn
    Microsoft.PowerShell.Utility\Write-Warning $text
}

function Write-ErrorAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -IsError
    Microsoft.PowerShell.Utility\Write-Error $text
}

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

    function Get-FirstExistingPath {
        param([string[]]$Paths)

        foreach ($Path in $Paths) {
            if (Test-Path -LiteralPath $Path) {
                return $Path
            }
        }

        return $null
    }

    # Determine the available Calibre Portable path.
    $CalibrePortablePath = Get-FirstExistingPath -Paths $CalibrePaths

    if (-not $CalibrePortablePath) {
        throw "Calibre Portable was not found. Checked paths:`n$($CalibrePaths -join "`n")"
    }

    $LibraryPath = Join-Path $CalibrePortablePath $LibraryName
    if (-not (Test-Path $LibraryPath)) {
        throw "Library path not found: '$LibraryPath'"
    }

    $CalibredbExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibredb.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $CalibredbExe) {
        throw "calibredb.exe was not found in '$CalibrePortablePath'."
    }

    Write-Host "Found:      $CalibrePortablePath"
    Write-Host "Tool:       $($CalibredbExe.FullName)"
    Write-Host "Library:    $LibraryPath"
    Write-Host "Output:     $ExportDir"
    Write-Host "Books/file: $BooksPerFile"
    Write-Host "Changed:    $ChangedWithinDays day(s)"

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
        --fields=title,authors,series,series_index,tags,last_modified `
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

    if ($ChangedWithinDays -eq 0) {
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

    # Transform the raw data into a simple object format for JSON export.
    $Results = foreach ($Book in $Books) {
        [PSCustomObject]@{
            Title       = Clear-ExportText -Value $Book.title
            Author      = Clear-ExportText -Value $Book.authors
            Series      = Clear-ExportText -Value $Book.series
            SeriesIndex = Clear-ExportText -Value $Book.series_index
            Tags        = Clear-ExportText -Value ($Book.tags -join ", ")
        }
    }

    # Write the export data either to a single file or split across multiple files.
    if (-not $NeedsSplitting) {
        $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_01_$ExportDate.json"
        Write-JsonFile -Path $JsonFile -InputObject $Results -Depth 10

        Write-Host ""
        Write-Host "Export complete:"
        Write-Host ("  Books: {0}" -f $Results.Count)
        Write-Host ("  File:  {0}" -f $JsonFile)
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
                $CurrentFile, $FileCount, ($StartIndex + 1), ($EndIndex + 1), $Batch.Count, $JsonFile)

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
    # Mark exception as already logged in this script so pipeline wrappers do not
    # write the same error to log a second time.
    if ($null -ne $_.Exception) {
        $_.Exception.Data['LoggedByScript'] = $true
    }
    throw
}