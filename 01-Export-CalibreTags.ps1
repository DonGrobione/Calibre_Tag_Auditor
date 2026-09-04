<#
.SYNOPSIS
    Extract Calibre tag notes and save them as JSON.

.DESCRIPTION
    Connects Calibre .calnotes/notes.db with the library metadata.db and exports tag notes as JSON. The first line of each note is removed so the output contains only the tag definition.
    Uses calibre-debug.exe (Calibre's embedded Python interpreter) to query both SQLite databases via ATTACH. The temporary Python script is written to $env:TEMP and deleted after execution.
    Script output (info, warnings, and errors) is written both to terminal and to the central log via Modules\Write-Log.psm1. A finally block removes the logging aliases before the script exits so they cannot leak into the calling shell.

.PARAMETER OutputPath
    Optional custom output file path. If omitted, a timestamped file is created in the 01-Export folder.

.NOTES
    Version: 3.1
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$OutputPath
)

$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '.\\Modules\\Write-Log.psm1'"
}

Import-Module -Name $WriteLogModulePath -Force

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "01-CalibreExport.config.json"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Required configuration file not found: '.\\01-CalibreExport.config.json'"
}

try {
    $CalibreConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "Unable to read Calibre configuration '.\\01-CalibreExport.config.json': $($_.Exception.Message)"
}

$CalibrePaths = @($CalibreConfig.CalibrePaths)
$LibraryName = [string]$CalibreConfig.LibraryName

if ($CalibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($LibraryName)) {
    throw "Calibre configuration '.\\01-CalibreExport.config.json' must define CalibrePaths and LibraryName."
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
        $displayCalibrePaths = @($CalibrePaths | ForEach-Object { ConvertTo-DisplayPath -Path $_ -BasePath $PSScriptRoot })
        throw "Calibre Portable was not found. Checked paths:`n$($displayCalibrePaths -join "`n")"
    }

    $LibraryPath = Join-Path $CalibrePortablePath $LibraryName
    if (-not (Test-Path $LibraryPath)) {
        throw "Library path not found: '$(ConvertTo-DisplayPath -Path $LibraryPath -BasePath $PSScriptRoot)'"
    }

    $CalibreDebugExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibre-debug.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $CalibreDebugExe) {
        throw "calibre-debug.exe was not found in '$(ConvertTo-DisplayPath -Path $CalibrePortablePath -BasePath $PSScriptRoot)'."
    }

    # Define the paths to the Calibre metadata database and notes database.
    $FullMetaDb = Join-Path $LibraryPath "metadata.db"
    $FullNotesDb = Join-Path $LibraryPath ".calnotes\notes.db"

    if (-not (Test-Path $FullMetaDb)) {
        throw "The file 'metadata.db' was not found: '$(ConvertTo-DisplayPath -Path $FullMetaDb -BasePath $PSScriptRoot)'"
    }

    if (-not (Test-Path $FullNotesDb)) {
        throw "The file 'notes.db' was not found: '$(ConvertTo-DisplayPath -Path $FullNotesDb -BasePath $PSScriptRoot)'"
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $OutputPath = Join-Path $ExportDir "02-Export-CalibreTags_$Timestamp.json"
    }

    # Prepare the target path and a temporary Python script for the data export.
    $FullOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $TempDir = $env:TEMP
    $TempScript = Join-Path $TempDir "calibre_export_temp.py"

    Write-Host "Found:      $(ConvertTo-DisplayPath -Path $CalibrePortablePath -BasePath $PSScriptRoot)"
    Write-Host "Tool:       $(ConvertTo-DisplayPath -Path $CalibreDebugExe.FullName -BasePath $PSScriptRoot)"
    Write-Host "Library:    $(ConvertTo-DisplayPath -Path $LibraryPath -BasePath $PSScriptRoot)"
    Write-Host "Metadata:   $(ConvertTo-DisplayPath -Path $FullMetaDb -BasePath $PSScriptRoot)"
    Write-Host "Notes DB:   $(ConvertTo-DisplayPath -Path $FullNotesDb -BasePath $PSScriptRoot)"
    Write-Host "Output:     $(ConvertTo-DisplayPath -Path $FullOutputPath -BasePath $PSScriptRoot)"

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
        Write-Host "Export completed successfully. $Count entries saved to '$(ConvertTo-DisplayPath -Path $FullOutputPath -BasePath $PSScriptRoot)'."
    } else {
        throw "Data export failed: $Result"
    }
}
catch {
    Write-Error $_.Exception.Message
    throw
}
finally {
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
    # Remove the logging aliases so they cannot leak into the caller's scope.
    Remove-Item -Path Alias:Write-Host, Alias:Write-Warning, Alias:Write-Error -ErrorAction SilentlyContinue
}
