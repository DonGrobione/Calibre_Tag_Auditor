<#
.SYNOPSIS
    Validate Calibre export data with the Mistral API.

.DESCRIPTION
    Reads the latest Calibre book export and tag-definition JSON files, creates
    or refreshes a Mistral agent for each run, sends each book export to the
    agent together with the prompt and tag definitions, and writes the LLM
    responses to the 02-LLM-Result folder as individual JSON files.

.NOTES
    Version: 2.5
    Requires a valid API key in .secrets/Mistral_API.txt and a prompt file named
    02-CalibreDataLLM-Prompt.txt in the script folder.
    Each output file is written as a valid JSON object with metadata, records,
    the raw response text, and any parse error information.
#>

try {
    # Enable strict error handling for the LLM workflow.
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Resolve the script directory and required input/output paths.
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

    # Ensure the output folder exists before writing results.
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }

    if (-not (Test-Path -Path $ApiKeyFile) -or -not (Test-Path -Path $PromptFile)) {
        throw "API key or prompt file is missing in the script folder."
    }

    # Create the secrets folder if it is missing.
    $SecretDir = Join-Path -Path $ScriptDir -ChildPath ".secrets"
    if (-not (Test-Path -Path $SecretDir)) {
        New-Item -Path $SecretDir -ItemType Directory | Out-Null
    }

    # Load the API key and the prompt system from external files.
    $ApiKey = (Get-Content -Path $ApiKeyFile -Raw -Encoding UTF8).Trim()
    $PromptSystem = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()

    # Find the latest tag-definition file and the available book export files.
    $tagFile = Get-ChildItem -Path $ExportDir -Filter "02-Export-CalibreTags_*.json" |
               Sort-Object -Property LastWriteTime -Descending |
               Select-Object -First 1

    $bookFiles = Get-ChildItem -Path $ExportDir -Filter "01-Export-CalibreBooks_*.json" |
                 Sort-Object -Property Name

    if (-not $tagFile -or $bookFiles.Count -eq 0) {
        throw "Tag or book export JSON files are missing in the folder '$ExportDir'."
    }

    # Load the tag definitions and print a short summary for the run.
    $tagContent = Get-Content -Path $tagFile.FullName -Raw -Encoding UTF8

    Write-Host "Tag file: $($tagFile.Name)" -ForegroundColor Cyan
    Write-Host "Found:    $($bookFiles.Count) book export files" -ForegroundColor Cyan
    Write-Host "Target:   $OutputDir" -ForegroundColor Cyan
    Write-Host ""

    # Check whether a previously stored agent ID still resolves to a real Mistral agent.
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

    # Delete an existing agent if it is still available.
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

    # Create a fresh Mistral agent for this run.
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

            $agentId = $null
            if ($null -ne $response) {
                try {
                    $agentId = [string]$response.id
                }
                catch {}
            }

            if (-not [string]::IsNullOrWhiteSpace($agentId)) {
                Set-Content -Path $script:AgentIdFile -Value $agentId -Encoding UTF8
                Write-Host "Agent created successfully with ID: $agentId" -ForegroundColor Green
                return $agentId
            }

            $responseText = $null
            try {
                $responseText = $response | ConvertTo-Json -Depth 10 -Compress
            }
            catch {
                if ($null -ne $response) {
                    $responseText = $response.ToString()
                }
            }

            if ([string]::IsNullOrWhiteSpace($responseText)) {
                throw "Agent creation failed: no agent ID was returned by the API."
            }

            throw "Agent creation failed: invalid agent ID in response. Response: $responseText"
        }
        catch {
            $errMessage = $null
            if ($null -ne $_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
                $errMessage = $_.Exception.Message
            }
            elseif ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                $errMessage = $_.ErrorDetails.Message
            }
            else {
                $errMessage = $_.ToString()
            }

            Write-Error "Failed to create agent: $errMessage"
            if ($null -ne $_.Exception -and $null -ne $_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorBody = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($errorBody)) {
                        Write-Error "API Response: $errorBody"
                    }
                }
                catch {}
            }
            throw
        }
    }

    # Reuse a previous ID only if it still exists; otherwise create a new agent.
    function Get-MistralAgentId {
        if (Test-Path -Path $script:AgentIdFile) {
            $agentIdContent = Get-Content -Path $script:AgentIdFile -Raw -Encoding UTF8
            if ($null -ne $agentIdContent) {
                $existingId = $agentIdContent.Trim()
                if (-not [string]::IsNullOrWhiteSpace($existingId)) {
                    Write-Host "Existing agent ID found from previous run: $existingId" -ForegroundColor Gray
                    Remove-MistralAgent -AgentId $existingId
                }
            }
        }

        Remove-Item -Path $script:AgentIdFile -Force -ErrorAction SilentlyContinue
        return New-MistralAgent
    }

    # Extract the response text from the Mistral API response regardless of the payload shape.
    function Get-MistralResponseText {
        param($Response)

        if ($null -eq $Response) {
            Write-Host "No response received from the Mistral API." -ForegroundColor Yellow
            return $null
        }

        function Get-TextFromContent {
            param($Content)

            if ($null -eq $Content) {
                return $null
            }

            if ($Content -is [string]) {
                return $Content
            }

            if ($Content -is [System.Collections.IEnumerable]) {
                $textParts = foreach ($item in $Content) {
                    if ($null -eq $item) {
                        continue
                    }

                    if ($item -is [string]) {
                        $item
                        continue
                    }

                    if ($null -ne $item.text -and -not [string]::IsNullOrWhiteSpace([string]$item.text)) {
                        [string]$item.text
                    }
                }

                if ($textParts) {
                    return ($textParts -join "")
                }
            }

            if ($null -ne $Content.text -and -not [string]::IsNullOrWhiteSpace([string]$Content.text)) {
                return [string]$Content.text
            }

            return $null
        }

        function Get-TextFromOutputEntry {
            param($Entry)

            if ($null -eq $Entry) {
                return $null
            }

            $entryType = $null
            if ($null -ne $Entry.type) {
                $entryType = [string]$Entry.type
            }

            $textFromContent = Get-TextFromContent -Content $Entry.content
            if (-not [string]::IsNullOrWhiteSpace($textFromContent)) {
                return $textFromContent
            }

            if ($entryType -eq 'message.output' -and $null -ne $Entry.message) {
                $textFromMessage = Get-TextFromContent -Content $Entry.message.content
                if (-not [string]::IsNullOrWhiteSpace($textFromMessage)) {
                    return $textFromMessage
                }

                if ($null -ne $Entry.message.text -and -not [string]::IsNullOrWhiteSpace([string]$Entry.message.text)) {
                    return [string]$Entry.message.text
                }
            }

            if ($null -ne $Entry.text -and -not [string]::IsNullOrWhiteSpace([string]$Entry.text)) {
                return [string]$Entry.text
            }

            return $null
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
            foreach ($outputEntry in $Response.outputs) {
                $outputText = Get-TextFromOutputEntry -Entry $outputEntry
                if (-not [string]::IsNullOrWhiteSpace($outputText)) {
                    return $outputText
                }
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
                $outputText = Get-TextFromContent -Content $Response.output.content
                if (-not [string]::IsNullOrWhiteSpace($outputText)) {
                    return $outputText
                }
            }
        }

        Write-Host "--- Raw API response ---" -ForegroundColor Magenta
        $Response | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Host $_ -ForegroundColor Magenta }
        Write-Host "--- End response ---" -ForegroundColor Magenta
        Write-Warning "Response could not be parsed. See raw output above."
        return $Response | ConvertTo-Json -Depth 3
    }

    # Extract the first valid JSON block from a text response.
    function Get-JsonText {
        param([string]$RawText)

        if ([string]::IsNullOrWhiteSpace($RawText)) {
            return $null
        }

        $firstArray = $RawText.IndexOf('[')
        $firstObject = $RawText.IndexOf('{')
        if ($firstArray -eq -1 -and $firstObject -eq -1) {
            return $null
        }

        if ($firstArray -ge 0 -and ($firstArray -le $firstObject -or $firstObject -eq -1)) {
            $start = $firstArray
        }
        else {
            $start = $firstObject
        }

        $depth = 0
        $inString = $false
        $escape = $false

        for ($i = $start; $i -lt $RawText.Length; $i++) {
            $character = $RawText[$i]

            if ($escape) {
                $escape = $false
                continue
            }

            if ($character -eq '\\') {
                $escape = $true
                continue
            }

            if ($character -eq '"') {
                $inString = -not $inString
                continue
            }

            if (-not $inString) {
                if ($character -eq '[' -or $character -eq '{') {
                    $depth++
                }
                elseif ($character -eq ']' -or $character -eq '}') {
                    $depth--
                    if ($depth -eq 0) {
                        return $RawText.Substring($start, $i - $start + 1)
                    }
                }
            }
        }

        $lastClose = [Math]::Max($RawText.LastIndexOf(']'), $RawText.LastIndexOf('}'))
        if ($lastClose -gt $start) {
            return $RawText.Substring($start, $lastClose - $start + 1)
        }

        return $null
    }

    # Convert the API response text into a JSON-safe result object.
    function Convert-ResponseTextToResultObject {
        param(
            [string]$RawText,
            [string]$SourceFile,
            [string]$AgentId
        )

        $result = [ordered]@{
            source_file  = $SourceFile
            agent_id     = $AgentId
            status       = 'success'
            records      = @()
            raw_response = $RawText
            parse_error  = $null
        }

        $jsonText = Get-JsonText -RawText $RawText
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            $result.status = 'error'
            $result.parse_error = 'No JSON structure could be extracted from the Mistral response.'
            return [pscustomobject]$result
        }

        try {
            $parsed = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
        }
        catch {
            $normalizedJsonText = $jsonText -replace '\\"', '"'

            if ($normalizedJsonText -ne $jsonText) {
                try {
                    $parsed = ConvertFrom-Json -InputObject $normalizedJsonText -ErrorAction Stop
                }
                catch {
                    $normalizedJsonText = [System.Text.RegularExpressions.Regex]::Unescape($jsonText)
                    try {
                        $parsed = ConvertFrom-Json -InputObject $normalizedJsonText -ErrorAction Stop
                    }
                    catch {
                        $result.status = 'error'
                        $result.parse_error = $_.Exception.Message
                        return [pscustomobject]$result
                    }
                }
            }
            else {
                $normalizedJsonText = [System.Text.RegularExpressions.Regex]::Unescape($jsonText)
                try {
                    $parsed = ConvertFrom-Json -InputObject $normalizedJsonText -ErrorAction Stop
                }
                catch {
                    $result.status = 'error'
                    $result.parse_error = $_.Exception.Message
                    return [pscustomobject]$result
                }
            }
        }

        if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
            $result.records = @($parsed)
        }
        else {
            $result.records = @($parsed)
        }

        return [pscustomobject]$result
    }

    # Send a request to the Mistral conversations API and handle basic retry cases.
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

    # Initialize the Mistral agent for this execution.
    Write-Host "--- Initialize Mistral agent ---" -ForegroundColor Cyan
    $AgentId = Get-MistralAgentId

    if ([string]::IsNullOrWhiteSpace($AgentId)) {
        throw "Agent ID could not be resolved."
    }
    Write-Host "Agent ID: $AgentId" -ForegroundColor Gray
    Write-Host ""

    # Process each book file one by one and save every LLM response separately.
    $counter = 0
    $total = $bookFiles.Count
    $savedCount = 0

    foreach ($bookFile in $bookFiles) {
        $counter++
        Write-Host "[$counter/$total] Processing $($bookFile.Name)..." -ForegroundColor Yellow

        # Read the current book export and build the full prompt payload.
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

        # Send the prompt to the Mistral conversation endpoint.
        $apiResult = Invoke-MistralRequest -PayloadText $fullPrompt

        if ($null -ne $apiResult) {
            $savedCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
            $outPath = Join-Path -Path $OutputDir -ChildPath $outName

            # Store a valid JSON wrapper so parse errors and raw API output are preserved.
            $resultObject = Convert-ResponseTextToResultObject -RawText $apiResult -SourceFile $bookFile.Name -AgentId $AgentId
            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($outPath, $jsonOutput, [System.Text.Encoding]::UTF8)

            if ($resultObject.status -eq 'success') {
                Write-Host "  -> Saved as: $outName" -ForegroundColor Green
            }
            else {
                Write-Host "  -> Saved with parse error: $outName" -ForegroundColor Yellow
                Write-Host "     $($resultObject.parse_error)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  -> ERROR: No response from API." -ForegroundColor Red
        }

        Start-Sleep -Seconds 15
    }

    # Final summary for the completed run.
    Write-Host ""
    Write-Host "--- Processing Complete ---" -ForegroundColor Cyan
    Write-Host "Total files:     $total" -ForegroundColor Gray
    Write-Host "Saved files:     $savedCount" -ForegroundColor Green

}
catch {
    $errorMessage = $null
    if ($null -ne $_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        $errorMessage = $_.Exception.Message
    }
    elseif ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
        $errorMessage = $_.ErrorDetails.Message
    }
    else {
        $errorMessage = $_.ToString()
    }

    Write-Host "ERROR: $errorMessage" -ForegroundColor Red
    throw
}