<#
.SYNOPSIS
    Prüft Calibre-Buchexporte gegen Tag-Definitionen mittels Mistral Large 3 API mit Web-Search.
.NOTES
    PowerShell: 5.1
#>

# TLS 1.2 erzwingen
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Pfade definieren
$ScriptDir           = $PSScriptRoot
$ExportDir           = Join-Path -Path $ScriptDir -ChildPath "Export"
$OutputDir           = Join-Path -Path $ScriptDir -ChildPath "Ergebnis"
$ApiKeyFile          = Join-Path -Path $ScriptDir -ChildPath ".secrets\Mistral_API.txt"
$PromptFile          = Join-Path -Path $ScriptDir -ChildPath "LLM_Calibre_ableich_Prompt.txt"

$Model               = "mistral-large-latest"
$AgentsUrl           = "https://api.mistral.ai/v1/agents"
$ConversationsUrl    = "https://api.mistral.ai/v1/conversations"
$AgentIdFile         = Join-Path -Path $ScriptDir -ChildPath ".secrets\Mistral_Agent_Id.txt"
$ApiTimeoutSec       = 300
$EnableDebugLogging  = $false

# 2. Ordner & Eingabedateien prüfen
if (-not (Test-Path -Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

if (-not (Test-Path -Path $ApiKeyFile) -or -not (Test-Path -Path $PromptFile)) {
    Write-Error "Fehler: API-Key oder Prompt-Datei fehlt im Skriptverzeichnis."
    exit 1
}

if (-not (Test-Path -Path (Join-Path -Path $ScriptDir -ChildPath ".secrets"))) {
    New-Item -Path (Join-Path -Path $ScriptDir -ChildPath ".secrets") -ItemType Directory | Out-Null
}

$ApiKey       = (Get-Content -Path $ApiKeyFile -Raw -Encoding UTF8).Trim()
$PromptSystem = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()

# 3. JSON-Dateien aus Export-Ordner laden
$tagFile = Get-ChildItem -Path $ExportDir -Filter "Calibre_Tag_Export_*.json" |
           Sort-Object -Property LastWriteTime -Descending |
           Select-Object -First 1

$bookFiles = Get-ChildItem -Path $ExportDir -Filter "Calibre_Buchexport_*.json" |
             Sort-Object -Property Name

if (-not $tagFile -or $bookFiles.Count -eq 0) {
    Write-Error "Fehler: Tag- oder Buchexport-JSON-Dateien fehlen im Ordner '$ExportDir'."
    exit 1
}

$tagContent = Get-Content -Path $tagFile.FullName -Raw -Encoding UTF8

Write-Host "Tag-Datei: $($tagFile.Name)" -ForegroundColor Cyan
Write-Host "Gefunden:  $($bookFiles.Count) Buchexport-Dateien" -ForegroundColor Cyan
Write-Host "Zielordner: $OutputDir" -ForegroundColor Cyan
Write-Host ""

# 4. Hilfsfunktionen

function Test-AgentExists {
    param([string]$AgentId)

    $headers = @{ Authorization = "Bearer $script:ApiKey" }
    try {
        $testUrl = "$script:AgentsUrl/$AgentId"
        Invoke-RestMethod -Uri $testUrl -Method Get -Headers $headers -TimeoutSec 30 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function New-MistralAgent {
    $headers = @{ Authorization = "Bearer $script:ApiKey" }
    $agentBody = @{
        model        = $script:Model
        name         = "Calibre Book Validation Agent"
        description  = "Agent zur Validierung von Calibre-Buchdaten gegen Tag-Definitionen."
        instructions = @"
$script:PromptSystem

Nutze die integrierte Websuche nur, wenn du das Buch nicht aus den Trainingsdaten kennst oder wenn du unsicher bist.
Wenn du das Buch aus den Trainingsdaten kennst, fuehre keine Websuche durch.
Wenn du Websuche benoetigst, verwende das Tool web_search.
Gib am Ende nur gueltiges JSON zurueck.
"@
        tools        = @(@{ type = "web_search" })
        completion_args = @{ temperature = 0.2; top_p = 0.95; max_tokens = 8192 }
    } | ConvertTo-Json -Depth 10

    try {
        Write-Host "Erstelle neuen Mistral Agent..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri $script:AgentsUrl -Method Post -Headers $headers -Body $agentBody -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec
        $agentId = $response.id

        if (-not [string]::IsNullOrWhiteSpace($agentId)) {
            Set-Content -Path $script:AgentIdFile -Value $agentId -Encoding UTF8
            Write-Host "Agent erfolgreich erstellt mit ID: $agentId" -ForegroundColor Green
            return $agentId
        }

        Write-Error "Agent-Erstellung fehlgeschlagen: Ungueltige Agent-ID in Response."
        exit 1
    }
    catch {
        Write-Host "Fehler beim Erstellen des Agents:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $errorBody = $reader.ReadToEnd()
                Write-Host "API Response: $errorBody" -ForegroundColor Red
            }
            catch {}
        }
        exit 1
    }
}

function Get-MistralAgentId {
    if (Test-Path -Path $script:AgentIdFile) {
        $existingId = (Get-Content -Path $script:AgentIdFile -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingId)) {
            Write-Host "Vorhandene Agent-ID gefunden: $existingId" -ForegroundColor Gray
            if (Test-AgentExists -AgentId $existingId) {
                Write-Host "Agent existiert noch - Verwendung der vorhandenen ID." -ForegroundColor Green
                return $existingId
            }
            else {
                Write-Host "Agent nicht mehr vorhanden - Erstelle neuen Agent." -ForegroundColor Yellow
                Remove-Item -Path $script:AgentIdFile -Force
            }
        }
    }

    return New-MistralAgent
}

function Get-MistralResponseText {
    param($Response)

    if ($script:EnableDebugLogging) {
        Write-Host "--- Rohes API Response ---" -ForegroundColor Magenta
        $Response | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Host $_ -ForegroundColor Magenta }
        Write-Host "--- Ende Response ---" -ForegroundColor Magenta
    }

    # Format 1: choices[].message.content
    if ($null -ne $Response.choices -and $Response.choices.Count -gt 0) {
        if ($null -ne $Response.choices[0].message) {
            if ($null -ne $Response.choices[0].message.content) {
                return $Response.choices[0].message.content
            }
            if ($null -ne $Response.choices[0].message.text) {
                return $Response.choices[0].message.text
            }
        }
        if ($null -ne $Response.choices[0].content) {
            return $Response.choices[0].content
        }
        if ($null -ne $Response.choices[0].text) {
            return $Response.choices[0].text
        }
    }

    # Format 2: outputs[]
    if ($null -ne $Response.outputs -and $Response.outputs.Count -gt 0) {
        $firstOutput = $Response.outputs[0]
        if ($firstOutput -is [string]) {
            return $firstOutput
        }
        if ($null -ne $firstOutput.content) {
            if ($firstOutput.content -is [string]) {
                return $firstOutput.content
            }
            if ($firstOutput.content -is [System.Collections.IEnumerable]) {
                $textParts = $firstOutput.content | Where-Object { $_.type -eq 'text' } | Select-Object -ExpandProperty text
                if ($textParts) {
                    return ($textParts -join "")
                }
            }
        }
        if ($null -ne $firstOutput.text) {
            return $firstOutput.text
        }
    }

    # Format 3: output (singular)
    if ($null -ne $Response.output) {
        if ($Response.output -is [string]) {
            return $Response.output
        }
        if ($null -ne $Response.output.text) {
            return $Response.output.text
        }
        if ($null -ne $Response.output.content) {
            return $Response.output.content
        }
    }

    if ($script:EnableDebugLogging) {
        Write-Host "WARNUNG: Response konnte nicht geparsed werden. Siehe Rohdaten oben." -ForegroundColor Yellow
        return $Response | ConvertTo-Json -Depth 3
    }

    return $null
}

