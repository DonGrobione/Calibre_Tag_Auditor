<#
.SYNOPSIS
    Extract Calibre tag notes and save them as JSON.

.DESCRIPTION
    Connects Calibre .calnotes/notes.db with the library metadata.db and
    exports tag notes as JSON. The first line of each note is removed so the
    output contains only the tag definition.
    Uses calibre-debug.exe (Calibre's embedded Python interpreter) to query
    both SQLite databases via ATTACH. The temporary Python script is written
    to $env:TEMP and deleted after execution.
    Script output (info, warnings, and errors) is written both to terminal and
    to the central log via Modules\Write-Log.psm1. Errors are marked as already
    logged before rethrowing so wrapper scripts can avoid duplicate log entries.

.PARAMETER OutputPath
    Optional custom output file path. If omitted, a timestamped file is created
    in the 01-Export folder.

.NOTES
    Version: 2.8
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$OutputPath
)

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

if ($CalibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($LibraryName)) {
    throw "Calibre configuration '$ConfigPath' must define CalibrePaths and LibraryName."
}

try {
    # Enable strict error handling for the tag export workflow.
    $ErrorActionPreference = "Stop"

    $ScriptDir = $PSScriptRoot

    # Create the export folder and remove older tag export files.
    $ExportDir = Join-Path $ScriptDir "01-Export"
    if (-not (Test-Path $ExportDir)) {
        New-Item -Path $ExportDir -ItemType Directory | Out-Null
    }

    Get-ChildItem -Path $ExportDir -Filter "02-Export-CalibreTags_*.json" -File |
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

    $CalibreDebugExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibre-debug.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $CalibreDebugExe) {
        throw "calibre-debug.exe was not found in '$CalibrePortablePath'."
    }

    # Define the paths to the Calibre metadata database and notes database.
    $FullMetaDb = Join-Path $LibraryPath "metadata.db"
    $FullNotesDb = Join-Path $LibraryPath ".calnotes\notes.db"

    if (-not (Test-Path $FullMetaDb)) {
        throw "The file 'metadata.db' was not found: '$FullMetaDb'"
    }

    if (-not (Test-Path $FullNotesDb)) {
        throw "The file 'notes.db' was not found: '$FullNotesDb'"
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OutputPath = Join-Path $ExportDir "02-Export-CalibreTags_$Timestamp.json"
    }

    # Prepare the target path and a temporary Python script for the data export.
    $FullOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $TempDir = $env:TEMP
    $TempScript = Join-Path $TempDir "calibre_export_temp.py"

    function Write-JsonFileUtf8 {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [string]$Content
        )

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    }

    Write-Host "Found:      $CalibrePortablePath"
    Write-Host "Tool:       $($CalibreDebugExe.FullName)"
    Write-Host "Library:    $LibraryPath"
    Write-Host "Metadata:   $FullMetaDb"
    Write-Host "Notes DB:   $FullNotesDb"
    Write-Host "Output:     $FullOutputPath"

    # The Python code reads the tag notes from the Calibre database and writes them as JSON.
    $PythonScriptContent = @"
import json
import sqlite3
import sys

meta_db = r"$FullMetaDb"
notes_db = r"$FullNotesDb"
output_path = r"$FullOutputPath"

def strip_tag_name(note_text):
    if not note_text:
        return ''

    if isinstance(note_text, bytes):
        note_text = note_text.decode('utf-8', errors='replace')

    note_text = note_text.replace('\u00ad', '')
    note_text = note_text.replace('\u200b', '')
    note_text = note_text.replace('\u200c', '')
    note_text = note_text.replace('\u200d', '')
    note_text = note_text.replace('\ufeff', '')

    lines = note_text.split('\n', 1)
    if len(lines) > 1:
        return lines[1].strip()
    return note_text.strip()

try:
    conn = sqlite3.connect(notes_db)
    cursor = conn.cursor()

    cursor.execute(f"ATTACH DATABASE '{meta_db}' AS meta;")

    query = """
    SELECT
        t.name AS Tag,
        n.searchable_text AS NoteText
    FROM meta.tags t
    INNER JOIN notes n ON n.item = t.id
    WHERE n.colname = 'tags';
    """

    cursor.execute(query)
    rows = cursor.fetchall()

    processed_rows = []
    for row in rows:
        tag, note_text = row
        clean_text = strip_tag_name(note_text)
        processed_rows.append([tag, clean_text])

    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump([
            {"Tag": tag, "NoteText": clean_text}
            for tag, clean_text in processed_rows
        ], f, ensure_ascii=False, indent=2)

    print(f"SUCCESS:{len(processed_rows)}")
    conn.close()

except Exception as e:
    print(f"ERROR:{e}")
"@

    # Write the temporary script and run it.
    Set-Content -Path $TempScript -Value $PythonScriptContent -Encoding UTF8 -Force
    $Result = & $CalibreDebugExe.FullName $TempScript

    if ($Result -like "*SUCCESS:*") {
        $Count = ($Result -split "SUCCESS:")[1].Trim()
        Write-Host ""
        Write-Host "Export completed successfully. $Count entries saved to '$FullOutputPath'."
    } else {
        throw "Data export failed: $Result"
    }
}
catch {
    Write-Error $_.Exception.Message
    # Mark exception as already logged in this script so pipeline wrappers do not
    # write the same error to log a second time.
    if ($null -ne $_.Exception) {
        $_.Exception.Data['LoggedByScript'] = $true
    }
    throw
}
finally {
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
}
