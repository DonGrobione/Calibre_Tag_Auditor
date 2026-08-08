<#
.SYNOPSIS
    Validate Calibre exports using the Mistral API.

.DESCRIPTION
    Uses extracted Calibre book export JSON and tag definition JSON files to
    validate book metadata against tag definitions with the Mistral API.
    Results are written to the LLM_Result folder as JSON files.

.NOTES
    PowerShell version: 5.1+
    Version: 2.1 - Added JSON validation
#>

try {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $ScriptDir = $PSScriptRoot
    $ExportDir = Join-Path -Path $ScriptDir -ChildPath "Export"
    $OutputDir = Join-Path -Path $ScriptDir -ChildPath "LLM_Result"
    $ApiKeyFile = Join-Path -Path $ScriptDir -ChildPath ".secrets\Mistral_API.txt"
    $PromptFile = Join-Path -Path $ScriptDir -ChildPath "03-CalibreDataLLM-Prompt.txt"

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

    $ApiKey = (Get-Content -Path $ApiKeyFile -Raw -Encoding UTF8).Trim()
    $PromptSystem = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()

    $tagFile = Get-ChildItem -Path $ExportDir -Filter "Calibre_Tag_Export_*.json" |
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

    function Test-ValidJson {
        param([string]$JsonString)

        # Trim whitespace
        $cleaned = $JsonString.Trim()

        # Remove possible Markdown code blocks
        $cleaned = $cleaned -replace '^\s*```json\s*', '' -replace '^\s*```\s*', ''
        $cleaned = $cleaned -replace '\s*```\s*$', ''
        $cleaned = $cleaned.Trim()

        # Check if starts with valid JSON delimiter
        if ($cleaned -notmatch '^[\{\[]') {
            return $false, "JSON must start with '{' or '[' - found: $($cleaned.Substring(0, [Math]::Min(20, $cleaned.Length)))"
        }

        # Check if ends with valid JSON delimiter
        if ($cleaned -notmatch '[\}\]]\s*$') {
            return $false, "JSON must end with '}' or ']'"
        }

        try {
            $parsed = $cleaned | ConvertFrom-Json -ErrorAction Stop
            return $true, $parsed
        }
        catch {
            return $false, $_.Exception.Message
        }
    }

    function Save-RawResponse {
        param([string]$OriginalName, [string]$Content, [string]$OutputDir)

        $rawName = $OriginalName -replace '\.json$', '.json.raw'
        $rawPath = Join-Path -Path $OutputDir -ChildPath $rawName
        [System.IO.File]::WriteAllText($rawPath, $Content, [System.Text.Encoding]::UTF8)
        return $rawPath
    }

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
            description  = "Agent for validating Calibre book data against tag definitions."
            instructions = $script:PromptSystem
            tools        = @(@{ type = "web_search" })
            completion_args = @{ temperature = 0.2; top_p = 0.95; max_tokens = 8192 }
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
                Write-Host "Existing agent ID found: $existingId" -ForegroundColor Gray
                if (Test-AgentExists -AgentId $existingId) {
                    Write-Host "Agent still exists - using existing ID." -ForegroundColor Green
                    return $existingId
                }
                else {
                    Write-Host "Agent no longer exists - creating a new agent." -ForegroundColor Yellow
                    Remove-Item -Path $script:AgentIdFile -Force
                }
            }
        }

        return New-MistralAgent
    }

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

    $counter = 0
    $total = $bookFiles.Count
    $validJsonCount = 0
    $invalidJsonCount = 0

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
            # JSON VALIDATION
            $isValid, $resultOrError = Test-ValidJson -JsonString $apiResult

            if (-not $isValid) {
                $invalidJsonCount++
                Write-Host "  -> INVALID JSON: $resultOrError" -ForegroundColor Red

                # Save raw response for manual inspection
                $rawPath = Save-RawResponse -OriginalName $bookFile.Name -Content $apiResult -OutputDir $OutputDir
                Write-Host "     Raw saved as: $($rawPath | Split-Path -Leaf)" -ForegroundColor DarkGray

                # Show preview of first 200 chars
                Write-Host "     Preview: $($apiResult.Substring(0, [Math]::Min(200, $apiResult.Length)))..." -ForegroundColor DarkGray
            }
            else {
                $validJsonCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "Ergebnis_"

                # Serialize the validated JSON back to string
                $jsonString = $resultOrError | ConvertTo-Json -Depth 10
                [System.IO.File]::WriteAllText($outPath, $jsonString, [System.Text.Encoding]::UTF8)
                Write-Host "  -> Saved as: $outName" -ForegroundColor Green

                if ($EnableDebugLogging -and $jsonString.Length -gt 200) {
                    Write-Host "     Preview: $($jsonString.Substring(0, [Math]::Min(200, $jsonString.Length)))..." -ForegroundColor Gray
                }
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
    Write-Host "Valid JSON:      $validJsonCount" -ForegroundColor Green
    Write-Host "Invalid JSON:    $invalidJsonCount" -ForegroundColor $(if ($invalidJsonCount -gt 0) { "Red" } else { "Gray" })

    if ($invalidJsonCount -gt 0) {
        Write-Host ""
        Write-Host "Note: Invalid responses saved as .json.raw files for manual review." -ForegroundColor Yellow
    }

    if ($EnableDebugLogging) {
        Write-Host ""
        Write-Host "Debug mode active. After testing set `$EnableDebugLogging to `$false." -ForegroundColor Yellow
    }
}
catch {
    Write-Error $_.Exception.Message
    throw
}