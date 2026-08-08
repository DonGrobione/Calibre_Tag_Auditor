<#
.SYNOPSIS
    Extrahiert alle Tag-Notizen aus .calnotes\notes.db und verknüpft sie mit metadata.db.

.DESCRIPTION
    Das Skript verbindet die notes.db aus dem Ordner '.calnotes' mit der metadata.db
    und speichert die Notizen (HTML und ReinTEXT) als CSV-Datei ab.
    Der Dateiname wird automatisch mit aktuellem Datum und Uhrzeit versehen.

.PARAMETER OutputPath
    Optionaler benutzerdefinierter Dateipfad. Wird dieser weggelassen, wird der Dateiname
    automatisch basierend auf dem aktuellen Zeitstempel generiert.

.NOTES
    PowerShell-Version: 5.1+
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
    $OutputPath = Join-Path $ScriptDir "Tags_NoteHTML_$Timestamp.csv"
}

$FullOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$TempScript     = Join-Path $env:TEMP "calibre_export_temp.py"

Write-Host "Gefunden:   $CalibrePortablePath"
Write-Host "Tool:       $($CalibreDebugExe.FullName)"
Write-Host "Bibliothek: $LibraryPath"
Write-Host "Metadata:   $FullMetaDb"
Write-Host "Notes DB:   $FullNotesDb"
Write-Host "Ausgabe:    $FullOutputPath"

# Python-Skript zur Abfrage
$PythonScriptContent = @"
import sqlite3
import csv
import sys

meta_db = r"$FullMetaDb"
notes_db = r"$FullNotesDb"
output_path = r"$FullOutputPath"

try:
    conn = sqlite3.connect(notes_db)
    cursor = conn.cursor()

    cursor.execute(f"ATTACH DATABASE '{meta_db}' AS meta;")

    query = """
    SELECT
        t.name AS Tag,
        n.doc AS NoteHTML,
        n.searchable_text AS NoteText
    FROM meta.tags t
    INNER JOIN notes n ON n.item = t.id
    WHERE n.colname = 'tags';
    """

    cursor.execute(query)
    rows = cursor.fetchall()

    with open(output_path, 'w', newline='', encoding='utf-8-sig') as f:
        writer = csv.writer(f)
        writer.writerow(['Tag', 'NoteHTML', 'NoteText'])
        writer.writerows(rows)

    print(f"SUCCESS:{len(rows)}")
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
        Write-Host "Export erfolgreich abgeschlossen. $Count Einträge in '$FullOutputPath' gespeichert."
    } else {
        Write-Error "Fehler beim Exportieren der Daten: $Result"
    }
}
catch {
    Write-Error "Fehler beim Ausführen von calibre-debug: $_"
}
finally {
    if (Test-Path -Path $TempScript) {
        Remove-Item -Path $TempScript -Force -ErrorAction SilentlyContinue
    }
}