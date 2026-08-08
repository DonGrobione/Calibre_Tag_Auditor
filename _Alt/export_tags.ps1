<#
.SYNOPSIS
    Exportiert alle Schlagwörter (Tags) aus einer Calibre-Bibliothek als CSV-Datei.

.DESCRIPTION
    Nutzt die CLI-Anwendung 'calibredb.exe' von Calibre Portable, um die Kategorie
    'tags' aus der angegebenen Bibliothek auszulesen und in eine UTF-8-kodierte
    CSV-Datei zu schreiben. Der Dateiname enthält einen Zeitstempel nach ISO 8601
    (angepasst für Dateisysteme).

.OUTPUTS
    CSV-Datei im Format 'tags_export_YYYY-MM-DD_HH-mm-ss.csv' im Skriptverzeichnis.

.NOTES
    PowerShell-Version: 5.1+
#>

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
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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
    exit 1
}

# Bibliothekspfad
$LibraryPath = Join-Path $CalibrePortablePath $LibraryName
if (-not (Test-Path $LibraryPath)) {
    Write-Error "Bibliothekspfad nicht gefunden: '$LibraryPath'"
    exit 1
}

# calibredb.exe suchen
$CalibredbExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibredb.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $CalibredbExe) {
    Write-Error "calibredb.exe wurde in '$CalibrePortablePath' nicht gefunden."
    exit 1
}

Write-Host "Gefunden:   $CalibrePortablePath"
Write-Host "Tool:       $($CalibredbExe.FullName)"
Write-Host "Bibliothek: $LibraryPath"
Write-Host "Ausgabe:    $ScriptDir"

# Zeitstempel und Ausgabedatei
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$CsvFile   = Join-Path $ScriptDir "tags_export_$Timestamp.csv"

# calibredb ausführen
& $CalibredbExe.FullName list_categories -r tags --csv "--with-library=$LibraryPath" |
    Out-File -Encoding utf8 -FilePath $CsvFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "calibredb fehlgeschlagen (Exit-Code: $LASTEXITCODE)."
    exit 1
}

Write-Host ""
Write-Host "Export abgeschlossen."
Write-Host ("  Datei:  {0}" -f $CsvFile)