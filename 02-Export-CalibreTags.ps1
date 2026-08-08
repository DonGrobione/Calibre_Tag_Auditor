<#
.SYNOPSIS
    Extract Calibre tag notes and save them as JSON.

.DESCRIPTION
    Connects Calibre .calnotes/notes.db with the library metadata.db and
    exports tag notes as JSON. The first line of each note is removed so the
    output contains only the tag definition.

.PARAMETER OutputPath
    Optional custom output file path. If omitted, a timestamped file is created
    in the Export folder.

.NOTES
    PowerShell version: 5.1+
    Version: 2.2
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$OutputPath
)

try {
    $ErrorActionPreference = "Stop"

    $CalibrePaths = @(
        "E:\HiDrive\PortableApps\Calibre Portable"
        "D:\HiDrive\PortableApps\Calibre Portable"
    )

    $LibraryName = "Calibre Library"
    $ScriptDir = $PSScriptRoot

    $ExportDir = Join-Path $ScriptDir "Export"
    if (-not (Test-Path $ExportDir)) {
        New-Item -Path $ExportDir -ItemType Directory | Out-Null
    }

    $CalibrePortablePath = $null
    foreach ($Path in $CalibrePaths) {
        if (Test-Path $Path) {
            $CalibrePortablePath = $Path
            break
        }
    }

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
        $OutputPath = Join-Path $ExportDir "Calibre_Tag_Export_$Timestamp.json"
    }

    $FullOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $TempDir = Join-Path $ScriptDir ".tmp"
    if (-not (Test-Path -Path $TempDir -PathType Container)) {
        New-Item -Path $TempDir -ItemType Directory | Out-Null
    }
    $TempScript = Join-Path $TempDir "calibre_export_temp.py"

    Write-Host "Found:      $CalibrePortablePath"
    Write-Host "Tool:       $($CalibreDebugExe.FullName)"
    Write-Host "Library:    $LibraryPath"
    Write-Host "Metadata:   $FullMetaDb"
    Write-Host "Notes DB:   $FullNotesDb"
    Write-Host "Output:     $FullOutputPath"

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
    throw
}
finally {
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
}