function Invoke-MistralRequest {
    param([string]$PayloadText)

    $headers = @{ Authorization = "Bearer $script:ApiKey" }
    $body = @{
        agent_id = $script:AgentId
        inputs   = $PayloadText
        store    = $false
    } | ConvertTo-Json -Depth 10

    $maxRetries = 3
    $retryCount = 0

    while ($retryCount -lt $maxRetries) {
        try {
            $response = Invoke-RestMethod -Uri $script:ConversationsUrl -Method Post -Headers $headers -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec
            $text = Get-MistralResponseText -Response $response
            return $text
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = $_.Exception.Response.StatusCode.value__
            }

            if ($statusCode -eq 429) {
                $retryCount++
                $waitTime = [math]::Pow(2, $retryCount) * 30
                Write-Host "  -> Rate-Limit (429). Warte $waitTime Sekunden... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $waitTime
            }
            else {
                Write-Host "  -> API Request fehlgeschlagen: HTTP $statusCode" -ForegroundColor Red

                if ($statusCode -eq 400) {
                    Write-Host "     Moegliche Ursachen: Ungueltige Agent-ID, falsches Payload-Format, fehlende Berechtigungen." -ForegroundColor Yellow
                }
                elseif ($statusCode -eq 401) {
                    Write-Host "     Moegliche Ursache: API-Key ungueltig oder abgelaufen." -ForegroundColor Yellow
                }
                elseif ($statusCode -eq 500 -or $statusCode -eq 502 -or $statusCode -eq 503) {
                    Write-Host "     Serverfehler bei Mistral - spaeterer Wiederholungsversuch empfohlen." -ForegroundColor Yellow
                }

                try {
                    if ($_.Exception.Response) {
                        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $errorBody = $reader.ReadToEnd()
                        if (-not [string]::IsNullOrEmpty($errorBody)) {
                            Write-Host "     API Response Body: $errorBody" -ForegroundColor DarkGray
                        }
                    }
                }
                catch {}

                Write-Host "     Original Error: $($_.Exception.Message)" -ForegroundColor DarkGray
                return $null
            }
        }
    }

    Write-Error "API Request nach $maxRetries Versuchen abgebrochen."
    return $null
}

