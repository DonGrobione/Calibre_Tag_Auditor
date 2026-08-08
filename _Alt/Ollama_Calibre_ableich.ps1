<#
.SYNOPSIS
    Prueft Calibre-Buchexporte gegen Tag-Definitionen mittels lokaler Ollama LLM.

.DESCRIPTION
    Dieses Skript liest eine Calibre Tag-Export-CSV und beliebig viele
    Calibre Buchexport-CSVs aus einem Arbeitsverzeichnis. Fuer jede
    Buchexport-Datei wird ein konfigurierbarer Prompt an ein lokales
    Ollama-Modell gesendet. Das Modell vergleicht die zugewiesenen Tags
    jedes Buches mit den Tag-Definitionen und erstellt Aenderungsvorschlaege.

    Voraussetzungen:
      - Ollama muss installiert sein und als Dienst laufen
      - Das angegebene Modell (Standard: qwen3.6) muss gepullt sein
      - Die Ollama-API muss unter http://127.0.0.1:11434 erreichbar sein

    Ergebnisdateien erhalten denselben Timestamp wie die jeweilige
    Buchexport-Datei (z.B. Ergebnis_01_2026-08-01_16-07-23.csv).

.PARAMETER Model
    Name des Ollama-Modells.
    Standard: qwen3.6

.PARAMETER ApiUrl
    URL der Ollama Chat-API.
    Standard: http://127.0.0.1:11434/api/chat

.PARAMETER NumCtx
    Kontextfenstergroesse in Tokens.
    Standard: 131072

.PARAMETER OutputPrefix
    Praefix fuer die Ergebnisdateien.
    Standard: Ergebnis

.EXAMPLE
    .\Calibre_Tag_Checker.ps1
    Verwendet alle Standardwerte und verarbeitet alle Buchexport-Dateien
    im Export-Verzeichnis innerhalb des Skriptverzeichnisses.

.NOTES
    Autor     : (vom Nutzer anzupassen)
    Erstellt  : 01.08.2026
    Abhaengig : Ollama (https://ollama.com)
    PowerShell: 5.1+
    Version   : 1.2
#>

# Konfiguration
$ScriptDir    = $PSScriptRoot
$WorkingDir   = Join-Path $ScriptDir "Export"
$Model        = "qwen3.6"
$ApiUrl       = "http://127.0.0.1:11434/api/chat"
$NumCtx       = 131072
$OutputPrefix = "Ergebnis"

# Export-Verzeichnis prüfen
if (-not (Test-Path $WorkingDir)) {
    Write-Error "Export-Verzeichnis nicht gefunden: '$WorkingDir'"
    exit 1
}

Set-Location $WorkingDir

# PROMPT TEMPLATE (hier bearbeiten)
$promptTemplate = @"
Du bist ein Bibliothekar für Calibre-Buchdatenbanken. Du erhältst:
1. Buchliste (CSV, Semikolon-Delimiter): Titel;Autor;Serie;Buchnummer;Schlagwoerter
2. Tag-Definitionen (CSV, Komma-Delimiter): Tag,NoteText

PARSING:
- Schlagwoerter: Komma-getrennt innerhalb Zelle, Leerzeichen trimmen
- Buchnummer: "," entfernen → Integer

VERARBEITUNGSPROZESS pro Buch:

1. Web-Recherche für jedes Buch:
   Query: "[Titel] [Autor] Inhalt Genre Zusammenfassung"
   - Rechercheergebnisse = einzige Grundlage für Validierung
   - Widersprüchliche Quellen → beide in Begründung anführen
   - Keine/ungenügende Ergebnisse → "Unsicherheit: ... manuelle Prüfung empfohlen"

2. Jeweils zugewiesene Tag prüfen:
   a) Hat Tag Definition in Tag_Export.csv? → Ja (alle aus Calibre-Export)
   b) Trifft Definition auf Buchinhalt zu? (nach Recherche)
      → Nein → REMOVE vorschlagen
      → Ja → behalten

3. Fehltender Tag prüfen:
   - Nur ADD vorschlagen wenn Recherche bestätigt
   - Restriktiv um Bloat zu vermeiden

4. Serien-Bücher SEPARAT prüfen:
   - Identische Tags bei Serie ≠ automatisch korrekt
   - Jeden Band einzeln bewerten

5. Nicht-definierte Tags:
   - In Begründung kennzeichnen: "Tag [Name] hat keine Definition"

OUTPUT-FORMAT:
CSV-Codeblock, Semikolon-Delimiter, alle Felder in Anführungszeichen

Header: Titel;Autor;Vorgeschlagene_Änderung;Begründung

Änderungstypen:
- "ADD: <Tagname>"     - hinzufügen (durch Recherche bestätigt)
- "REMOVE: <Tagname>"  - entfernen (Definition passt nicht)
- "NO_CHANGES"         - keine Änderung nötig

AUSGABEREGELN:
- Jede Änderung = eigene Zeile
- Bücher mit Änderungen → keine NO_CHANGES-Zeile
- Alle Bücher dokumentieren (inkl. NO_CHANGES)

Verarbeitungssprache: Deutsch
Geschlechterform: masculine Bezeichnungen, "Protagonist"

Beispiel:

