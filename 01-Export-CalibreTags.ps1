<#
.SYNOPSIS
    Extract Calibre tag notes and save them as JSON.

.DESCRIPTION
    Connects Calibre .calnotes/notes.db with the library metadata.db and exports tag notes as JSON. The first line of each note is removed so the output contains only the tag definition.
    Uses calibre-debug.exe (Calibre's embedded Python interpreter) to query both SQLite databases via ATTACH. The temporary Python script is written to $env:TEMP and deleted after execution.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 2.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

.PARAMETER OutputPath
    Optional custom output file path. If omitted, a timestamped file is created in the 01-Export folder.

.NOTES
    Version: 3.4
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$OutputPath
)

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

$CalibreEnvironmentModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Environment.psd1"
if (-not (Test-Path -LiteralPath $CalibreEnvironmentModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Environment.psd1'"
}

Import-Module -Name $CalibreEnvironmentModulePath -Force

# Start an own log session only when the script is not running inside the pipeline's session. -MaxFileSizeMB 0 turns off size-based rotation, so each run stays in one log file.
$ownsLogSession = -not (Test-LogSession)
if ($ownsLogSession) {
    Start-Log -LogDirectory 'Calibre_Tag_Auditor' -MaxFileSizeMB 0
}

try {
    # Enable strict error handling for the tag export workflow.
    $ErrorActionPreference = "Stop"

    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "01-CalibreExport.config.json"
    $CalibreConfig = Get-CalibreConfiguration -ConfigurationPath $ConfigPath

    $ScriptDir = $PSScriptRoot

    # Create the export folder and remove older tag export files.
    $ExportDir = Join-Path $ScriptDir "01-Export"
    if (-not (Test-Path $ExportDir)) {
        New-Item -Path $ExportDir -ItemType Directory | Out-Null
    }

    Get-ChildItem -Path $ExportDir -Filter "02-Export-CalibreTags_*.json" -File |
    Remove-Item -Force

    $CalibreEnvironment = Get-CalibreEnvironment -Configuration $CalibreConfig
    $CalibrePortablePath = $CalibreEnvironment.PortablePath
    $LibraryPath = $CalibreEnvironment.LibraryPath
    $CalibreDebugExe = Get-CalibreExecutable -CalibrePath $CalibrePortablePath -Name 'calibre-debug.exe'

    # Define the paths to the Calibre metadata database and notes database.
    $FullMetaDb = $CalibreEnvironment.MetadataDbPath
    $FullNotesDb = $CalibreEnvironment.NotesDbPath

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

    Write-ScriptLog "Found:      $(ConvertTo-DisplayPath -Path $CalibrePortablePath -BasePath $PSScriptRoot)"
    Write-ScriptLog "Tool:       $(ConvertTo-DisplayPath -Path $CalibreDebugExe.FullName -BasePath $PSScriptRoot)"
    Write-ScriptLog "Library:    $(ConvertTo-DisplayPath -Path $LibraryPath -BasePath $PSScriptRoot)"
    Write-ScriptLog "Metadata:   $(ConvertTo-DisplayPath -Path $FullMetaDb -BasePath $PSScriptRoot)"
    Write-ScriptLog "Notes DB:   $(ConvertTo-DisplayPath -Path $FullNotesDb -BasePath $PSScriptRoot)"
    Write-ScriptLog "Output:     $(ConvertTo-DisplayPath -Path $FullOutputPath -BasePath $PSScriptRoot)"

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
        Write-Information -MessageData '' -InformationAction Continue
        Write-ScriptLog "Export completed successfully. $Count entries saved to '$(ConvertTo-DisplayPath -Path $FullOutputPath -BasePath $PSScriptRoot)'."
    } else {
        throw "Data export failed: $Result"
    }
}
catch {
    Write-ScriptLog -Level ERROR -Message $_.Exception.Message -ErrorRecord $_
    throw
}
finally {
    # Stop the own log session first so a failing cleanup below cannot leave it running.
    if ($ownsLogSession) {
        Stop-Log
    }
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
}
