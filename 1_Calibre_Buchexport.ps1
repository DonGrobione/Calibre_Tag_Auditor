<#
.SYNOPSIS
    Calibre Portable Datenexport als CSV

.DESCRIPTION
    Exportiert Titel, Autor, Serie, Buchnummer und Schlagwörter aus einer
    Calibre Portable Bibliothek in eine JSON-Datei.
    Die Ausgabe kann in mehrere JSON-Dateien aufgeteilt werden (konfigurierbar).

.NOTES
    PowerShell-Version: 5.1+
    Version: 2.1
#>

# =====================================================================
# Konfiguration
# =====================================================================

$CalibrePaths = @(
    "E:\HiDrive\PortableApps\Calibre Portable"
    "D:\HiDrive\PortableApps\Calibre Portable"
)

$LibraryName = "Calibre Library"

# Anzahl der Bücher pro JSON-Datei.
# 0 = alle Bücher in eine einzige Datei.
# > 0 = Aufteilung in mehrere Dateien, sollte nicht mehr als 199 sein da LLM-Modelle sonst Probleme haben.
$BooksPerFile = 99

# =====================================================================
# Ab hier keine Änderungen
# =====================================================================

$ErrorActionPreference = "Stop"

# Ausgabeverzeichnis = Verzeichnis, in dem dieses Skript liegt
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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
    exit 1
}

# Bibliothekspfad validieren
$LibraryPath = Join-Path $CalibrePortablePath $LibraryName
if (-not (Test-Path $LibraryPath)) {
    Write-Error "Bibliothekspfad nicht gefunden: '$LibraryPath'"
    exit 1
}

# calibredb.exe im Portable-Verzeichnis suchen
$CalibredbExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibredb.exe" -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $CalibredbExe) {
    Write-Error "calibredb.exe wurde in '$CalibrePortablePath' nicht gefunden."
    exit 1
}

Write-Host "Gefunden:   $CalibrePortablePath"
Write-Host "Tool:       $($CalibredbExe.FullName)"
Write-Host "Bibliothek: $LibraryPath"
Write-Host "Ausgabe:    $ExportDir"

# Exportdatum mit Uhrzeit
$ExportDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# calibredb ausführen – JSON-Ausgabe abrufen
$JsonOutput = & $CalibredbExe.FullName list `
    --for-machine `
    --fields=title,authors,series,series_index,tags `
    "--with-library=$LibraryPath"

if ($LASTEXITCODE -ne 0) {
    Write-Error "calibredb fehlgeschlagen (Exit-Code: $LASTEXITCODE)."
    Write-Error ($JsonOutput -join "`n")
    exit 1
}

# JSON-String zusammensetzen und parsen
$JsonString = $JsonOutput -join "`n"
$Books = $JsonString | ConvertFrom-Json

if (-not $Books -or $Books.Count -eq 0) {
    Write-Warning "Keine Bücher in der Bibliothek gefunden."
    exit 0
}

# Gesamtzahl der Bücher
$TotalBooks = $Books.Count

# Bestimmen, ob Aufteilung stattfindet
if ($BooksPerFile -gt 0 -and $TotalBooks -gt $BooksPerFile) {
    $NeedsSplitting = $true
} else {
    $NeedsSplitting = $false
}

# Objekte mit Spaltennamen aufbauen
$Results = foreach ($Book in $Books) {
    [PSCustomObject]@{
        Titel         = $Book.title
        Autor         = $Book.authors
        Serie         = $Book.series
        Buchnummer    = $Book.series_index
        Schlagwoerter = ($Book.tags -join ", ")
    }
}

if (-not $NeedsSplitting) {

    # --- Einzelne Datei ---
    $JsonFile = Join-Path $ExportDir "Calibre_Buchexport_01_$ExportDate.json"
    $Results | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFile -Encoding UTF8

    Write-Host ""
    Write-Host "Export abgeschlossen:"
    Write-Host ("  Bücher: {0}" -f $Results.Count)
    Write-Host ("  Datei:  {0}" -f $JsonFile)

} else {

    # --- Aufteilung in mehrere Dateien ---
    $FileCount   = [Math]::Ceiling($TotalBooks / $BooksPerFile)
    $PadWidth    = [Math]::Max(2, $FileCount.ToString().Length)
    $CurrentFile = 0
    $StartIndex  = 0

    while ($StartIndex -lt $TotalBooks) {
        $CurrentFile++
        $EndIndex  = [Math]::Min($StartIndex + $BooksPerFile, $TotalBooks) - 1
        $Batch     = $Results[$StartIndex..$EndIndex]
        $Suffix    = $CurrentFile.ToString("D$PadWidth")
        $JsonFile  = Join-Path $ExportDir "Calibre_Buchexport_${Suffix}_$ExportDate.json"

        $Batch | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFile -Encoding UTF8

        Write-Host ("  Datei {0}/{1}: Bücher {2}-{3} ({4}) -> {5}" -f `
            $CurrentFile, $FileCount, ($StartIndex + 1), ($EndIndex + 1), $Batch.Count, $JsonFile)

        $StartIndex += $BooksPerFile
    }

    Write-Host ""
    Write-Host "Export abgeschlossen:"
    Write-Host ("  Bücher:    {0}" -f $TotalBooks)
    Write-Host ("  Dateien:   {0}" -f $FileCount)
    Write-Host ("  Pro Datei: max. {0}" -f $BooksPerFile)
}