<#
.SYNOPSIS
    Extrahiert alle Tag-Notizen aus .calnotes\notes.db und verknüpft sie mit metadata.db.

.DESCRIPTION
    Das Skript verbindet die notes.db aus dem Ordner '.calnotes' mit der metadata.db
    und speichert die Notizen (nur Tag und NoteText) als JSON-Datei ab.
    Der Dateiname wird automatisch mit aktuellem Datum und Uhrzeit versehen.
    Aus dem NoteText wird die erste Zeile (Tag-Name) entfernt, sodass nur die Definition bleibt.

.PARAMETER OutputPath
    Optionaler benutzerdefinierter Dateipfad. Wird dieser weggelassen, wird der Dateiname
    automatisch basierend auf dem aktuellen Zeitstempel generiert.

.NOTES
    PowerShell-Version: 5.1+
    Version: 2.1
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$OutputPath
)

# =====================================================================
# Konfiguration
# =====================================================================

# Mögliche Calibre Portable Pfade (erster Treffer wird verwendet)
$CalibrePaths = @(
    "E:\HiDrive\PortableApps\Calibre Portable"
    "D:\HiDrive\PortableApps\Calibre Portable"
)

# Name der Bibliothek
$LibraryName = "Calibre Library"

# Ausgabeverzeichnis = Skriptverzeichnis
$ScriptDir = $PSScriptRoot

# =====================================================================
# Ab hier keine Änderungen
# =====================================================================

$ErrorActionPreference = "Stop"

# Export-Unterverzeichnis erstellen, falls nicht vorhanden
$ExportDir = Join-Path $ScriptDir "Export"
if (-not (Test-Path $ExportDir)) {
    New-Item -Path $ExportDir -ItemType Directory | Out-Null
}

# Calibre Portable Pfad ermitteln
$CalibrePortablePath = $null
foreach ($Path in $CalibrePaths) {
    if (Test-Path $Path) {
        $CalibrePortablePath = $Path
        break
    }
}

if (-not $CalibrePortablePath) {
    Write-Error "Kein Calibre Portable gefunden. Geprüfte Pfade:`n$($CalibrePaths -join "`n")"
    return
}

# Bibliothekspfad
$LibraryPath = Join-Path $CalibrePortablePath $LibraryName
if (-not (Test-Path $LibraryPath)) {
    Write-Error "Bibliothekspfad nicht gefunden: '$LibraryPath'"
    return
}

# calibre-debug.exe im Portable-Verzeichnis suchen
$CalibreDebugExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibre-debug.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $CalibreDebugExe) {
    Write-Error "calibre-debug.exe wurde in '$CalibrePortablePath' nicht gefunden."
    return
}

# Datenbankpfade auflösen
$FullMetaDb  = Join-Path $LibraryPath "metadata.db"
$FullNotesDb = Join-Path $LibraryPath ".calnotes\notes.db"

if (-not (Test-Path $FullMetaDb)) {
    Write-Error "Die Datei 'metadata.db' wurde unter '$FullMetaDb' nicht gefunden."
    return
}

if (-not (Test-Path $FullNotesDb)) {
    Write-Error "Die Datei 'notes.db' wurde unter '$FullNotesDb' nicht gefunden."
    return
}

# Ausgabedatei
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $Timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $OutputPath = Join-Path $ExportDir "Calibre_Tag_Export_$Timestamp.json"
}

$FullOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$TempDir = Join-Path $ScriptDir ".tmp"
if (-not (Test-Path -Path $TempDir -PathType Container)) {
    New-Item -Path $TempDir -ItemType Directory | Out-Null
}
$TempScript = Join-Path $TempDir "calibre_export_temp.py"

Write-Host "Gefunden:   $CalibrePortablePath"
Write-Host "Tool:       $($CalibreDebugExe.FullName)"
Write-Host "Bibliothek: $LibraryPath"
Write-Host "Metadata:   $FullMetaDb"
Write-Host "Notes DB:   $FullNotesDb"
Write-Host "Ausgabe:    $FullOutputPath"

# Python-Skript zur Abfrage
$PythonScriptContent = @"
import json
import sqlite3
import sys

meta_db = r"$FullMetaDb"
notes_db = r"$FullNotesDb"
output_path = r"$FullOutputPath"

def strip_tag_name(note_text):
    """Entfernt die erste Zeile (Tag-Name) aus dem NoteText."""
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
    sys.exit(1)
"@

try {
    Set-Content -Path $TempScript -Value $PythonScriptContent -Encoding UTF8 -Force
    $Result = & $CalibreDebugExe.FullName $TempScript

    if ($Result -like "*SUCCESS:*") {
        $Count = ($Result -split "SUCCESS:")[1].Trim()
        Write-Host ""
        Write-Host "Export erfolgreich abgeschlossen. $Count Eintraege in '$FullOutputPath' gespeichert."
    } else {
        Write-Error "Fehler beim Exportieren der Daten: $Result"
    }
}
catch {
    Write-Error "Fehler beim Ausfuehren von calibre-debug: $_"
}
finally {
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
}