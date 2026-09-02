<#
.SYNOPSIS
    Validate Calibre export data with the Mistral API.

.DESCRIPTION
    Reads the latest Calibre book export and tag-definition JSON files, creates a fresh Mistral agent for each run, sends each book export to the agent together with the prompt and tag definitions, and writes the LLM responses
    to the 02-LLM-Result folder as individual JSON files.
    It validates unique-book counts per file, repairs mojibake in LLM responses, and stores the validation outcome in the output metadata.
    Script output (info, warnings, and errors) is written both to terminal and to the central log via Modules\Write-Log.psm1. Errors are marked as already logged before rethrowing so wrapper scripts can avoid duplicate log entries.

.NOTES
    Version: 3.2
    Requires a valid API key in .secrets/Mistral_API.txt and a prompt file named 02-CalibreDataLLM-Prompt.txt in the script folder.
    Each output file is written as a valid JSON object with metadata, records, the raw response text, parse errors, and validation details for unique-book counts.
#>

$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '$WriteLogModulePath'"
}

Import-Module -Name $WriteLogModulePath -Force

# Prefix every log line with the current script name to simplify troubleshooting
# when multiple scripts write into one shared logfile.
$ScriptLogName = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { 'UnknownScript' } else { Split-Path -Path $PSCommandPath -Leaf }
$ScriptLogPrefix = "[$ScriptLogName]"

function Write-HostAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator
    )

    $joinSeparator = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    $message = (($Object | ForEach-Object { [string]$_ }) -join $joinSeparator)
    Write-Log -Message "$ScriptLogPrefix $message" -Info
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Write-WarningAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -Warn
    Microsoft.PowerShell.Utility\Write-Warning $text
}