# 5. Agent initialisieren
Write-Host "--- Initialisiere Mistral Agent ---" -ForegroundColor Cyan
$AgentId = Get-MistralAgentId

if ([string]::IsNullOrWhiteSpace($AgentId)) {
    Write-Error "Fehler: Agent-ID konnte nicht ermittelt werden."
    exit 1
}
Write-Host "Agent-ID: $AgentId" -ForegroundColor Gray
Write-Host ""

# 6. Verarbeitungsschleife
$counter = 0
$total = $bookFiles.Count

foreach ($bookFile in $bookFiles) {
    $counter++
    Write-Host "[$counter/$total] Verarbeite $($bookFile.Name)..." -ForegroundColor Yellow

    $bookContent = Get-Content -Path $bookFile.FullName -Raw -Encoding UTF8

    $fullPrompt = @"
$PromptSystem

===================================
TAG-DEFINITIONEN (aus $($tagFile.Name)):
===================================
$tagContent

===================================
BUeCHER (aus $($bookFile.Name)):
===================================
$bookContent
"@

    $apiResult = Invoke-MistralRequest -PayloadText $fullPrompt

    if ($apiResult) {
        $outName = $bookFile.Name -replace "^Calibre_Buchexport_", "Ergebnis_"
        $outPath = Join-Path -Path $OutputDir -ChildPath $outName

        [System.IO.File]::WriteAllText($outPath, $apiResult, [System.Text.Encoding]::UTF8)
        Write-Host "  -> Gespeichert in: $outName" -ForegroundColor Green

        if ($EnableDebugLogging -and $apiResult.Length -gt 200) {
            Write-Host "     Preview: $($apiResult.Substring(0, [Math]::Min(200, $apiResult.Length)))..." -ForegroundColor Gray
        }
    }
    else {
        Write-Host "  -> FEHLER: Keine Antwort von API." -ForegroundColor Red
    }

    Start-Sleep -Seconds 15
}

Write-Host ""
Write-Host "Verarbeitung abgeschlossen." -ForegroundColor Cyan

$successfulFiles = (Get-ChildItem -Path $OutputDir -Filter "Ergebnis_*.json" -ErrorAction SilentlyContinue).Count
Write-Host "Ergebnisse: $successfulFiles von $total Dateien erfolgreich verarbeitet" -ForegroundColor Gray

if ($EnableDebugLogging) {
    Write-Host ""
    Write-Host "Debug-Modus aktiv. Nach erfolgreichem Test `$EnableDebugLogging auf `$false setzen." -ForegroundColor Yellow
}