BEISPIEL-AUSGABE:
Titel;Autor;Vorgeschlagene_Änderung;Begründung
"Eisenhorn Omnibus";"Dan Abnett";"ADD: Science Fiction";"Warhammer 40k ist definiert als Grimdark Sci-Fi im WH40k-Universum; Science Fiction als Oberkategorie für technologisch geprägte Zukunftsszenarien passend"
"Eisenhorn Omnibus";"Dan Abnett";"REMOVE: Male Protagonist";"Protagonist Gregor Eisenhorn ist männlich, jedoch steht der Fokus auf Inquisition/Ermittlungsarbeit, nicht auf der Geschlechtsidentität als prägendes Merkmal"
"Ravenor Omnibus";"Dan Abnett";"ADD: Science Fiction";"Gleiches Begründungsmuster wie Eisenhorn - WH40k-Setting erfüllt Science-Fiction-Definition"
"Ravenor Omnibus";"Dan Abnett";"ADD: Male Protagonist";"Ravenor ist männlich und nach Definition als Hauptfigur zu taggen"
"Gaunt's Ghosts 14: Blood Pact";"Dan Abnett";"NO_CHANGES";"Alle Tags entsprechen ihren Definitionen nach Prüfung"
"Witcher Saga 1: The Last Wish";"Andrzej Sapkowski";"ADD: Kurzgeschichten";"The Last Wish ist eine Sammlung verknüpfter Kurzgeschichten, nicht ein durchgängiger Roman"

VERIFIKATION:
Nach der CSV-Ausgabe prüfen, dass jedes Buch aus der Eingabeliste bearbeitet wurde.
Bestätigung im Format:
"Verarbeitungsstatus: Geprüft X/Y Bücher (Y = Gesamtzahl, X = Bücher mit mindestens einer Änderung)"
"@

# 1. Neueste Calibre_Tag_Export Datei finden
$tagFile = Get-ChildItem -Path $WorkingDir -Filter "Calibre_Tag_Export_*.csv" |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if (-not $tagFile) {
    Write-Error ("Keine Calibre_Tag_Export_*.csv gefunden.")
    exit 1
}
Write-Host ("Tag-Datei: " + $tagFile.Name) -ForegroundColor Cyan
$tagContent = Get-Content $tagFile.FullName -Raw -Encoding UTF8

# 2. Alle Buchexport-Dateien finden, nach Name sortiert
$bookFiles = Get-ChildItem -Path $WorkingDir -Filter "Calibre_Buchexport_*.csv" |
             Sort-Object Name

if ($bookFiles.Count -eq 0) {
    Write-Error ("Keine Calibre_Buchexport_*.csv gefunden.")
    exit 1
}
Write-Host ("Gefunden: " + $bookFiles.Count + " Buchexport-Dateien")
Write-Host ""

# 3. Hilfsfunktionen: Nummer und Timestamp extrahieren
function Get-FileMetadata($filename) {
    $metadata = @{}
    
    # Nummer extrahieren: Calibre_Buchexport_01_...
    if ($filename -match "Calibre_Buchexport_(\d+)_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})") {
        $metadata["number"] = $matches[1]
        $metadata["timestamp"] = $matches[2]
        return $metadata
    }
    
    return $null
}

# 4. Hilfsfunktion: API-Aufruf
function Invoke-OllamaChat {
    param(
        [string]$PromptText,
        [string]$ModelName,
        [int]$CtxSize
    )

    $body = @{
        model     = $ModelName
        messages  = @(
            @{ role = "user"; content = $PromptText }
        )
        stream    = $false
        options   = @{
            num_ctx    = $CtxSize
            num_thread = 0
        }
        keep_alive = "30m"
    } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Body $body `
                     -ContentType "application/json; charset=utf-8" `
                     -TimeoutSec 3600
        return $response.message.content
    }
    catch {
        Write-Error ("API-Fehler: " + $_.Exception.Message)
        return $null
    }
}

# 5. Hauptverarbeitung
$total = $bookFiles.Count
$counter = 0

foreach ($bookFile in $bookFiles) {
    $counter++
    $fileMetadata = Get-FileMetadata $bookFile.Name

    if (-not $fileMetadata) {
        Write-Warning ("Konnte Metadaten nicht extrahieren aus: " + $bookFile.Name + " - ueberspringe.")
        continue
    }

    $fileNumber = $fileMetadata["number"]
    $timestamp = $fileMetadata["timestamp"]

    Write-Host ("[" + $counter + "/" + $total + "] Verarbeite " + $bookFile.Name + " ...") -ForegroundColor Yellow

    $bookContent = Get-Content $bookFile.FullName -Raw -Encoding UTF8

    # Prompt zusammenbauen
    $fullPrompt = $promptTemplate + "`n`n" +
                  "===================================`n" +
                  "TAG-DEFINITIONEN (aus " + $tagFile.Name + "):`n" +
                  "===================================`n" +
                  $tagContent + "`n`n" +
                  "===================================`n" +
                  "BUCHER (aus " + $bookFile.Name + "):`n" +
                  "===================================`n" +
                  $bookContent

    # API aufrufen
    $result = Invoke-OllamaChat -PromptText $fullPrompt -ModelName $Model -CtxSize $NumCtx

    if ($result) {
        # Ergebnis mit gleichem Timestamp speichern
        $outputFileName = ($OutputPrefix + "_" + $fileNumber + "_" + $timestamp + ".csv")
        $outputFile = Join-Path $WorkingDir $outputFileName
        $result | Out-File $outputFile -Encoding UTF8
        Write-Host ("  -> Gespeichert: " + $outputFileName) -ForegroundColor Green
    }
    else {
        Write-Host "  -> FEHLER, keine Antwort erhalten." -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host ("Fertig. " + $counter + " Dateien verarbeitet.") -ForegroundColor Cyan
Write-Host ("Ergebnisse gespeichert als " + $OutputPrefix + "_NN_TIMESTAMP.csv im Verzeichnis: " + $WorkingDir) -ForegroundColor Cyan