function Write-ErrorAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -IsError
    Microsoft.PowerShell.Utility\Write-Error $text
}

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

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
    $script:MaxContentRetries = 3
    $script:LastApiErrorMessage = $null
    $script:LastApiErrorBody = $null

    # Ensure the output folder exists before writing results and remove stale JSON files from a previous run.
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }
    else {
        $jsonFiles = Get-ChildItem -Path $OutputDir -Filter "*.json" -File
        if ($jsonFiles.Count -gt 0) {
            Write-Host "Cleaning $($jsonFiles.Count) JSON file(s) from 02-LLM-Result..." -ForegroundColor Yellow
            $jsonFiles | Remove-Item -Force
            Write-Host "Done." -ForegroundColor Green
            Write-Host ""
        }
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
            if ($null -ne $response -and $response.PSObject.Properties.Name -contains 'id') {
                $agentId = [string]$response.id
            }

            if (-not [string]::IsNullOrWhiteSpace($agentId)) {
                Set-Content -Path $script:AgentIdFile -Value $agentId -Encoding UTF8
                Write-Host "Agent created successfully with ID: $agentId" -ForegroundColor Green
                return $agentId
            }

            $responseText = $null
            if ($null -ne $response) {
                try {
                    $responseText = $response | ConvertTo-Json -Depth 10 -Compress
                }
                catch {
                    $responseText = [string]$response
                }
            }

            if ([string]::IsNullOrWhiteSpace($responseText)) {
                throw "Agent creation failed: no agent ID was returned by the API."
            }

            throw "Agent creation failed: invalid agent ID in response. Response: $responseText"
        }
        catch {
            $errMessage = Get-ErrorMessageFromException -ErrorRecord $_
            if ([string]::IsNullOrWhiteSpace($errMessage)) {
                $errMessage = $_.ToString()
            }

            Write-Error "Failed to create agent: $errMessage"
            $errorBody = Get-ErrorBodyTextFromException -ErrorRecord $_
            if (-not [string]::IsNullOrWhiteSpace($errorBody)) {
                Write-Error "API Response: $errorBody"
            }
            throw
        }
    }

    # Remove any previously stored agent and create a fresh one for each run.
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

    function Repair-MojibakeText {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return $Text
        }

        if ($Text -notmatch 'Ã|Â') {
            return $Text
        }

        $current = $Text
        for ($i = 0; $i -lt 4; $i++) {
            try {
                $bytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($current)
                $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
            }
            catch {
                break
            }

            if ($decoded -eq $current -or $decoded -match '�') {
                break
            }

            $current = $decoded
        }

        return $current
    }

    function Get-ErrorMessageFromException {
        param([System.Management.Automation.ErrorRecord]$ErrorRecord)

        if ($null -eq $ErrorRecord) {
            return $null
        }

        if ($null -ne $ErrorRecord.Exception -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.Message)) {
            return $ErrorRecord.Exception.Message
        }

        if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
            return $ErrorRecord.ErrorDetails.Message
        }

        return [string]$ErrorRecord
    }

    function Get-ErrorBodyTextFromException {
        param([System.Management.Automation.ErrorRecord]$ErrorRecord)

        if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception -or $null -eq $ErrorRecord.Exception.Response) {
            return $null
        }

        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
        catch {
            return $null
        }
    }

    # Extract the response text from the Mistral API response regardless of the payload shape.
    function Get-MistralResponseText {
        param($Response)

        if ($null -eq $Response) {
            Write-Warning "No response received from the Mistral API."
            return $null
        }

        function Get-TextFromContent {
            param($Content)

            if ($null -eq $Content) {
                return $null
            }

            if ($Content -is [string]) {
                return (Repair-MojibakeText -Text $Content)
            }

            if ($Content -is [System.Collections.IEnumerable]) {
                $textParts = foreach ($item in $Content) {
                    if ($null -eq $item) {
                        continue
                    }

                    if ($item -is [string]) {
                        Repair-MojibakeText -Text $item
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
                return (Repair-MojibakeText -Text [string]$Content.text)
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
                    return (Repair-MojibakeText -Text [string]$Entry.message.text)
                }
            }

            if ($null -ne $Entry.text -and -not [string]::IsNullOrWhiteSpace([string]$Entry.text)) {
                return (Repair-MojibakeText -Text [string]$Entry.text)
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
    function Repair-JsonArrayFormatting {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return $Text
        }

        $cleaned = $Text.Trim()
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*```(?:json)?\s*', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '\s*```\s*$', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*\*+', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '\*+\s*$', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '^\s*`+', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '`+\s*$', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '(?<=\[)\*\*', '')
        $cleaned = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '\*\*(?=\])', '')

        $repaired = [System.Text.RegularExpressions.Regex]::Replace($cleaned, '(?s)(\})\s*(\{)', '$1,$2')
        return $repaired
    }

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

    function Get-BookIdentityKey {
        param(
            [object]$Book,
            [string]$TitlePropertyName,
            [string]$AuthorPropertyName,
            [string]$SeriesPropertyName = '',
            [string]$SeriesIndexPropertyName = ''
        )

        if ($null -eq $Book) {
            return ''
        }

        $title = ''
        $author = ''
        $series = ''
        $seriesIndex = ''

        if ($Book.PSObject.Properties.Name -contains $TitlePropertyName) {
            $title = [string]$Book.$TitlePropertyName
        }
        if ($Book.PSObject.Properties.Name -contains $AuthorPropertyName) {
            $author = [string]$Book.$AuthorPropertyName
        }
        if (-not [string]::IsNullOrWhiteSpace($SeriesPropertyName) -and $Book.PSObject.Properties.Name -contains $SeriesPropertyName) {
            $series = [string]$Book.$SeriesPropertyName
        }
        if (-not [string]::IsNullOrWhiteSpace($SeriesIndexPropertyName) -and $Book.PSObject.Properties.Name -contains $SeriesIndexPropertyName) {
            $seriesIndex = [string]$Book.$SeriesIndexPropertyName
        }

        $normalizedParts = @(
            ([regex]::Replace($title, '\s+', ' ').Trim()).ToLowerInvariant(),
            ([regex]::Replace($author, '\s+', ' ').Trim()).ToLowerInvariant(),
            ([regex]::Replace($series, '\s+', ' ').Trim()).ToLowerInvariant(),
            ([regex]::Replace($seriesIndex, '\s+', ' ').Trim()).ToLowerInvariant()
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        return ($normalizedParts -join '|')
    }

    function Get-UniqueBookCount {
        param(
            [object[]]$Items,
            [string]$TitlePropertyName,
            [string]$AuthorPropertyName,
            [string]$SeriesPropertyName = '',
            [string]$SeriesIndexPropertyName = ''
        )

        if ($null -eq $Items) {
            return 0
        }

        $itemList = @($Items)
        if ($itemList.Count -eq 0) {
            return 0
        }

        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in $itemList) {
            $key = Get-BookIdentityKey -Book $item -TitlePropertyName $TitlePropertyName -AuthorPropertyName $AuthorPropertyName -SeriesPropertyName $SeriesPropertyName -SeriesIndexPropertyName $SeriesIndexPropertyName
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                [void]$keys.Add($key)
            }
        }

        return $keys.Count
    }

    function Convert-ResponseTextToResultObject {
        param(
            [string]$RawText,
            [string]$SourceFile,
            [string]$AgentId,
            [int]$ExpectedUniqueBookCount = -1
        )

        $result = [ordered]@{
            source_file             = $SourceFile
            agent_id                = $AgentId
            status                  = 'success'
            input_unique_book_count = $null
            output_unique_book_count = 0
            unique_book_count_match = $null
            validation_error        = $null
            records                 = @()
            raw_response            = $RawText
            parse_error             = $null
        }

        if ($ExpectedUniqueBookCount -ge 0) {
            $result.input_unique_book_count = $ExpectedUniqueBookCount
        }

        $jsonText = Repair-MojibakeText -Text (Get-JsonText -RawText $RawText)
        $jsonText = Repair-JsonArrayFormatting -Text $jsonText
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            $result.status = 'error'
            $result.parse_error = 'No JSON structure could be extracted from the Mistral response.'
            return [pscustomobject]$result
        }

        $parsed = $null
        $candidateJsonTexts = @($jsonText)
        if ($jsonText -match '\\"') {
            $candidateJsonTexts += ($jsonText -replace '\\"', '"')
        }
        if ($jsonText -match '\\u') {
            $candidateJsonTexts += [System.Text.RegularExpressions.Regex]::Unescape($jsonText)
        }

        $lastParseError = $null
        foreach ($candidateJsonText in ($candidateJsonTexts | Select-Object -Unique)) {
            try {
                $parsed = ConvertFrom-Json -InputObject $candidateJsonText -ErrorAction Stop
                break
            }
            catch {
                $lastParseError = $_
                continue
            }
        }

        if ($null -eq $parsed) {
            $result.status = 'error'
            $result.parse_error = (Get-ErrorMessageFromException -ErrorRecord $lastParseError)
            return [pscustomobject]$result
        }

        if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
            $result.records = @($parsed)
        }
        else {
            $result.records = @($parsed)
        }

        $result.output_unique_book_count = Get-UniqueBookCount -Items $result.records -TitlePropertyName 'Title' -AuthorPropertyName 'Author'

        $validationMessages = @()

        if ($ExpectedUniqueBookCount -ge 0) {
            $result.unique_book_count_match = ($result.output_unique_book_count -eq $ExpectedUniqueBookCount)
            if (-not $result.unique_book_count_match) {
                $validationMessages += "Unique book count mismatch: input=$ExpectedUniqueBookCount, output=$($result.output_unique_book_count)."
            }
        }

        if ($validationMessages.Count -gt 0) {
            $result.status = 'warning'
            $result.validation_error = ($validationMessages -join ' ')
        }

        return [pscustomobject]$result
    }

    function Invoke-MistralRequest {
        param([string]$PayloadText)

        $script:LastApiErrorMessage = $null
        $script:LastApiErrorBody = $null

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
                    Write-Warning "Rate limit (429). Waiting $waitTime seconds... ($retryCount/$maxRetries)"
                    Start-Sleep -Seconds $waitTime
                }
                else {
                    Write-Warning "API request failed: HTTP $statusCode"

                    if ($statusCode -eq 400) {
                        Write-Warning "Possible causes: invalid agent ID, malformed payload, missing permissions."
                    }
                    elseif ($statusCode -eq 401) {
                        Write-Warning "Possible cause: API key is invalid or expired."
                    }
                    elseif ($statusCode -eq 500 -or $statusCode -eq 502 -or $statusCode -eq 503) {
                        Write-Warning "Server error at Mistral - retry later."
                    }

                    $errorBody = Get-ErrorBodyTextFromException -ErrorRecord $_
                    $originalError = Get-ErrorMessageFromException -ErrorRecord $_
                    if ([string]::IsNullOrWhiteSpace($originalError)) {
                        $originalError = $_.ToString()
                    }

                    $script:LastApiErrorMessage = ("HTTP {0}: {1}" -f $statusCode, $originalError)
                    $script:LastApiErrorBody = $errorBody

                    if (-not [string]::IsNullOrEmpty($errorBody)) {
                        Write-Warning "API response body: $errorBody"
                    }

                    Write-Warning "Original error: $originalError"
                    return $null
                }
            }
        }

        $script:LastApiErrorMessage = "API request aborted after $maxRetries attempts."
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
        $inputUniqueBookCount = -1

        # Count the number of unique books in the input file for output validation.
        try {
            $parsedInputBooks = ConvertFrom-Json -InputObject $bookContent -ErrorAction Stop
            if ($parsedInputBooks -is [System.Collections.IEnumerable] -and -not ($parsedInputBooks -is [string])) {
                $inputUniqueBookCount = Get-UniqueBookCount -Items $parsedInputBooks -TitlePropertyName 'Title' -AuthorPropertyName 'Author' -SeriesPropertyName 'Series' -SeriesIndexPropertyName 'SeriesIndex'
            }
            else {
                $inputUniqueBookCount = 1
            }
            Write-Host "  -> Input unique books: $inputUniqueBookCount" -ForegroundColor Gray
        }
        catch {
            $validationWarningText = "Validation warning in '$($bookFile.Name)': Could not parse input book JSON for count validation. $($_.Exception.Message)"
            Write-Log -Message "$ScriptLogPrefix $validationWarningText" -Warn
            Microsoft.PowerShell.Utility\Write-Warning $validationWarningText
        }

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

        # Send the prompt to the Mistral conversation endpoint, retrying on incomplete/invalid responses
        # (e.g. the model returning a raw tool-call marker instead of the final book data).
        $apiResult = $null
        $resultObject = $null
        $contentAttempt = 0

        while ($contentAttempt -lt $script:MaxContentRetries) {
            $contentAttempt++
            $apiResult = Invoke-MistralRequest -PayloadText $fullPrompt

            if ($null -eq $apiResult) {
                break
            }

            $resultObject = Convert-ResponseTextToResultObject -RawText $apiResult -SourceFile $bookFile.Name -AgentId $AgentId -ExpectedUniqueBookCount $inputUniqueBookCount

            if ($resultObject.status -eq 'success') {
                break
            }

            if ($contentAttempt -lt $script:MaxContentRetries) {
                $retryReason = if (-not [string]::IsNullOrWhiteSpace($resultObject.validation_error)) { $resultObject.validation_error } else { $resultObject.parse_error }
                Write-Warning "Invalid/incomplete response for '$($bookFile.Name)' (attempt $contentAttempt/$($script:MaxContentRetries)): $retryReason. Retrying..."
                Start-Sleep -Seconds 15
            }
        }

        if ($null -ne $apiResult) {
            $savedCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
            $outPath = Join-Path -Path $OutputDir -ChildPath $outName

            # Store a valid JSON wrapper so parse errors and raw API output are preserved.
            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($outPath, $jsonOutput, $utf8WithBom)

            if ($resultObject.status -eq 'success') {
                Write-Host "  -> Saved as: $outName" -ForegroundColor Green
                if ($null -ne $resultObject.unique_book_count_match) {
                    Write-Host "  -> Unique book count OK: input=$($resultObject.input_unique_book_count), output=$($resultObject.output_unique_book_count)" -ForegroundColor Green
                }
            }
            elseif ($resultObject.status -eq 'warning') {
                Write-Host "  -> Saved with validation warning: $outName" -ForegroundColor Yellow
                $validationWarningText = "Validation warning in '$($bookFile.Name)': $($resultObject.validation_error)"
                Write-Log -Message "$ScriptLogPrefix $validationWarningText" -Warn
                Microsoft.PowerShell.Utility\Write-Warning $validationWarningText
            }
            else {
                Write-Host "  -> Saved with parse error: $outName" -ForegroundColor Yellow
                $validationErrorText = "Validation error in '$($bookFile.Name)': $($resultObject.parse_error)"
                Write-Log -Message "$ScriptLogPrefix $validationErrorText" -IsError
                Microsoft.PowerShell.Utility\Write-Error -Message $validationErrorText -ErrorAction Continue
            }
        }
        else {
            $savedCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
            $outPath = Join-Path -Path $OutputDir -ChildPath $outName

            $apiDetail = $script:LastApiErrorMessage
            if ([string]::IsNullOrWhiteSpace($apiDetail)) {
                $apiDetail = 'No response from API.'
            }

            if (-not [string]::IsNullOrWhiteSpace($script:LastApiErrorBody)) {
                $apiDetail = "$apiDetail | API response: $($script:LastApiErrorBody)"
            }

            $resultObject = [pscustomobject][ordered]@{
                source_file              = $bookFile.Name
                agent_id                 = $AgentId
                status                   = 'error'
                input_unique_book_count  = if ($inputUniqueBookCount -ge 0) { $inputUniqueBookCount } else { $null }
                output_unique_book_count = 0
                unique_book_count_match  = $null
                validation_error         = $null
                records                  = @()
                raw_response             = if (-not [string]::IsNullOrWhiteSpace($script:LastApiErrorBody)) { $script:LastApiErrorBody } else { $apiDetail }
                parse_error              = $apiDetail
            }

            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($outPath, $jsonOutput, $utf8WithBom)

            Write-Host "  -> Saved with API error: $outName" -ForegroundColor Red
            $validationErrorText = "Validation error in '$($bookFile.Name)': $apiDetail"
            Write-Log -Message "$ScriptLogPrefix $validationErrorText" -IsError
            Microsoft.PowerShell.Utility\Write-Error -Message $validationErrorText -ErrorAction Continue
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

    # Log error exactly once in this script and mark it before rethrowing so
    # upstream wrappers can show the error in terminal without duplicate logging.
    Write-Error $errorMessage
    if ($null -ne $_.Exception) {
        $_.Exception.Data['LoggedByScript'] = $true
    }
    throw
}