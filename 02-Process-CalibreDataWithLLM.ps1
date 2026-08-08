<#
.SYNOPSIS
    Validate Calibre exports using the Mistral API.

.DESCRIPTION
    Uses extracted Calibre book export JSON and tag definition JSON files to
    validate book metadata against tag definitions with the Mistral API.
    Results are written to the 02-LLM-Result folder as JSON files.
    The system prompt is loaded from the external 02-CalibreDataLLM-Prompt.txt file.

.NOTES
    Version: 2.3
#>

try {
    # Enable strict error handling for the LLM workflow.
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $ScriptDir = $PSScriptRoot
    $ExportDir = Join-Path -Path $ScriptDir -ChildPath "01-Export"
    $OutputDir = Join-Path -Path $ScriptDir -ChildPath "02-LLM-Result"
    $ApiKeyFile = Join-Path -Path $ScriptDir -ChildPath ".secrets\Mistral_API.txt"
    $PromptFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreDataLLM-Prompt.txt"

    $Model = "mistral-large-latest"
    $AgentsUrl = "https://api.mistral.ai/v1/agents"
    $ConversationsUrl = "https://api.mistral.ai/v1/conversations"
    $AgentIdFile = Join-Path -Path $ScriptDir -ChildPath ".secrets\Mistral_Agent_Id.txt"
    $ApiTimeoutSec = 300
    $EnableDebugLogging = $false

    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }

    if (-not (Test-Path -Path $ApiKeyFile) -or -not (Test-Path -Path $PromptFile)) {
        throw "API key or prompt file is missing in the script folder."
    }

    $SecretDir = Join-Path -Path $ScriptDir -ChildPath ".secrets"
    if (-not (Test-Path -Path $SecretDir)) {
        New-Item -Path $SecretDir -ItemType Directory | Out-Null
    }

    # Load the API key and the prompt system from external files.
    $ApiKey = (Get-Content -Path $ApiKeyFile -Raw -Encoding UTF8).Trim()
    $PromptSystem = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()

    # Find the latest tag definition and the book export files in the export folder.
    $tagFile = Get-ChildItem -Path $ExportDir -Filter "02-Export-CalibreTags_*.json" |
               Sort-Object -Property LastWriteTime -Descending |
               Select-Object -First 1

    $bookFiles = Get-ChildItem -Path $ExportDir -Filter "01-Export-CalibreBooks_*.json" |
                 Sort-Object -Property Name

    if (-not $tagFile -or $bookFiles.Count -eq 0) {
        throw "Tag or book export JSON files are missing in the folder '$ExportDir'."
    }

    $tagContent = Get-Content -Path $tagFile.FullName -Raw -Encoding UTF8

    Write-Host "Tag file: $($tagFile.Name)" -ForegroundColor Cyan
    Write-Host "Found:    $($bookFiles.Count) book export files" -ForegroundColor Cyan
    Write-Host "Target:   $OutputDir" -ForegroundColor Cyan
    Write-Host ""

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

    function Remove-MistralAgent {
        param([string]$AgentId)

        if ([string]::IsNullOrWhiteSpace($AgentId)) {
            return
        }

        if (-not (Test-AgentExists -AgentId $AgentId)) {
            Write-Host "No existing agent found for ID: $AgentId" -ForegroundColor DarkGray
            return
        }

        $headers = @{ Authorization = "Bearer $script:ApiKey" }
        $deleteUrl = "$script:AgentsUrl/$AgentId"

        try {
            Write-Host "Deleting existing Mistral agent: $AgentId" -ForegroundColor Yellow
            Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $headers -TimeoutSec $script:ApiTimeoutSec | Out-Null
            Write-Host "Existing agent deleted successfully." -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not delete existing agent '$AgentId': $($_.Exception.Message)"
        }
    }

    function New-MistralAgent {
        $headers = @{ Authorization = "Bearer $script:ApiKey" }
        $agentBody = @{
            model        = $script:Model
            name         = "Calibre Book Validation Agent"
            description  = "Agent for validating Calibre book data against tag definitions."
            instructions = $script:PromptSystem
            tools        = @(@{ type = "web_search" })
            completion_args = @{ temperature = 0.2; top_p = 0.95 }
        } | ConvertTo-Json -Depth 10

        try {
            Write-Host "Creating new Mistral agent..." -ForegroundColor Gray
            $response = Invoke-RestMethod -Uri $script:AgentsUrl -Method Post -Headers $headers -Body $agentBody -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec
            $agentId = $response.id

            if (-not [string]::IsNullOrWhiteSpace($agentId)) {
                Set-Content -Path $script:AgentIdFile -Value $agentId -Encoding UTF8
                Write-Host "Agent created successfully with ID: $agentId" -ForegroundColor Green
                return $agentId
            }

            throw "Agent creation failed: invalid agent ID in response."
        }
        catch {
            Write-Error "Failed to create agent: $($_.Exception.Message)"
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorBody = $reader.ReadToEnd()
                    Write-Error "API Response: $errorBody"
                }
                catch {}
            }
            throw
        }
    }

    function Get-MistralAgentId {
        if (Test-Path -Path $script:AgentIdFile) {
            $existingId = (Get-Content -Path $script:AgentIdFile -Raw -Encoding UTF8).Trim()
            if (-not [string]::IsNullOrWhiteSpace($existingId)) {
                Write-Host "Existing agent ID found from previous run: $existingId" -ForegroundColor Gray
                Remove-MistralAgent -AgentId $existingId
            }
        }

        Remove-Item -Path $script:AgentIdFile -Force -ErrorAction SilentlyContinue
        return New-MistralAgent
    }

    # Extract the actual text from the Mistral response regardless of its response format.
    function Get-MistralResponseText {
        param($Response)

        if ($script:EnableDebugLogging) {
            Write-Host "--- Raw API response ---" -ForegroundColor Magenta
            $Response | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Host $_ -ForegroundColor Magenta }
            Write-Host "--- End response ---" -ForegroundColor Magenta
        }

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
            Write-Warning "Response could not be parsed. See raw output above."
            return $Response | ConvertTo-Json -Depth 3
        }

        return $null
    }

    # Send a request to the Mistral conversations API and handle simple retry cases.
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
                    Write-Host "  -> Rate limit (429). Waiting $waitTime seconds... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    Start-Sleep -Seconds $waitTime
                }
                else {
                    Write-Host "  -> API request failed: HTTP $statusCode" -ForegroundColor Red

                    if ($statusCode -eq 400) {
                        Write-Host "     Possible causes: invalid agent ID, malformed payload, missing permissions." -ForegroundColor Yellow
                    }
                    elseif ($statusCode -eq 401) {
                        Write-Host "     Possible cause: API key is invalid or expired." -ForegroundColor Yellow
                    }
                    elseif ($statusCode -eq 500 -or $statusCode -eq 502 -or $statusCode -eq 503) {
                        Write-Host "     Server error at Mistral - retry later." -ForegroundColor Yellow
                    }

                    try {
                        if ($_.Exception.Response) {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $errorBody = $reader.ReadToEnd()
                            if (-not [string]::IsNullOrEmpty($errorBody)) {
                                Write-Host "     API response body: $errorBody" -ForegroundColor DarkGray
                            }
                        }
                    }
                    catch {}

                    Write-Host "     Original error: $($_.Exception.Message)" -ForegroundColor DarkGray
                    return $null
                }
            }
        }

        Write-Error "API request aborted after $maxRetries attempts."
        return $null
    }

    Write-Host "--- Initialize Mistral agent ---" -ForegroundColor Cyan
    $AgentId = Get-MistralAgentId

    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        throw "Agent ID could not be resolved."
    }
    Write-Host "Agent ID: $AgentId" -ForegroundColor Gray
    Write-Host ""

    # Process each book file one by one and save the LLM response separately.
    $counter = 0
    $total = $bookFiles.Count
    $savedCount = 0

    foreach ($bookFile in $bookFiles) {
        $counter++
        Write-Host "[$counter/$total] Processing $($bookFile.Name)..." -ForegroundColor Yellow

        $bookContent = Get-Content -Path $bookFile.FullName -Raw -Encoding UTF8

        $fullPrompt = @"
$PromptSystem

===================================
TAG DEFINITIONS (from $($tagFile.Name)):
===================================
$tagContent

===================================
BOOKS (from $($bookFile.Name)):
===================================
$bookContent
"@

        $apiResult = Invoke-MistralRequest -PayloadText $fullPrompt

        if ($apiResult) {
            $savedCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
            $outPath = Join-Path -Path $OutputDir -ChildPath $outName
            [System.IO.File]::WriteAllText($outPath, $apiResult, [System.Text.Encoding]::UTF8)
            Write-Host "  -> Saved as: $outName" -ForegroundColor Green

            if ($EnableDebugLogging -and $apiResult.Length -gt 200) {
                Write-Host "     Preview: $($apiResult.Substring(0, [Math]::Min(200, $apiResult.Length)))..." -ForegroundColor Gray
            }
        }
        else {
            Write-Host "  -> ERROR: No response from API." -ForegroundColor Red
        }

        Start-Sleep -Seconds 15
    }

    Write-Host ""
    Write-Host "--- Processing Complete ---" -ForegroundColor Cyan
    Write-Host "Total files:     $total" -ForegroundColor Gray
    Write-Host "Saved files:     $savedCount" -ForegroundColor Green

    if ($EnableDebugLogging) {
        Write-Host ""
        Write-Host "Debug mode active. After testing set `$EnableDebugLogging to `$false." -ForegroundColor Yellow
    }
}
catch {
    Write-Error $_.Exception.Message
    throw
}