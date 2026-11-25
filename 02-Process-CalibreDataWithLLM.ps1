<#
.SYNOPSIS
    Validate Calibre export data with the Google Gemini API.

.DESCRIPTION
    Reads the latest Calibre book export and tag-definition JSON files, sends each book's extracted content (or its stored content profile, see below) and existing tags together with the tag definitions to the Gemini Interactions API (prompt as system instruction), and writes the LLM responses to the 02-LLM-Result folder as individual JSON files.
    It validates unique-book counts per file (books are counted by Title and Author, the only identity fields of a result record), repairs mojibake in LLM responses, and stores the validation outcome in the output metadata.
    Before contacting the API, the script verifies that the export folder exists and that at least one book export and one tag export JSON file are present; otherwise it stops with an error.
    If a response is invalid or incomplete (e.g. a wrong unique-book count or a parse error), the request for that file is sent up to $MaxContentAttempts times in total before the result is saved.
    API requests are retried on HTTP 429, 500, 502, 503, and 504 and on connection failures without HTTP response (DNS lookup, connect, send/receive, timeout), with up to $MaxRequestAttempts attempts in total; there is no wait after the last failed attempt.
    An export file that is not valid JSON is not sent; it gets a result file with status error, so a resumed run tries it again.
    When Gemini blocks the request of a file with several books for prohibited content (HTTP 400), the books of that file are sent again one at a time, so only the book that triggers the block stays without audit. The file is then saved with a validation warning that names the books without result. A block is not retried, because Gemini blocks the same input again.
    Every input book without a record in the result (blocked, failed request, unparsable response, or simply left out by the LLM) is written to the result file as missing_books with Title, Author, and Reason, logged by title, and listed in the run summary under "Books without audit result". 03-Convert-LLMResults2ODS.ps1 turns these entries into rows with ProposedAction NOT_AUDITED, so their tags can be checked manually.
    Result files are written to LLM-Result_<nn>_<timestamp>.tmp first and then renamed to .json (Save-AtomicTextFile from Modules\Calibre.Storage.psm1), so a crash or power outage never leaves a truncated result file that a resumed run (-Resume) would count as done.
    A per-file validation check, per-file token usage, and a final run summary (start/end time, duration, retry statistics, and total token usage) are printed after processing.
    Token usage: every count has prompt tokens (input, including the cached part), cached tokens (the part of the prompt served from Gemini's cache at a lower rate), tool use tokens (search results the google_search tool added to the input), completion tokens (output plus thinking), and the total (prompt + tool use + completion). Besides the per-file token_usage in the result files, the script keeps the token ledger 02-LLM-Result\LLM-TokenUsage.json, which it updates after every Gemini response. The ledger therefore also counts the tokens of an export file whose processing was interrupted (Ctrl+C, crash) or repeated, which no result file holds. A new run starts a new ledger; a run with -Resume continues it. Invoke-CalibreToolsPipeline.ps1 reads the ledger for its summary.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 2.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

    Content profiles: for every book sent with its full text, the LLM also returns a content profile (a factual description of the excerpt in fixed facets, 400 to 700 words). The facets come from 02-CalibreContentProfile-Checklist.txt, which the script inserts into both prompt files at the placeholder {{CONTENT_PROFILE_CHECKLIST}}; they do not depend on the tag definitions, so a profile stays useful when tags are added or changed. A profile with fewer than $MinimumProfileWords words is stored with a warning. The script stores the profile in the book's cache file 01-Cache/<uuid>.json, but only when that file still holds the same book text (same ContentHash). On later runs, 01-Export-CalibreBooks.ps1 exports the profile with the book, and this script sends the profile instead of the full text while the profile has the current $ContentProfileVersion. This cuts the input tokens of a re-audited book from about 40,000 to about a thousand. Increase $ContentProfileVersion when the checklist or the profile instructions in a prompt change, so all profiles are rebuilt.
    Profile gaps: for a book sent with its profile, the LLM lists every tag whose decision the profile cannot settle (ProfileGaps). Each profile stores the fingerprints of the tag definitions that were already checked against the book's source (ContentProfileTagHashes: all tags for a profile written from the text, the focus tags of targeted searches for a web profile). A gap tag that is new or whose definition changed since then leads to a refresh in the same run: a text book is audited again with its full excerpt and gets a new profile; a book without text gets a new web search that targets the open tag definitions, and is audited again with the new profile. The refresh replaces the first results of these books. Gaps for unchanged definitions are not refreshed again, so the refresh cost stays bounded.
    Web content profiles: a book without text (ContentStatus NoText, e.g. a comic, manga, or graphic novel made of images) has no excerpt to write a profile from. Before the tag audit of each export file, the script sends each such book's metadata (title, author, series, identifiers, publisher, year, Calibre description) in a separate request with the google_search tool and the prompt 02-CalibreWebProfile-Prompt.txt; the tag definitions are not sent. The LLM identifies the exact work and writes a profile only from facts found in the search results and the description. The profile is stored in the cache file with ContentProfileSource Web and the cited web sources; when the work cannot be identified reliably, a WebNotFound marker is stored instead, so the book is not searched again until its identity metadata changes. The tag audit request itself never uses search. Google bills grounded requests per executed search query, so the number of search queries is logged per file and in the run summary.
    The book data and tag definitions are sent as compact JSON without indentation.

.PARAMETER Resume
    Continues an interrupted run: the result files already in 02-LLM-Result are kept (only orphaned LLM-Result_*.tmp files are removed), every export file whose result file is complete (valid JSON with a status other than error) is skipped, and the token ledger LLM-TokenUsage.json is continued (rebuilt from the result files when it is missing). Invoke-CalibreToolsPipeline.ps1 passes it when it resumes a run. Without -Resume, the result files of the previous run (LLM-Result_*.json) are removed at the start and the token ledger starts at 0; other files in the folder, such as the pipeline's run state file, are kept.

.PARAMETER FullContent
    Sends the full book text for every book, even when a content profile exists, and stores new profiles from the responses. Books without text get a new web content profile from a new Google Search (this costs search queries). Profile gaps already refresh the affected books automatically, so this is only needed to rebuild all profiles of the exported books at once.

.EXAMPLE
    .\02-Process-CalibreDataWithLLM.ps1
    Validates the latest book export and uses stored content profiles where available.

.EXAMPLE
    .\02-Process-CalibreDataWithLLM.ps1 -FullContent
    Validates the latest book export with the full book text of every book.

.EXAMPLE
    .\02-Process-CalibreDataWithLLM.ps1 -Resume
    Continues an interrupted run and skips the export files that already have a complete result.

.NOTES
    Version: 7.6
    Requires a JSON file Secrets/Gemini_API.json.key with the API key in the property APIKey and the prompt files 02-CalibreDataLLM-Prompt.txt, 02-CalibreWebProfile-Prompt.txt, and 02-CalibreContentProfile-Checklist.txt in the script folder.
    Each output file is written as a valid JSON object with metadata, records, missing books, content profiles, profile gaps, the profile refresh summary, token usage, the raw response text, parse errors, and validation details for unique-book counts.
    All attempt counts and wait intervals (API attempts on HTTP errors and connection failures, content-validation attempts, inter-file delay) are configured via $script: variables near the top of the script.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$FullContent,

    [Parameter()]
    [switch]$Resume
)

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

$CalibreTextModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Text.psd1"
if (-not (Test-Path -LiteralPath $CalibreTextModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Text.psd1'"
}

Import-Module -Name $CalibreTextModulePath -Force

$CalibreStorageModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Storage.psd1"
if (-not (Test-Path -LiteralPath $CalibreStorageModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Storage.psd1'"
}

Import-Module -Name $CalibreStorageModulePath -Force

# Start an own log session only when the script is not running inside the pipeline's session. -MaxFileSizeMB 0 turns off size-based rotation, so each run stays in one log file.
$ownsLogSession = -not (Test-LogSession)
if ($ownsLogSession) {
    Start-Log -LogDirectory 'Calibre_Tag_Auditor' -MaxFileSizeMB 0
}

try {
    # Enable strict error handling for the LLM workflow.
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $scriptStartTime = Get-Date

    # Resolve the script directory and required input/output paths.
    $ScriptDir = $PSScriptRoot
    $ExportDir = Join-Path -Path $ScriptDir -ChildPath "01-Export"
    $OutputDir = Join-Path -Path $ScriptDir -ChildPath "02-LLM-Result"
    $TokenLedgerFile = Join-Path -Path $OutputDir -ChildPath "LLM-TokenUsage.json"
    $ApiKeyFile = Join-Path -Path $ScriptDir -ChildPath "Secrets\Gemini_API.json.key"
    $PromptFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreDataLLM-Prompt.txt"
    $WebProfilePromptFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreWebProfile-Prompt.txt"
    $ChecklistFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreContentProfile-Checklist.txt"
    $CacheDir = Join-Path -Path $ScriptDir -ChildPath "01-Cache"

    # Increase ContentProfileVersion whenever the content profile checklist or the profile instructions in a prompt change, so all stored content profiles are rebuilt.
    $script:ContentProfileVersion = 2
    $script:MinimumProfileWords = 300                     # Text profiles with fewer words are stored with a warning.

    $Model = "gemini-3.8-flash"
    $ThinkingLevel = "medium"                             # Gemini thinking level: low, medium, or high.
    $InteractionsUrl = "https://generativelanguage.googleapis.com/v1beta/interactions"
    $ApiTimeoutSec = 300

    # Retry/backoff configuration for all retry activities in this script.
    $script:MaxRequestAttempts = 3                      # Attempts per API request in total on 429/500/502/503/504 errors and connection failures.
    $script:RateLimitRetryBaseSeconds = 30               # 429: base seconds for exponential backoff (wait = base * 2^attempt).
    $script:ServiceUnavailableRetryBaseSeconds = 5        # 500/502/503: base seconds for exponential backoff.
    $script:ServiceUnavailableRetryMaxSeconds = 60        # 500/502/503: cap (seconds) for exponential backoff.
    $script:GatewayTimeoutRetryIntervalSeconds = 300      # 504: fixed wait interval (seconds) between retries.
    $script:ConnectionRetryBaseSeconds = 15               # Connection failures without HTTP response (DNS, connect, timeout): base seconds for exponential backoff.
    $script:ConnectionRetryMaxSeconds = 120               # Connection failures: cap (seconds) for exponential backoff.
    $script:MaxContentAttempts = 3                        # Attempts per file in total for invalid/incomplete LLM responses.
    $script:ContentRetryDelaySeconds = 15                 # Wait (seconds) between content-validation retries.
    $script:InterFileDelaySeconds = 15                    # Wait (seconds) between two book files that were sent; none after the last file.

    $script:LastApiErrorMessage = $null
    $script:LastApiErrorBody = $null
    $script:LastApiStatusCode = $null

    # Ensure the output folder exists. Orphaned temporary result files (a write interrupted before its rename) are always removed. A new run also removes the result files of the previous run; a resumed run keeps them. Other files in the folder, such as the pipeline's run state file, are not touched.
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }
    else {
        @(Get-ChildItem -LiteralPath $OutputDir -Filter 'LLM-Result_*.tmp' -File) | Remove-Item -Force
        if ($Resume) {
            Write-ScriptLog "Resume: existing result files in 02-LLM-Result are kept; export files with a complete result are skipped."
            Write-Information -MessageData '' -InformationAction Continue
        }
        else {
            $jsonFiles = @(Get-ChildItem -LiteralPath $OutputDir -Filter 'LLM-Result_*.json' -File)
            if ($jsonFiles.Count -gt 0) {
                Write-ScriptLog "Cleaning $($jsonFiles.Count) result file(s) from 02-LLM-Result..."
                $jsonFiles | Remove-Item -Force
                Write-ScriptLog "Done."
                Write-Information -MessageData '' -InformationAction Continue
            }
        }
    }

    if (-not (Test-Path -Path $ApiKeyFile -PathType Leaf) -or -not (Test-Path -Path $PromptFile -PathType Leaf) -or -not (Test-Path -Path $WebProfilePromptFile -PathType Leaf) -or -not (Test-Path -Path $ChecklistFile -PathType Leaf)) {
        throw "API key or prompt file is missing in the script folder (Secrets\Gemini_API.json.key, 02-CalibreDataLLM-Prompt.txt, 02-CalibreWebProfile-Prompt.txt, 02-CalibreContentProfile-Checklist.txt)."
    }

    # Read the Gemini API key from the APIKey property of the JSON secrets file.
    function Get-GeminiApiKey {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Path
        )

        try {
            $secret = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "The Gemini API key file is not valid JSON: $($_.Exception.Message)"
        }

        if ($null -eq $secret -or $null -eq $secret.PSObject.Properties['APIKey'] -or [string]::IsNullOrWhiteSpace([string]$secret.APIKey)) {
            throw "The Gemini API key file contains no value for the property 'APIKey'."
        }

        return ([string]$secret.APIKey).Trim()
    }

    # Returns the prompt text with the placeholder {{CONTENT_PROFILE_CHECKLIST}} replaced by the checklist text; throws when the prompt has no placeholder, so a prompt is never sent without the checklist.
    function Merge-ContentProfileChecklist {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$PromptText,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$ChecklistText,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$PromptName
        )

        $placeholder = '{{CONTENT_PROFILE_CHECKLIST}}'
        if (-not $PromptText.Contains($placeholder)) {
            throw "The prompt file '$PromptName' has no placeholder $placeholder for the content profile checklist."
        }

        return $PromptText.Replace($placeholder, $ChecklistText)
    }

    # Load the API key and the prompt system from external files; both prompts get the shared content profile checklist.
    $ApiKey = Get-GeminiApiKey -Path $ApiKeyFile
    $ChecklistText = (Get-Content -Path $ChecklistFile -Raw -Encoding UTF8).Trim()
    $PromptSystem = Merge-ContentProfileChecklist -PromptText (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim() -ChecklistText $ChecklistText -PromptName (Split-Path -Path $PromptFile -Leaf)
    $WebProfilePromptSystem = Merge-ContentProfileChecklist -PromptText (Get-Content -Path $WebProfilePromptFile -Raw -Encoding UTF8).Trim() -ChecklistText $ChecklistText -PromptName (Split-Path -Path $WebProfilePromptFile -Leaf)

    # Require the export folder and both export types before contacting the API.
    if (-not (Test-Path -Path $ExportDir -PathType Container)) {
        throw "Export folder not found: '$(ConvertTo-DisplayPath -Path $ExportDir -BasePath $PSScriptRoot)'. Run 01-Export-CalibreBooks.ps1 and 01-Export-CalibreTags.ps1 first."
    }

    # Find the latest tag-definition file and the available book export files.
    $tagFile = Get-ChildItem -Path $ExportDir -Filter "02-Export-CalibreTags_*.json" -ErrorAction SilentlyContinue |
               Sort-Object -Property LastWriteTime -Descending |
               Select-Object -First 1

    $bookFiles = Get-ChildItem -Path $ExportDir -Filter "01-Export-CalibreBooks_*.json" -ErrorAction SilentlyContinue |
                 Sort-Object -Property Name

    if (-not $tagFile -or $bookFiles.Count -eq 0) {
        $missingParts = @()
        if (-not $tagFile) { $missingParts += "tag export file(s) (02-Export-CalibreTags_*.json) - run 01-Export-CalibreTags.ps1" }
        if ($bookFiles.Count -eq 0) { $missingParts += "book export file(s) (01-Export-CalibreBooks_*.json) - run 01-Export-CalibreBooks.ps1" }
        throw "Missing required export file(s) in folder '$(ConvertTo-DisplayPath -Path $ExportDir -BasePath $PSScriptRoot)': $($missingParts -join '; and ')."
    }

    # Load the tag definitions and print a short summary for the run.
    $tagContent = Get-Content -Path $tagFile.FullName -Raw -Encoding UTF8

    Write-ScriptLog "Tag file: $($tagFile.Name)"
    Write-ScriptLog "Found:    $($bookFiles.Count) book export files"
    Write-ScriptLog "Target:   $(ConvertTo-DisplayPath -Path $OutputDir -BasePath $PSScriptRoot)"
    Write-Information -MessageData '' -InformationAction Continue

    # Extracts a human-readable error message string from an ErrorRecord object.
    function Get-ErrorMessageFromException {
        [CmdletBinding()]
        [OutputType([string])]
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

    # Reads the HTTP error response body stream from an ErrorRecord object.
    function Get-ErrorBodyTextFromException {
        [CmdletBinding()]
        param([System.Management.Automation.ErrorRecord]$ErrorRecord)

        if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception -or $null -eq $ErrorRecord.Exception.Response) {
            return $null
        }

        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        }
        catch {
            return $null
        }
    }

    # Returns the WebExceptionStatus name (e.g. NameResolutionFailure, ConnectFailure, Timeout) when the error is a transient connection failure without HTTP response, which is worth a retry; returns $null for every other error.
    function Get-ConnectionFailureStatus {
        [CmdletBinding()]
        [OutputType([string])]
        param([System.Management.Automation.ErrorRecord]$ErrorRecord)

        if ($null -eq $ErrorRecord) {
            return $null
        }

        $transientStatuses = @('NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'SendFailure', 'ReceiveFailure', 'ConnectionClosed', 'KeepAliveFailure', 'PipelineFailure', 'Timeout')
        $exception = $ErrorRecord.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.Net.WebException]) {
                if ($null -ne $exception.Response) {
                    return $null
                }

                $status = [string]$exception.Status
                if ($transientStatuses -contains $status) {
                    return $status
                }

                return $null
            }

            $exception = $exception.InnerException
        }

        return $null
    }

    # Returns $true when the API rejected the request with HTTP 400 because its content violates Google's prohibited use policy (the response body mentions prohibited content).
    function Test-ProhibitedContentError {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [AllowNull()]
            [object]$StatusCode,
            [AllowNull()]
            [string]$ErrorBody
        )

        if ($null -eq $StatusCode -or [int]$StatusCode -ne 400 -or [string]::IsNullOrWhiteSpace($ErrorBody)) {
            return $false
        }

        return ($ErrorBody -match '(?i)prohibited (content|use)')
    }

    # Extracts the token usage of a Gemini interaction response: prompt (input, including the cached part), cached (the part of the prompt served from the cache at a lower rate), tool use (search results the google_search tool added to the input), completion (output plus thinking), and total (prompt + tool use + completion; the API's total_tokens only when none of the parts is reported).
    function Get-TokenUsageFromResponse {
        [CmdletBinding()]
        param($Response)

        if ($null -eq $Response -or $null -eq $Response.PSObject.Properties['usage'] -or $null -eq $Response.usage) {
            return $null
        }

        $usage = $Response.usage
        $promptTokens = $null
        $cachedTokens = $null
        $toolUseTokens = $null
        $completionTokens = $null
        $totalTokens = $null

        if ($null -ne $usage.PSObject.Properties['total_input_tokens']) {
            $promptTokens = [int64]$usage.total_input_tokens
        }
        if ($null -ne $usage.PSObject.Properties['total_cached_tokens']) {
            $cachedTokens = [int64]$usage.total_cached_tokens
        }
        if ($null -ne $usage.PSObject.Properties['total_tool_use_tokens']) {
            $toolUseTokens = [int64]$usage.total_tool_use_tokens
        }

        # Thinking tokens are billed as output tokens, so they count as completion tokens.
        foreach ($outputPropertyName in @('total_output_tokens', 'total_thought_tokens')) {
            if ($null -ne $usage.PSObject.Properties[$outputPropertyName]) {
                if ($null -eq $completionTokens) {
                    $completionTokens = [int64]0
                }
                $completionTokens += [int64]$usage.$outputPropertyName
            }
        }

        # Cached tokens are part of the prompt tokens, so they are not added to the total a second time.
        foreach ($partTokens in @($promptTokens, $toolUseTokens, $completionTokens)) {
            if ($null -ne $partTokens) {
                if ($null -eq $totalTokens) {
                    $totalTokens = [int64]0
                }
                $totalTokens += $partTokens
            }
        }
        if ($null -eq $totalTokens -and $null -ne $usage.PSObject.Properties['total_tokens']) {
            $totalTokens = [int64]$usage.total_tokens
        }

        return [pscustomobject]@{
            PromptTokens     = $promptTokens
            CachedTokens     = $cachedTokens
            ToolUseTokens    = $toolUseTokens
            CompletionTokens = $completionTokens
            TotalTokens      = $totalTokens
        }
    }

    # Joins the text items of all model output steps of a Gemini interaction response and logs the raw response when it contains no text.
    function Get-GeminiResponseText {
        [CmdletBinding()]
        [OutputType([string])]
        param($Response)

        if ($null -eq $Response) {
            Write-ScriptLog -Level WARN -Message "No response received from the Gemini API."
            return $null
        }

        if ($null -ne $Response.PSObject.Properties['status'] -and [string]$Response.status -ne 'completed') {
            Write-ScriptLog -Level WARN -Message "Gemini interaction finished with status '$($Response.status)'."
        }

        $textParts = @()
        if ($null -ne $Response.PSObject.Properties['steps']) {
            foreach ($step in @($Response.steps)) {
                if ($null -eq $step -or [string]$step.type -ne 'model_output' -or $null -eq $step.PSObject.Properties['content']) {
                    continue
                }

                foreach ($contentItem in @($step.content)) {
                    if ($null -ne $contentItem -and [string]$contentItem.type -eq 'text' -and -not [string]::IsNullOrEmpty([string]$contentItem.text)) {
                        $textParts += [string]$contentItem.text
                    }
                }
            }
        }

        if ($textParts.Count -gt 0) {
            return (Repair-MojibakeText -Text ($textParts -join ''))
        }

        Write-ScriptLog "--- Raw API response ---"
        Write-ScriptLog -Message ($Response | ConvertTo-Json -Depth 10)
        Write-ScriptLog "--- End response ---"
        Write-ScriptLog -Level WARN -Message "Response could not be parsed. See raw output above."
        # An empty text counts as an invalid response (retried, then saved with a parse error); the response JSON itself is no answer.
        return ''
    }

    # Returns the number of Google Search queries (google_search_call steps, arguments.queries) and the unique cited web sources (url_citation annotations of the model output, as Title and Url) of a Gemini interaction response.
    function Get-GeminiSearchSummary {
        [CmdletBinding()]
        param($Response)

        $queryCount = 0
        $sources = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $seenUrls = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

        if ($null -ne $Response -and $null -ne $Response.PSObject.Properties['steps']) {
            foreach ($step in @($Response.steps)) {
                if ($null -eq $step -or $null -eq $step.PSObject.Properties['type']) {
                    continue
                }

                if ([string]$step.type -eq 'google_search_call') {
                    if ($null -ne $step.PSObject.Properties['arguments'] -and $null -ne $step.arguments -and $null -ne $step.arguments.PSObject.Properties['queries']) {
                        $queryCount += @($step.arguments.queries | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
                    }
                    continue
                }

                if ([string]$step.type -ne 'model_output' -or $null -eq $step.PSObject.Properties['content']) {
                    continue
                }

                foreach ($contentItem in @($step.content)) {
                    if ($null -eq $contentItem -or $null -eq $contentItem.PSObject.Properties['annotations']) {
                        continue
                    }

                    foreach ($annotation in @($contentItem.annotations)) {
                        if ($null -eq $annotation -or [string]$annotation.type -ne 'url_citation' -or [string]::IsNullOrWhiteSpace([string]$annotation.url)) {
                            continue
                        }

                        if ($seenUrls.Add([string]$annotation.url)) {
                            $sources.Add([pscustomobject][ordered]@{ Title = [string]$annotation.title; Url = [string]$annotation.url })
                        }
                    }
                }
            }
        }

        return [pscustomobject]@{
            QueryCount = $queryCount
            Sources    = $sources.ToArray()
        }
    }

    # Removes markdown code block delimiters and repairs missing comma separators between JSON objects in array text.
    function Repair-JsonArrayFormatting {
        [CmdletBinding()]
        [OutputType([string])]
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

    # Returns the normalized identity key of a book (title and author in lower case with collapsed whitespace, joined with |). Input books and result records are compared by this key only, because a result record holds no other identity field; an empty key means the book has neither title nor author.
    function Get-BookIdentityKey {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [AllowNull()]
            [object]$Book
        )

        if ($null -eq $Book) {
            return ''
        }

        $normalizedParts = foreach ($propertyName in @('Title', 'Author')) {
            $value = ''
            if ($null -ne $Book.PSObject.Properties[$propertyName]) {
                $value = [string]$Book.$propertyName
            }
            $normalizedValue = ([regex]::Replace($value, '\s+', ' ').Trim()).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($normalizedValue)) {
                $normalizedValue
            }
        }

        return (@($normalizedParts) -join '|')
    }

    # Returns the number of different books (by Get-BookIdentityKey) in the items; items without title and author are not counted.
    function Get-UniqueBookCount {
        [CmdletBinding()]
        [OutputType([int])]
        param(
            [AllowNull()]
            [AllowEmptyCollection()]
            [object[]]$Items
        )

        if ($null -eq $Items) {
            return 0
        }

        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($item in @($Items)) {
            $key = Get-BookIdentityKey -Book $item
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                [void]$keys.Add($key)
            }
        }

        return $keys.Count
    }

    # Parses raw LLM text response into a structured result object with book records and validation metadata; the model name comes from $script:Model.
    function Convert-ResponseTextToResultObject {
        [CmdletBinding()]
        param(
            [string]$RawText,
            [string]$SourceFile,
            [int]$ExpectedUniqueBookCount = -1
        )

        $result = [ordered]@{
            source_file             = $SourceFile
            model                   = $script:Model
            status                  = 'success'
            input_unique_book_count = $null
            output_unique_book_count = 0
            unique_book_count_match = $null
            validation_error        = $null
            records                 = @()
            content_profiles        = @()
            profile_gaps            = @()
            token_usage             = $null
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
            $result.parse_error = 'No JSON structure could be extracted from the Gemini response.'
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

        # The prompt asks for an object with Results, ContentProfiles, and ProfileGaps; a plain array of result objects is still accepted.
        if ($parsed -isnot [System.Array] -and $null -ne $parsed.PSObject.Properties['Results']) {
            $result.records = @($parsed.Results | Where-Object { $null -ne $_ })
            if ($null -ne $parsed.PSObject.Properties['ContentProfiles']) {
                $result.content_profiles = @($parsed.ContentProfiles | Where-Object { $null -ne $_ })
            }
            if ($null -ne $parsed.PSObject.Properties['ProfileGaps']) {
                $result.profile_gaps = @($parsed.ProfileGaps | Where-Object { $null -ne $_ })
            }
        }
        else {
            $result.records = @($parsed)
        }

        $result.output_unique_book_count = Get-UniqueBookCount -Items $result.records

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

    # Decodes the raw bytes of a web response as UTF-8 and parses them as JSON, independent of the charset in the server's Content-Type header (Windows PowerShell 5.1 falls back to ISO-8859-1 without one).
    function ConvertFrom-Utf8JsonResponse {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$WebResponse
        )

        $bytes = $WebResponse.RawContentStream.ToArray()
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            $text = $text.Substring(1)
        }

        return (ConvertFrom-Json -InputObject $text -ErrorAction Stop)
    }

    # Converts an object to JSON without indentation and turns the \u00XX escapes that Windows PowerShell 5.1 writes for &, ', <, and > back into the characters, because every escape costs several tokens. An escaped backslash before such a sequence is kept, so literal backslash-u text in the content stays unchanged.
    function ConvertTo-CompactJson {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$InputObject,
            [ValidateRange(1, 100)]
            [int]$Depth = 10
        )

        $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
        return (Restore-JsonEscapedCharacter -Json $json)
    }

    # Returns $true when the book export record holds a non-empty content profile of the current $script:ContentProfileVersion.
    function Test-ContentProfile {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book
        )

        if ($null -eq $Book.PSObject.Properties['ContentProfile'] -or $null -eq $Book.PSObject.Properties['ContentProfileVersion']) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace([string]$Book.ContentProfile)) {
            return $false
        }

        return ([string]$Book.ContentProfileVersion -eq [string]$script:ContentProfileVersion)
    }

    # Returns $true when the export record is a book without text (ContentStatus NoText).
    function Test-NoTextBook {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book
        )

        return ($null -ne $Book.PSObject.Properties['ContentStatus'] -and [string]$Book.ContentStatus -eq 'NoText')
    }

    # Returns $true when a book without text needs a new web content profile: it has a UUID and ContentHash to store the profile under, and FullContent is set or it has neither a current profile nor a current WebNotFound marker.
    function Test-WebProfileRequired {
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [switch]$FullContent
        )

        if (-not (Test-NoTextBook -Book $Book)) {
            return $false
        }

        if ($null -eq $Book.PSObject.Properties['Uuid'] -or [string]::IsNullOrWhiteSpace([string]$Book.Uuid) -or $null -eq $Book.PSObject.Properties['ContentHash'] -or [string]::IsNullOrWhiteSpace([string]$Book.ContentHash)) {
            return $false
        }

        if ($FullContent) {
            return $true
        }

        if ($null -eq $Book.PSObject.Properties['ContentProfileVersion'] -or [string]$Book.ContentProfileVersion -ne [string]$script:ContentProfileVersion) {
            return $true
        }

        $isNotFoundMarker = $null -ne $Book.PSObject.Properties['ContentProfileSource'] -and [string]$Book.ContentProfileSource -eq 'WebNotFound'
        $hasProfile = $null -ne $Book.PSObject.Properties['ContentProfile'] -and -not [string]::IsNullOrWhiteSpace([string]$Book.ContentProfile)
        return (-not ($isNotFoundMarker -or $hasProfile))
    }

    # Builds the web profile input record of a book without text: the identity metadata and the plain-text Calibre description that help to identify the exact work.
    function ConvertTo-WebProfileRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book
        )

        return [ordered]@{
            Title       = $Book.Title
            Author      = $Book.Author
            Series      = $Book.Series
            SeriesIndex = $Book.SeriesIndex
            IDs         = $Book.IDs
            Publisher   = $Book.Publisher
            Year        = $Book.Year
            Description = $Book.Description
        }
    }

    # Parses the web profile response text into an object with the trimmed ContentProfile (empty when the work could not be identified reliably), or returns $null when the text holds no JSON object with a ContentProfile key.
    function ConvertFrom-WebProfileResponse {
        [CmdletBinding()]
        param([string]$RawText)

        $jsonText = Repair-JsonArrayFormatting -Text (Repair-MojibakeText -Text (Get-JsonText -RawText $RawText))
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            return $null
        }

        try {
            $parsed = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
        }
        catch {
            return $null
        }

        if ($null -eq $parsed -or $parsed -is [System.Array] -or $null -eq $parsed.PSObject.Properties['ContentProfile']) {
            return $null
        }

        $profileText = ''
        if ($null -ne $parsed.ContentProfile) {
            $profileText = ([string]$parsed.ContentProfile).Trim()
        }

        return [pscustomobject]@{ ContentProfile = $profileText }
    }

    # Returns an empty token usage counter (Available $false, all token counts 0).
    function Get-TokenUsageCounter {
        [CmdletBinding()]
        param()

        return [pscustomobject]@{ Available = $false; PromptTokens = [int64]0; CachedTokens = [int64]0; ToolUseTokens = [int64]0; CompletionTokens = [int64]0; TotalTokens = [int64]0 }
    }

    # Adds the prompt, cached, tool use, completion, and total tokens of one request (or of another counter) to a usage counter from Get-TokenUsageCounter; a $null token usage leaves the counter unchanged, a missing or $null count adds nothing.
    function Add-TokenUsage {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Counter,
            [AllowNull()]
            [object]$TokenUsage
        )

        if ($null -eq $TokenUsage) {
            return
        }

        $Counter.Available = $true
        foreach ($propertyName in @('PromptTokens', 'CachedTokens', 'ToolUseTokens', 'CompletionTokens', 'TotalTokens')) {
            if ($null -ne $TokenUsage.PSObject.Properties[$propertyName] -and $null -ne $TokenUsage.$propertyName) {
                $Counter.$propertyName += [int64]$TokenUsage.$propertyName
            }
        }
    }

    # Returns the token_usage object of a result file or of the token ledger: the counts of a usage counter (all $null when the counter is not Available) and the number of web search queries.
    function ConvertTo-TokenUsageRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Counter,
            [int64]$SearchQueryCount = 0
        )

        return [ordered]@{
            prompt_tokens      = if ($Counter.Available) { $Counter.PromptTokens } else { $null }
            cached_tokens      = if ($Counter.Available) { $Counter.CachedTokens } else { $null }
            tool_use_tokens    = if ($Counter.Available) { $Counter.ToolUseTokens } else { $null }
            completion_tokens  = if ($Counter.Available) { $Counter.CompletionTokens } else { $null }
            total_tokens       = if ($Counter.Available) { $Counter.TotalTokens } else { $null }
            web_search_queries = $SearchQueryCount
        }
    }

    # Formats the counts of a usage counter for the log, with the total last: prompt (with its cached part), tool use, completion, total.
    function Format-TokenUsage {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Counter
        )

        return "prompt=$($Counter.PromptTokens.ToString('N0')) (cached=$($Counter.CachedTokens.ToString('N0'))), tool use=$($Counter.ToolUseTokens.ToString('N0')), completion=$($Counter.CompletionTokens.ToString('N0')), total=$($Counter.TotalTokens.ToString('N0'))"
    }

    # Adds the token_usage object of a result file or of the token ledger to a usage counter and returns its web_search_queries (0 when missing). Files written before cached and tool use tokens were recorded add only the counts they hold; a missing total is computed as prompt + tool use + completion.
    function Add-TokenUsageRecord {
        [CmdletBinding()]
        [OutputType([int], [long])]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Counter,
            [AllowNull()]
            [object]$Record
        )

        if ($null -eq $Record) {
            return 0
        }

        $tokenUsage = Get-TokenUsageCounter
        $propertyMap = [ordered]@{ prompt_tokens = 'PromptTokens'; cached_tokens = 'CachedTokens'; tool_use_tokens = 'ToolUseTokens'; completion_tokens = 'CompletionTokens'; total_tokens = 'TotalTokens' }
        foreach ($recordPropertyName in $propertyMap.Keys) {
            if ($null -ne $Record.PSObject.Properties[$recordPropertyName] -and $null -ne $Record.$recordPropertyName) {
                $tokenUsage.Available = $true
                $tokenUsage.($propertyMap[$recordPropertyName]) = [int64]$Record.$recordPropertyName
            }
        }
        if ($null -eq $Record.PSObject.Properties['total_tokens'] -or $null -eq $Record.total_tokens) {
            $tokenUsage.TotalTokens = $tokenUsage.PromptTokens + $tokenUsage.ToolUseTokens + $tokenUsage.CompletionTokens
        }
        if ($tokenUsage.Available) {
            Add-TokenUsage -Counter $Counter -TokenUsage $tokenUsage
        }

        if ($null -ne $Record.PSObject.Properties['web_search_queries'] -and $null -ne $Record.web_search_queries) {
            return [int64]$Record.web_search_queries
        }
        return 0
    }

    # Prepares the token ledger of the run in $script:TokenLedger, which counts the tokens and search queries of every Gemini response, including the requests of export files that never got a result file (interrupted run, Ctrl+C, crash). A resumed run continues the existing ledger file; otherwise, or when the ledger file is missing or invalid, the ledger starts from the token_usage of the result files in the folder (none after the cleanup of a new run). The ledger is written to the file right away.
    function Initialize-TokenLedger {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Path,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$ResultDirectory,
            [switch]$Resume
        )

        $ledger = Get-TokenUsageCounter
        $ledger | Add-Member -MemberType NoteProperty -Name 'SearchQueryCount' -Value ([int64]0)
        $ledger | Add-Member -MemberType NoteProperty -Name 'RequestCount' -Value ([int64]0)

        $storedLedger = $null
        if ($Resume -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            try {
                $storedLedger = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $storedLedger = $null
            }
        }

        if ($null -ne $storedLedger) {
            $ledger.SearchQueryCount = Add-TokenUsageRecord -Counter $ledger -Record $storedLedger
            if ($null -ne $storedLedger.PSObject.Properties['requests'] -and $null -ne $storedLedger.requests) {
                $ledger.RequestCount = [int64]$storedLedger.requests
            }
        }
        else {
            foreach ($resultFile in @(Get-ChildItem -LiteralPath $ResultDirectory -Filter 'LLM-Result_*.json' -File)) {
                try {
                    $result = [System.IO.File]::ReadAllText($resultFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    continue
                }
                if ($null -ne $result -and $null -ne $result.PSObject.Properties['token_usage']) {
                    $ledger.SearchQueryCount += Add-TokenUsageRecord -Counter $ledger -Record $result.token_usage
                }
            }
        }

        $script:TokenLedgerPath = $Path
        $script:TokenLedger = $ledger
        Save-TokenLedger
    }

    # Writes $script:TokenLedger to $script:TokenLedgerPath through a temporary file (Save-AtomicTextFile), so an interruption never leaves a truncated ledger.
    function Save-TokenLedger {
        [CmdletBinding()]
        param()

        $record = ConvertTo-TokenUsageRecord -Counter $script:TokenLedger -SearchQueryCount $script:TokenLedger.SearchQueryCount
        $record['requests'] = $script:TokenLedger.RequestCount
        Save-AtomicTextFile -Path $script:TokenLedgerPath -Content (ConvertTo-Json -InputObject $record)
    }

    # Adds the token usage and search queries of one Gemini response to the token ledger and writes it at once, so the tokens stay counted even when the run is interrupted before the result file of the export file is written. Does nothing while no ledger is initialized; a failed write is logged as a warning and does not stop the run.
    function Add-TokenLedgerUsage {
        [CmdletBinding()]
        param(
            [AllowNull()]
            [object]$TokenUsage,
            [int64]$SearchQueryCount = 0
        )

        if ($null -eq $script:TokenLedger) {
            return
        }

        $script:TokenLedger.RequestCount++
        $script:TokenLedger.SearchQueryCount += $SearchQueryCount
        Add-TokenUsage -Counter $script:TokenLedger -TokenUsage $TokenUsage
        try {
            Save-TokenLedger
        }
        catch {
            Write-ScriptLog -Level WARN -Message "The token ledger could not be written: $($_.Exception.Message)"
        }
    }

    # Requests a web content profile for one book without text: sends the book metadata (and, for a targeted search, the focus tag definitions as JSON) with the web profile prompt and the google_search tool, retries invalid responses up to $MaxContentAttempts attempts, and adds the token usage to the counter. Returns ContentProfile ($null when the request failed, empty when the work was not identified), the cited Sources, and the SearchQueryCount of all attempts.
    function Request-WebContentProfile {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [AllowEmptyString()]
            [string]$FocusTagDefinitions = '',
            [Parameter(Mandatory = $true)]
            [object]$UsageCounter
        )

        $bookInput = ConvertTo-CompactJson -InputObject (ConvertTo-WebProfileRecord -Book $Book) -Depth 5
        $payload = @"
===================================
BOOK METADATA:
===================================
$bookInput
"@
        if (-not [string]::IsNullOrWhiteSpace($FocusTagDefinitions)) {
            $payload += @"


===================================
FOCUS QUESTIONS:
===================================
$FocusTagDefinitions
"@
        }

        $searchQueryCount = 0
        for ($attempt = 1; $attempt -le $script:MaxContentAttempts; $attempt++) {
            $requestResult = Invoke-GeminiRequest -PayloadText $payload -SystemInstruction $script:WebProfilePromptSystem -UseGoogleSearch
            if ($null -eq $requestResult) {
                break
            }

            Add-TokenUsage -Counter $UsageCounter -TokenUsage $requestResult.TokenUsage
            $searchQueryCount += [int]$requestResult.SearchQueryCount

            $webProfile = ConvertFrom-WebProfileResponse -RawText $requestResult.Text
            if ($null -ne $webProfile) {
                return [pscustomobject]@{
                    ContentProfile   = $webProfile.ContentProfile
                    Sources          = @($requestResult.Sources)
                    SearchQueryCount = $searchQueryCount
                }
            }

            if ($attempt -lt $script:MaxContentAttempts) {
                Write-ScriptLog -Level WARN -Message "Invalid web profile response for '$($Book.Title)' (attempt $attempt/$($script:MaxContentAttempts)). Retrying..."
                Start-Sleep -Seconds $script:ContentRetryDelaySeconds
            }
        }

        return [pscustomobject]@{
            ContentProfile   = $null
            Sources          = @()
            SearchQueryCount = $searchQueryCount
        }
    }

    # Adds the content profile fields (ContentProfile, current ContentProfileVersion, ContentProfileSource, ContentProfileSources, ContentProfileTagHashes) to the export record in memory, so the tag audit of this run uses the new profile.
    function Add-BookContentProfile {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [object]$ProfileData
        )

        $tagHashes = $null
        if ($null -ne $ProfileData.PSObject.Properties['TagHashes']) {
            $tagHashes = $ProfileData.TagHashes
        }

        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfile' -Value ([string]$ProfileData.ContentProfile) -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileVersion' -Value $script:ContentProfileVersion -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileSource' -Value ([string]$ProfileData.Source) -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileSources' -Value $ProfileData.Sources -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileTagHashes' -Value $tagHashes -Force
    }

    # Returns an ordered dictionary from tag name to the fingerprint of its definition (the first 16 hex characters of the SHA256 hash of NoteText), sorted by tag name. Content profiles store these fingerprints, so a later run can tell which tag definitions are new or changed since the profile was written. Entries without a tag name are skipped.
    function Get-TagDefinitionHashTable {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$TagDefinitions
        )

        $result = [ordered]@{}
        $namedDefinitions = @($TagDefinitions | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Tag'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Tag) })
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            foreach ($definition in ($namedDefinitions | Sort-Object -Property { ([string]$_.Tag).Trim() })) {
                $noteText = ''
                if ($null -ne $definition.PSObject.Properties['NoteText'] -and $null -ne $definition.NoteText) {
                    $noteText = [string]$definition.NoteText
                }

                $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($noteText))
                $result[([string]$definition.Tag).Trim()] = (($hashBytes[0..7] | ForEach-Object { $_.ToString('x2') }) -join '')
            }
        }
        finally {
            $sha256.Dispose()
        }

        return $result
    }

    # Converts stored tag definition fingerprints (a JSON object read from an export or cache file, or a dictionary) into a hashtable from tag name to fingerprint; $null or any other value gives an empty hashtable.
    function ConvertTo-TagHashTable {
        [CmdletBinding()]
        param(
            [AllowNull()]
            [object]$InputObject
        )

        $result = @{}
        if ($null -eq $InputObject) {
            return $result
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            foreach ($key in $InputObject.Keys) {
                $result[[string]$key] = [string]$InputObject[$key]
            }
            return $result
        }

        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $InputObject.PSObject.Properties) {
                $result[$property.Name] = [string]$property.Value
            }
        }

        return $result
    }

    # Returns a copy of the stored fingerprints in which the given tags get their current fingerprint; names that are not in the current fingerprints are ignored. Used for a web profile, which records only the tags of its targeted searches.
    function Merge-TagHashTable {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary]$StoredTagHashes,
            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary]$CurrentTagHashes,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$TagNames
        )

        $result = @{}
        foreach ($key in $StoredTagHashes.Keys) {
            $result[[string]$key] = [string]$StoredTagHashes[$key]
        }

        foreach ($tagName in $TagNames) {
            if ($CurrentTagHashes.Contains($tagName)) {
                $result[$tagName] = [string]$CurrentTagHashes[$tagName]
            }
        }

        return $result
    }

    # Returns the tag definitions whose Tag name is in TagNames (case-insensitive), in the order of the definitions.
    function Select-TagDefinition {
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$TagDefinitions,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [string[]]$TagNames
        )

        $names = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($tagName in $TagNames) {
            [void]$names.Add($tagName.Trim())
        }

        return @($TagDefinitions | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['Tag'] -and $names.Contains(([string]$_.Tag).Trim()) })
    }

    # Returns the books of a tag audit response whose profile gaps justify a refresh. Each candidate holds the BookId, the export record (Book), the Kind (Text: audit again with the full excerpt; Web: new targeted web search), and the gap Tags that exist in the current tag definitions and whose fingerprint differs from the one stored with the book's profile (new or changed definitions). Gaps of unknown BookIds, repeated gap objects of a book, gaps of books whose profile cannot be refreshed (a text profile without BookContent, a web profile without UUID or ContentHash), and gaps without such tags are skipped.
    function Get-ProfileRefreshCandidate {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [AllowEmptyCollection()]
            [object[]]$ProfileGaps,
            [Parameter(Mandatory = $true)]
            [hashtable]$ProfileBooksById,
            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary]$TagHashes
        )

        $candidates = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $seenBookIds = New-Object -TypeName 'System.Collections.Generic.HashSet[int]'
        foreach ($profileGap in $ProfileGaps) {
            if ($null -eq $profileGap -or $null -eq $profileGap.PSObject.Properties['BookId'] -or $null -eq $profileGap.PSObject.Properties['Tags']) {
                continue
            }

            $bookId = 0
            if (-not [int]::TryParse([string]$profileGap.BookId, [ref]$bookId) -or -not $ProfileBooksById.ContainsKey($bookId) -or -not $seenBookIds.Add($bookId)) {
                continue
            }

            $book = $ProfileBooksById[$bookId]
            $kind = 'Text'
            if ($null -ne $book.PSObject.Properties['ContentProfileSource'] -and [string]$book.ContentProfileSource -eq 'Web') {
                $kind = 'Web'
            }

            if ($kind -eq 'Text' -and ($null -eq $book.PSObject.Properties['BookContent'] -or [string]::IsNullOrEmpty([string]$book.BookContent))) {
                continue
            }
            if ($kind -eq 'Web' -and ($null -eq $book.PSObject.Properties['Uuid'] -or [string]::IsNullOrWhiteSpace([string]$book.Uuid) -or $null -eq $book.PSObject.Properties['ContentHash'] -or [string]::IsNullOrWhiteSpace([string]$book.ContentHash))) {
                continue
            }

            $storedTagHashes = @{}
            if ($null -ne $book.PSObject.Properties['ContentProfileTagHashes']) {
                $storedTagHashes = ConvertTo-TagHashTable -InputObject $book.ContentProfileTagHashes
            }

            $tags = New-Object -TypeName 'System.Collections.Generic.List[string]'
            foreach ($tag in @($profileGap.Tags)) {
                $tagName = ([string]$tag).Trim()
                if ([string]::IsNullOrEmpty($tagName) -or -not $TagHashes.Contains($tagName) -or $tags.Contains($tagName)) {
                    continue
                }
                if ($storedTagHashes.ContainsKey($tagName) -and [string]$storedTagHashes[$tagName] -ceq [string]$TagHashes[$tagName]) {
                    continue
                }
                $tags.Add($tagName)
            }

            if ($tags.Count -gt 0) {
                $candidates.Add([pscustomobject]@{ BookId = $bookId; Book = $book; Kind = $kind; Tags = $tags.ToArray() })
            }
        }

        return $candidates.ToArray()
    }

    # Replaces the results of the books that were audited again in a profile refresh: for every refresh input book with at least one record in the refresh response (matched by Title and Author), the records of the first audit are removed and the refresh records are added; the refresh content profiles are appended. Refresh records of books that were not in the refresh request are ignored, and a book without refresh record keeps its first result. Returns the number of replaced books.
    function Merge-RefreshedAuditRecord {
        [CmdletBinding()]
        [OutputType([int])]
        param(
            [Parameter(Mandatory = $true)]
            [object]$ResultObject,
            [Parameter(Mandatory = $true)]
            [object]$RefreshResultObject,
            [Parameter(Mandatory = $true)]
            [object[]]$BookRecords
        )

        $requestedKeys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($bookRecord in $BookRecords) {
            [void]$requestedKeys.Add((Get-BookIdentityKey -Book ([pscustomobject]$bookRecord)))
        }

        $refreshRecords = @($RefreshResultObject.records | Where-Object { $null -ne $_ -and $requestedKeys.Contains((Get-BookIdentityKey -Book $_)) })
        $replacedKeys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($refreshRecord in $refreshRecords) {
            [void]$replacedKeys.Add((Get-BookIdentityKey -Book $refreshRecord))
        }

        if ($replacedKeys.Count -eq 0) {
            return 0
        }

        $keptRecords = @($ResultObject.records | Where-Object { $null -ne $_ -and -not $replacedKeys.Contains((Get-BookIdentityKey -Book $_)) })
        $ResultObject.records = @($keptRecords) + @($refreshRecords)
        $ResultObject.content_profiles = @($ResultObject.content_profiles) + @($RefreshResultObject.content_profiles | Where-Object { $null -ne $_ })
        return $replacedKeys.Count
    }

    # Builds the LLM input record of one book with a request-local BookId: the identity fields, the current tags, and either the stored content profile (when it is valid and FullContent is not set, or always for a book without text) or the extracted BookContent. A web profile is marked with ContentProfileSource Web.
    function ConvertTo-BookAnalysisRecord {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [ValidateRange(1, [int]::MaxValue)]
            [int]$BookId,
            [switch]$FullContent
        )

        $record = [ordered]@{
            BookId              = $BookId
            Title               = $Book.Title
            Author              = $Book.Author
            Series              = $Book.Series
            SeriesIndex         = $Book.SeriesIndex
            ExistingCalibreTags = $Book.Tags
        }

        if ((-not $FullContent -or (Test-NoTextBook -Book $Book)) -and (Test-ContentProfile -Book $Book)) {
            $record.ContentProfile = [string]$Book.ContentProfile
            if ($null -ne $Book.PSObject.Properties['ContentProfileSource'] -and [string]$Book.ContentProfileSource -eq 'Web') {
                $record.ContentProfileSource = 'Web'
            }
        }
        else {
            $record.BookContent = $Book.BookContent
        }

        return $record
    }

    # Stores a content profile (ProfileData with ContentProfile, Source Text/Web/WebNotFound, and optional Sources and TagHashes) in the book's cache file 01-Cache/<uuid>.json, logs the cache file path, and returns $true. Returns $false without writing when the profile is empty without being a WebNotFound marker, the UUID is invalid, the cache file is missing or unreadable, or the file holds a different ContentHash, so a profile never belongs to another text or other metadata.
    function Update-BookCacheProfile {
        [CmdletBinding(SupportsShouldProcess = $true)]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$CacheDirectory,
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [object]$ProfileData
        )

        $contentProfile = [string]$ProfileData.ContentProfile
        $source = [string]$ProfileData.Source
        if ($source -notin @('Text', 'Web', 'WebNotFound') -or ([string]::IsNullOrWhiteSpace($contentProfile) -and $source -ne 'WebNotFound')) {
            return $false
        }

        $sources = $null
        if ($null -ne $ProfileData.PSObject.Properties['Sources'] -and @($ProfileData.Sources).Count -gt 0) {
            $sources = @($ProfileData.Sources)
        }

        $tagHashes = $null
        if ($null -ne $ProfileData.PSObject.Properties['TagHashes'] -and $null -ne $ProfileData.TagHashes) {
            $tagHashes = $ProfileData.TagHashes
        }

        $uuid = $null
        $contentHash = $null
        if ($null -ne $Book.PSObject.Properties['Uuid']) { $uuid = [string]$Book.Uuid }
        if ($null -ne $Book.PSObject.Properties['ContentHash']) { $contentHash = [string]$Book.ContentHash }

        if (-not (Test-CalibreUuid -Uuid $uuid) -or [string]::IsNullOrEmpty($contentHash)) {
            return $false
        }

        $path = Join-Path -Path $CacheDirectory -ChildPath ("{0}.json" -f $uuid.ToLowerInvariant())
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }

        try {
            $cached = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
        }
        catch {
            return $false
        }

        if ($null -eq $cached -or $null -eq $cached.PSObject.Properties['ContentHash'] -or [string]$cached.ContentHash -cne $contentHash) {
            return $false
        }

        $cached | Add-Member -MemberType NoteProperty -Name 'ContentProfile' -Value $contentProfile -Force
        $cached | Add-Member -MemberType NoteProperty -Name 'ContentProfileVersion' -Value $script:ContentProfileVersion -Force
        $cached | Add-Member -MemberType NoteProperty -Name 'ContentProfileSource' -Value $source -Force
        $cached | Add-Member -MemberType NoteProperty -Name 'ContentProfileSources' -Value $sources -Force
        $cached | Add-Member -MemberType NoteProperty -Name 'ContentProfileTagHashes' -Value $tagHashes -Force

        if (-not $PSCmdlet.ShouldProcess($path, 'Store content profile')) {
            return $false
        }

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $cached -Depth 10), $utf8NoBom)
        Write-ScriptLog -Message ("Stored content profile ({0}) of '{1}' in cache file: {2}" -f $source, $Book.Title, (ConvertTo-DisplayPath -Path $path -BasePath $PSScriptRoot))
        return $true
    }

    # Stores the content profiles of an LLM response in the cache files, together with the fingerprints of all current tag definitions ($script:TagDefinitionHashes), and returns the number of stored profiles. Only profiles whose BookId belongs to a book of this request that was sent with its full text are stored; unknown IDs, books sent as a profile, and empty profiles are skipped. A stored profile with fewer than $script:MinimumProfileWords words is logged as a warning.
    function Save-ContentProfile {
        [CmdletBinding(SupportsShouldProcess = $true)]
        [OutputType([int])]
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$ContentProfiles,
            [Parameter(Mandatory = $true)]
            [hashtable]$FullTextBooksById,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$CacheDirectory
        )

        $savedCount = 0
        foreach ($contentProfile in $ContentProfiles) {
            if ($null -eq $contentProfile -or $null -eq $contentProfile.PSObject.Properties['BookId'] -or $null -eq $contentProfile.PSObject.Properties['ContentProfile']) {
                continue
            }

            $bookId = 0
            if (-not [int]::TryParse([string]$contentProfile.BookId, [ref]$bookId) -or -not $FullTextBooksById.ContainsKey($bookId)) {
                continue
            }

            $profileText = ([string]$contentProfile.ContentProfile).Trim()
            if ([string]::IsNullOrWhiteSpace($profileText)) {
                continue
            }

            $book = $FullTextBooksById[$bookId]
            if (-not $PSCmdlet.ShouldProcess([string]$book.Title, 'Store content profile')) {
                continue
            }

            try {
                $profileData = [pscustomobject]@{ ContentProfile = $profileText; Source = 'Text'; Sources = $null; TagHashes = $script:TagDefinitionHashes }
                if (Update-BookCacheProfile -CacheDirectory $CacheDirectory -Book $book -ProfileData $profileData) {
                    $savedCount++
                    $wordCount = @($profileText -split '\s+' | Where-Object { $_ }).Count
                    if ($wordCount -lt $script:MinimumProfileWords) {
                        Write-ScriptLog -Level WARN -Message ("Content profile of '{0}' has only {1} words (expected at least {2})." -f $book.Title, $wordCount, $script:MinimumProfileWords)
                    }
                }
                else {
                    Write-ScriptLog -Level WARN -Message ("Content profile of '{0}' was not stored: no matching cache file for this book text." -f $book.Title)
                }
            }
            catch {
                Write-ScriptLog -Level WARN -Message ("Content profile of '{0}' was not stored: {1}" -f $book.Title, $_.Exception.Message)
            }
        }

        return $savedCount
    }

    # Returns the seconds to wait before the next attempt of a failed request, or $null when the error is not worth a retry. Connection failures without HTTP response and HTTP 500/502/503 use a capped exponential backoff, HTTP 429 an uncapped exponential backoff, and HTTP 504 a fixed interval; RetryNumber is the number of the failed attempt (1 for the first).
    function Get-RetryWaitSecond {
        [CmdletBinding()]
        [OutputType([double])]
        param(
            [AllowNull()]
            [object]$StatusCode,
            [AllowNull()]
            [AllowEmptyString()]
            [string]$ConnectionFailure,
            [Parameter(Mandatory = $true)]
            [ValidateRange(1, 100)]
            [int]$RetryNumber
        )

        if (-not [string]::IsNullOrEmpty($ConnectionFailure)) {
            return [math]::Min($script:ConnectionRetryMaxSeconds, [math]::Pow(2, $RetryNumber) * $script:ConnectionRetryBaseSeconds)
        }

        if ($null -eq $StatusCode) {
            return $null
        }

        switch ([int]$StatusCode) {
            429 { return [math]::Pow(2, $RetryNumber) * $script:RateLimitRetryBaseSeconds }
            { $_ -in @(500, 502, 503) } { return [math]::Min($script:ServiceUnavailableRetryMaxSeconds, [math]::Pow(2, $RetryNumber) * $script:ServiceUnavailableRetryBaseSeconds) }
            504 { return $script:GatewayTimeoutRetryIntervalSeconds }
        }

        return $null
    }

    # Sends the payload with a system instruction (by default the tag audit prompt) to the Gemini Interactions API with automatic retry on rate limits, HTTP server errors (500/502/503/504), and connection failures without HTTP response, and returns the response text, token usage, search query count, and cited sources. -UseGoogleSearch enables the google_search tool. The request body is sent as UTF-8 bytes and the response is decoded as UTF-8, so umlauts and typographic characters do not depend on PowerShell's encoding defaults.
    function Invoke-GeminiRequest {
        [CmdletBinding()]
        param(
            [string]$PayloadText,
            [string]$SystemInstruction = $script:PromptSystem,
            [switch]$UseGoogleSearch
        )

        $script:LastApiErrorMessage = $null
        $script:LastApiErrorBody = $null
        $script:LastApiStatusCode = $null

        $headers = @{ 'x-goog-api-key' = $script:ApiKey }
        $requestBody = @{
            model              = $script:Model
            system_instruction = $SystemInstruction
            input              = $PayloadText
            generation_config  = @{ thinking_level = $script:ThinkingLevel }
            store              = $false
        }
        if ($UseGoogleSearch) {
            $requestBody.tools = @(@{ type = 'google_search' })
        }
        $body = $requestBody | ConvertTo-Json -Depth 10
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

        $maxAttempts = $script:MaxRequestAttempts
        $attempt = 0

        while ($attempt -lt $maxAttempts) {
            $attempt++
            try {
                $webResponse = Invoke-WebRequest -Uri $script:InteractionsUrl -Method Post -Headers $headers -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec -UseBasicParsing
                $response = ConvertFrom-Utf8JsonResponse -WebResponse $webResponse
                $text = Get-GeminiResponseText -Response $response
                $searchSummary = Get-GeminiSearchSummary -Response $response
                $tokenUsage = Get-TokenUsageFromResponse -Response $response
                Add-TokenLedgerUsage -TokenUsage $tokenUsage -SearchQueryCount $searchSummary.QueryCount
                return [pscustomobject]@{
                    Text             = $text
                    TokenUsage       = $tokenUsage
                    SearchQueryCount = $searchSummary.QueryCount
                    Sources          = $searchSummary.Sources
                }
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                }

                $connectionFailure = $null
                if ($null -eq $statusCode) {
                    $connectionFailure = Get-ConnectionFailureStatus -ErrorRecord $_
                }

                $waitTime = Get-RetryWaitSecond -StatusCode $statusCode -ConnectionFailure $connectionFailure -RetryNumber $attempt
                if ($null -ne $waitTime) {
                    $failureText = if ($null -ne $connectionFailure) { "Connection failure ($connectionFailure)" } else { "HTTP $statusCode" }
                    if ($attempt -ge $maxAttempts) {
                        Write-ScriptLog -Level WARN -Message "$failureText on attempt $attempt/$maxAttempts. No attempts left."
                        break
                    }

                    Write-ScriptLog -Level WARN -Message "$failureText on attempt $attempt/$maxAttempts. Waiting $waitTime seconds before the next attempt..."
                    Start-Sleep -Seconds $waitTime
                }
                else {
                    Write-ScriptLog -Level WARN -Message "API request failed: HTTP $statusCode"

                    $errorBody = Get-ErrorBodyTextFromException -ErrorRecord $_
                    if (Test-ProhibitedContentError -StatusCode $statusCode -ErrorBody $errorBody) {
                        Write-ScriptLog -Level WARN -Message "Gemini blocked the request for prohibited content (policy filter). The block is not retried."
                    }
                    elseif ($statusCode -eq 400) {
                        Write-ScriptLog -Level WARN -Message "Possible causes: invalid API key (Gemini reports it as HTTP 400), invalid model name, malformed payload. See the API response body below."
                    }
                    elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        Write-ScriptLog -Level WARN -Message "Possible cause: API key is invalid or expired."
                    }

                    $originalError = Get-ErrorMessageFromException -ErrorRecord $_
                    if ([string]::IsNullOrWhiteSpace($originalError)) {
                        $originalError = $_.ToString()
                    }

                    $script:LastApiErrorMessage = ("HTTP {0}: {1}" -f $statusCode, $originalError)
                    $script:LastApiErrorBody = $errorBody
                    $script:LastApiStatusCode = $statusCode

                    if (-not [string]::IsNullOrEmpty($errorBody)) {
                        Write-ScriptLog -Level WARN -Message "API response body: $errorBody"
                    }

                    Write-ScriptLog -Level WARN -Message "Original error: $originalError"
                    return $null
                }
            }
        }

        $script:LastApiErrorMessage = "API request aborted after $maxAttempts attempts."
        Write-ScriptLog -Level ERROR -Message "API request aborted after $maxAttempts attempts."
        return $null
    }

    # Builds the tag audit input from the prepared tag definition section and the given book analysis records as compact JSON array, labeled with the name of the book export file.
    function ConvertTo-BookAuditPayload {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$TagSection,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$BookFileName,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [object[]]$BookRecords
        )

        $bookAnalysisInput = ConvertTo-CompactJson -InputObject $BookRecords -Depth 10
        return @"
$TagSection

===================================
BOOK CONTENT AND CURRENT CALIBRE TAGS (from $BookFileName):
===================================
$bookAnalysisInput
"@
    }

    # Sends one tag audit payload and retries invalid or incomplete responses (e.g. a wrong unique-book count or text that is not JSON) up to $MaxContentAttempts attempts. Returns the parsed ResultObject and the RawText of the last response (both $null when no response arrived), the number of Attempts, and the token Usage counter of all attempts.
    function Invoke-BookAuditRequest {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$PayloadText,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$SourceFile,
            [int]$ExpectedUniqueBookCount = -1
        )

        $usage = Get-TokenUsageCounter
        $rawText = $null
        $resultObject = $null
        $attempt = 0

        while ($attempt -lt $script:MaxContentAttempts) {
            $attempt++
            $requestResult = Invoke-GeminiRequest -PayloadText $PayloadText

            if ($null -eq $requestResult) {
                break
            }

            $rawText = $requestResult.Text
            Add-TokenUsage -Counter $usage -TokenUsage $requestResult.TokenUsage

            $resultObject = Convert-ResponseTextToResultObject -RawText $rawText -SourceFile $SourceFile -ExpectedUniqueBookCount $ExpectedUniqueBookCount

            if ($resultObject.status -eq 'success') {
                break
            }

            $retryReason = if (-not [string]::IsNullOrWhiteSpace($resultObject.validation_error)) { $resultObject.validation_error } else { $resultObject.parse_error }
            if ($attempt -lt $script:MaxContentAttempts) {
                Write-ScriptLog -Level WARN -Message "Invalid/incomplete response for '$SourceFile' (attempt $attempt/$($script:MaxContentAttempts)): $retryReason. Retrying..."
                Start-Sleep -Seconds $script:ContentRetryDelaySeconds
            }
            else {
                Write-ScriptLog -Level WARN -Message "All $($script:MaxContentAttempts) attempt(s) for '$SourceFile' failed validation. Last reason: $retryReason"
            }
        }

        return [pscustomobject]@{
            ResultObject = $resultObject
            RawText      = $rawText
            Attempts     = $attempt
            Usage        = $usage
        }
    }

    # Audits the books of a file one at a time after Gemini blocked the request of the whole file for prohibited content: sends each book analysis record in its own request (with its original BookId, so content profiles still match) and merges the parsed responses into one result object for the file. A book that is blocked again, whose request fails, or whose response stays unparsable gets no record and is named in validation_error, and the status becomes warning. Returns the merged ResultObject ($null when no book got a response), the MissingBooks (Title, Author, Reason) without result, and the token Usage of all requests.
    function Invoke-SingleBookAudit {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [object[]]$BookRecords,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$TagSection,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$BookFileName
        )

        $usage = Get-TokenUsageCounter
        $records = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $contentProfiles = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $profileGaps = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $rawResponses = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $missingBooks = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $missingBookRecords = New-Object -TypeName 'System.Collections.Generic.List[object]'

        foreach ($bookRecord in $BookRecords) {
            $payload = ConvertTo-BookAuditPayload -TagSection $TagSection -BookFileName $BookFileName -BookRecords @($bookRecord)
            $auditResult = Invoke-BookAuditRequest -PayloadText $payload -SourceFile "$BookFileName, book $($bookRecord.BookId)" -ExpectedUniqueBookCount 1
            if ($auditResult.Usage.Available) {
                Add-TokenUsage -Counter $usage -TokenUsage $auditResult.Usage
            }

            $resultObject = $auditResult.ResultObject
            if ($null -ne $auditResult.RawText -and $resultObject.status -ne 'error') {
                foreach ($record in @($resultObject.records)) {
                    $records.Add($record)
                }
                foreach ($contentProfile in @($resultObject.content_profiles)) {
                    $contentProfiles.Add($contentProfile)
                }
                foreach ($profileGap in @($resultObject.profile_gaps)) {
                    $profileGaps.Add($profileGap)
                }
                $rawResponses.Add($auditResult.RawText)
                continue
            }

            $reason = 'invalid response'
            if ($null -eq $auditResult.RawText) {
                $reason = 'request failed'
                if (Test-ProhibitedContentError -StatusCode $script:LastApiStatusCode -ErrorBody $script:LastApiErrorBody) {
                    $reason = 'blocked for prohibited content'
                }
            }

            $missingBooks.Add("'$($bookRecord.Title)' ($reason)")
            $missingBookRecords.Add([pscustomobject][ordered]@{ Title = [string]$bookRecord.Title; Author = [string]$bookRecord.Author; Reason = $reason })
            Write-ScriptLog -Level WARN -Message "No audit result for '$($bookRecord.Title)' in '$BookFileName': $reason."
        }

        if ($rawResponses.Count -eq 0) {
            return [pscustomobject]@{ ResultObject = $null; MissingBooks = $missingBookRecords.ToArray(); Usage = $usage }
        }

        $expectedCount = Get-UniqueBookCount -Items @($BookRecords | ForEach-Object { [pscustomobject]$_ })
        $outputCount = Get-UniqueBookCount -Items $records.ToArray()
        $validationMessages = @()
        if ($missingBooks.Count -gt 0) {
            $validationMessages += "No audit result for $($missingBooks.Count) of $(@($BookRecords).Count) book(s) after the file was blocked for prohibited content and sent book by book: $($missingBooks -join ', ')."
        }
        if ($outputCount -ne $expectedCount) {
            $validationMessages += "Unique book count mismatch: input=$expectedCount, output=$outputCount."
        }

        $mergedResult = [pscustomobject][ordered]@{
            source_file              = $BookFileName
            model                    = $script:Model
            status                   = if ($validationMessages.Count -gt 0) { 'warning' } else { 'success' }
            input_unique_book_count  = $expectedCount
            output_unique_book_count = $outputCount
            unique_book_count_match  = ($outputCount -eq $expectedCount)
            validation_error         = if ($validationMessages.Count -gt 0) { $validationMessages -join ' ' } else { $null }
            records                  = $records.ToArray()
            content_profiles         = $contentProfiles.ToArray()
            profile_gaps             = $profileGaps.ToArray()
            token_usage              = $null
            raw_response             = $rawResponses.ToArray()
            parse_error              = $null
        }

        return [pscustomobject]@{ ResultObject = $mergedResult; MissingBooks = $missingBookRecords.ToArray(); Usage = $usage }
    }

    # Returns the input books of a file that have no record in the audit result, compared by title and author (case and whitespace are ignored, like the unique-book count). Each missing book is returned with Title, Author, and the given Reason.
    function Get-MissingBookRecord {
        [CmdletBinding()]
        param(
            [AllowNull()]
            [object[]]$Books,
            [AllowNull()]
            [object[]]$Records,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$Reason
        )

        $recordKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($record in @($Records | Where-Object { $null -ne $_ })) {
            [void]$recordKeys.Add((Get-BookIdentityKey -Book $record))
        }

        $missingBooks = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($book in @($Books | Where-Object { $null -ne $_ })) {
            $bookKey = Get-BookIdentityKey -Book $book
            if ([string]::IsNullOrWhiteSpace($bookKey) -or $recordKeys.Contains($bookKey)) {
                continue
            }

            [void]$recordKeys.Add($bookKey)
            $missingBooks.Add([pscustomobject][ordered]@{ Title = [string]$book.Title; Author = [string]$book.Author; Reason = $Reason })
        }

        return $missingBooks.ToArray()
    }

    # Send the tag definitions as compact JSON; the indentation of the export file only costs tokens. The result of ConvertFrom-Json is assigned before it is wrapped in @(), because Windows PowerShell 5.1 writes a JSON array as one object, and wrapping the command itself in @() would nest it in a second array (sent as {"value":[...],"Count":n}).
    try {
        $parsedTagDefinitions = ConvertFrom-Json -InputObject $tagContent -ErrorAction Stop
        $tagDefinitions = @($parsedTagDefinitions)
        $tagContent = ConvertTo-CompactJson -InputObject $tagDefinitions -Depth 5
    }
    catch {
        throw "The tag export file '$($tagFile.Name)' is not valid JSON: $($_.Exception.Message)"
    }

    # Fingerprints of the current tag definitions, stored with every new content profile and compared with the stored ones to decide which profile gaps need a refresh.
    $script:TagDefinitionHashes = Get-TagDefinitionHashTable -TagDefinitions $tagDefinitions

    $tagPayloadSection = @"
===================================
TAG DEFINITIONS (from $($tagFile.Name)):
===================================
$tagContent
"@

    Write-ScriptLog "Model:    $Model (thinking level: $ThinkingLevel)"
    Write-Information -MessageData '' -InformationAction Continue

    # Process each book file one by one and save every LLM response separately.
    $counter = 0
    $total = $bookFiles.Count
    $savedCount = 0
    $retriedFileCount = 0
    $retriedFileSuccessCount = 0
    $sessionUsage = Get-TokenUsageCounter
    $totalFullTextBookCount = 0
    $totalProfileBookCount = 0
    $totalSavedProfileCount = 0
    $totalNoContentBookCount = 0
    $totalWebProfileCount = 0
    $totalWebNotFoundCount = 0
    $totalSearchQueryCount = 0
    $totalProfileGapBookCount = 0
    $totalRefreshedTextCount = 0
    $totalRefreshedWebCount = 0
    $allMissingBooks = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $skippedFileCount = 0

    # Count the tokens of every response in the run's token ledger, so requests of an interrupted export file stay counted. A resumed run continues the ledger of the earlier sessions.
    Initialize-TokenLedger -Path $TokenLedgerFile -ResultDirectory $OutputDir -Resume:$Resume

    if ($FullContent) {
        Write-ScriptLog "FullContent: the full book text is sent for every book; stored content profiles are not used."
        Write-Information -MessageData '' -InformationAction Continue
    }

    foreach ($bookFile in $bookFiles) {
        $counter++
        $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
        $outPath = Join-Path -Path $OutputDir -ChildPath $outName

        # A resumed run skips every export file that already has a complete result from the earlier session.
        if ($Resume -and (Test-ResultFileComplete -Path $outPath)) {
            $skippedFileCount++
            Write-ScriptLog "[$counter/$total] Skipped (already processed): $($bookFile.Name)"
            continue
        }

        Write-ScriptLog "[$counter/$total] Processing $($bookFile.Name)..."

        # Read the current book export and build the full prompt payload.
        $bookContent = Get-Content -Path $bookFile.FullName -Raw -Encoding UTF8
        $inputUniqueBookCount = -1
        $parsedInputBooks = $null

        # Parse the input books; an export file that is not valid JSON is not sent (the request would hold no books), but gets a result file with status error, so a resumed run tries it again.
        $inputParseError = $null
        try {
            $parsedInputBooks = ConvertFrom-Json -InputObject $bookContent -ErrorAction Stop
        }
        catch {
            $inputParseError = $_.Exception.Message
        }
        if ($null -eq $inputParseError -and $null -eq $parsedInputBooks) {
            $inputParseError = 'The file holds no book records.'
        }

        if ($null -ne $inputParseError) {
            $inputErrorText = "The book export file '$($bookFile.Name)' is not valid JSON and was not sent: $inputParseError"
            Write-ScriptLog -Level ERROR -Message $inputErrorText
            $inputErrorResult = [pscustomobject][ordered]@{
                source_file              = $bookFile.Name
                model                    = $Model
                status                   = 'error'
                input_unique_book_count  = $null
                output_unique_book_count = 0
                unique_book_count_match  = $null
                validation_error         = $null
                records                  = @()
                missing_books            = @()
                content_profiles         = @()
                profile_gaps             = @()
                profile_refresh          = $null
                token_usage              = ConvertTo-TokenUsageRecord -Counter (Get-TokenUsageCounter)
                raw_response             = $null
                parse_error              = $inputErrorText
            }
            Save-AtomicTextFile -Path $outPath -Content ($inputErrorResult | ConvertTo-Json -Depth 20)
            $savedCount++
            Write-ScriptLog "  -> Saved with input error: $outName"
            continue
        }

        # Count the number of unique books in the input file for output validation.
        if ($parsedInputBooks -is [System.Collections.IEnumerable] -and -not ($parsedInputBooks -is [string])) {
            $inputUniqueBookCount = Get-UniqueBookCount -Items $parsedInputBooks
        }
        else {
            $inputUniqueBookCount = 1
        }

        $fileUsage = Get-TokenUsageCounter
        $fileSearchQueryCount = 0

        # Books without text first get a content profile from a Google Search in a separate request, so the tag audit below can use it like any other profile. The audit request itself never searches.
        $webProfileBooks = @($parsedInputBooks | Where-Object { $null -ne $_ -and (Test-WebProfileRequired -Book $_ -FullContent:$FullContent) })
        if ($webProfileBooks.Count -gt 0) {
            Write-ScriptLog "  -> Web search for $($webProfileBooks.Count) book(s) without text..."
        }

        $fileWebProfileCount = 0
        $fileWebNotFoundCount = 0
        foreach ($webProfileBook in $webProfileBooks) {
            $webProfileResult = Request-WebContentProfile -Book $webProfileBook -UsageCounter $fileUsage
            $fileSearchQueryCount += $webProfileResult.SearchQueryCount
            if ($null -eq $webProfileResult.ContentProfile) {
                Write-ScriptLog -Level WARN -Message "No web content profile for '$($webProfileBook.Title)': the request failed. The book is checked without content."
                continue
            }

            $profileData = [pscustomobject]@{
                ContentProfile = $webProfileResult.ContentProfile
                Source         = if ([string]::IsNullOrWhiteSpace($webProfileResult.ContentProfile)) { 'WebNotFound' } else { 'Web' }
                Sources        = @($webProfileResult.Sources)
                TagHashes      = $null
            }

            try {
                if (-not (Update-BookCacheProfile -CacheDirectory $CacheDir -Book $webProfileBook -ProfileData $profileData)) {
                    Write-ScriptLog -Level WARN -Message "Web content profile of '$($webProfileBook.Title)' was not stored: no matching cache file for this book."
                }
            }
            catch {
                Write-ScriptLog -Level WARN -Message "Web content profile of '$($webProfileBook.Title)' was not stored: $($_.Exception.Message)"
            }

            Add-BookContentProfile -Book $webProfileBook -ProfileData $profileData
            if ($profileData.Source -eq 'Web') {
                $fileWebProfileCount++
                Write-ScriptLog "     Web profile: $($webProfileBook.Title) ($($webProfileResult.SearchQueryCount) search queries, $(@($webProfileResult.Sources).Count) sources)"
            }
            else {
                $fileWebNotFoundCount++
                Write-ScriptLog -Level WARN -Message "No reliable web information found for '$($webProfileBook.Title)' ($($webProfileResult.SearchQueryCount) search queries). The book is checked without content and searched again only after its metadata changes or with -FullContent."
            }
        }

        if ($webProfileBooks.Count -gt 0) {
            $totalWebProfileCount += $fileWebProfileCount
            $totalWebNotFoundCount += $fileWebNotFoundCount
            Write-ScriptLog "  -> Web profiles: $fileWebProfileCount written, $fileWebNotFoundCount not identified, $($webProfileBooks.Count - $fileWebProfileCount - $fileWebNotFoundCount) failed; $fileSearchQueryCount search queries"
        }

        # Send the current tags with either the stored content profile or the extracted content of each book. Books are remembered by BookId: those sent with their full text, so their new content profiles can be stored after the response, and those sent with their profile, so their profile gaps can be refreshed.
        $bookAnalysisRecords = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $fullTextBooksById = @{}
        $profileBooksById = @{}
        $fileProfileBookCount = 0
        $fileNoContentBookCount = 0
        $bookId = 0
        foreach ($inputBook in @($parsedInputBooks | Where-Object { $null -ne $_ })) {
            $bookId++
            $bookAnalysisRecord = ConvertTo-BookAnalysisRecord -Book $inputBook -BookId $bookId -FullContent:$FullContent
            $bookAnalysisRecords.Add($bookAnalysisRecord)
            if ($bookAnalysisRecord.Contains('ContentProfile')) {
                $fileProfileBookCount++
                $profileBooksById[$bookId] = $inputBook
            }
            elseif (-not [string]::IsNullOrEmpty([string]$inputBook.BookContent)) {
                $fullTextBooksById[$bookId] = $inputBook
            }
            else {
                $fileNoContentBookCount++
            }
        }
        $totalProfileBookCount += $fileProfileBookCount
        $totalFullTextBookCount += $fullTextBooksById.Count
        $totalNoContentBookCount += $fileNoContentBookCount
        Write-ScriptLog "  -> Input: $($fullTextBooksById.Count) book(s) with full text, $fileProfileBookCount with content profile, $fileNoContentBookCount without content"

        # The prompt itself is sent as system instruction, so the input holds only the data.
        $bookPayload = ConvertTo-BookAuditPayload -TagSection $tagPayloadSection -BookFileName $bookFile.Name -BookRecords $bookAnalysisRecords.ToArray()

        # Send the book data to the Gemini Interactions API, retrying on incomplete or invalid responses (e.g. a wrong unique-book count or text that is not JSON).
        $auditResult = Invoke-BookAuditRequest -PayloadText $bookPayload -SourceFile $bookFile.Name -ExpectedUniqueBookCount $inputUniqueBookCount
        if ($auditResult.Usage.Available) {
            Add-TokenUsage -Counter $fileUsage -TokenUsage $auditResult.Usage
        }
        $apiResult = $auditResult.RawText
        $resultObject = $auditResult.ResultObject
        $contentAttempt = $auditResult.Attempts
        $singleBookMissingBooks = @()

        # A block for prohibited content rejects the whole file, so the books are sent again one at a time and only the book that triggers the block stays without result.
        if ($null -eq $apiResult -and $bookAnalysisRecords.Count -gt 1 -and (Test-ProhibitedContentError -StatusCode $script:LastApiStatusCode -ErrorBody $script:LastApiErrorBody)) {
            Write-ScriptLog -Level WARN -Message "  -> Request blocked for prohibited content. Sending the $($bookAnalysisRecords.Count) books of '$($bookFile.Name)' one at a time..."
            $singleBookResult = Invoke-SingleBookAudit -BookRecords $bookAnalysisRecords.ToArray() -TagSection $tagPayloadSection -BookFileName $bookFile.Name
            if ($singleBookResult.Usage.Available) {
                Add-TokenUsage -Counter $fileUsage -TokenUsage $singleBookResult.Usage
            }
            $singleBookMissingBooks = @($singleBookResult.MissingBooks)
            if ($null -ne $singleBookResult.ResultObject) {
                $resultObject = $singleBookResult.ResultObject
                $apiResult = $resultObject.raw_response
            }
        }

        if ($contentAttempt -gt 1) {
            $retriedFileCount++
            if ($null -ne $resultObject -and $resultObject.status -eq 'success') {
                $retriedFileSuccessCount++
                Write-ScriptLog "  -> Retry succeeded for '$($bookFile.Name)' on attempt $contentAttempt/$($script:MaxContentAttempts)."
            }
        }

        # Books whose content profile left tag decisions open (profile gaps) are audited again in the same run, because a book is exported again only after it changes: a text book with its full excerpt, a book without text with a new web profile from a search that targets the open tag definitions. Only gap tags that are new or changed since the profile was written lead to a refresh. Gaps in the refresh response are ignored, so there is one refresh round per file.
        $profileRefreshSummary = $null
        if ($null -ne $apiResult -and $null -ne $resultObject -and $resultObject.status -ne 'error' -and @($resultObject.profile_gaps).Count -gt 0) {
            $refreshCandidates = @(Get-ProfileRefreshCandidate -ProfileGaps @($resultObject.profile_gaps) -ProfileBooksById $profileBooksById -TagHashes $script:TagDefinitionHashes)
            $fileProfileGapBookCount = @($resultObject.profile_gaps | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['BookId'] } | ForEach-Object { [string]$_.BookId } | Select-Object -Unique).Count
            $totalProfileGapBookCount += $fileProfileGapBookCount
            Write-ScriptLog "  -> Profile gaps: $fileProfileGapBookCount book(s), $($refreshCandidates.Count) with new or changed tag definitions to refresh"

            $refreshRecords = New-Object -TypeName 'System.Collections.Generic.List[object]'
            $refreshTextBooksById = @{}
            $fileRenewedWebCount = 0
            foreach ($candidate in $refreshCandidates) {
                $openTagText = $candidate.Tags -join ', '
                if ($candidate.Kind -eq 'Text') {
                    $refreshRecords.Add((ConvertTo-BookAnalysisRecord -Book $candidate.Book -BookId $candidate.BookId -FullContent))
                    $refreshTextBooksById[$candidate.BookId] = $candidate.Book
                    Write-ScriptLog "     Refresh with full text: $($candidate.Book.Title) (open tags: $openTagText)"
                    continue
                }

                $focusTagDefinitions = ConvertTo-CompactJson -InputObject @(Select-TagDefinition -TagDefinitions $tagDefinitions -TagNames $candidate.Tags) -Depth 5
                $webRefreshResult = Request-WebContentProfile -Book $candidate.Book -FocusTagDefinitions $focusTagDefinitions -UsageCounter $fileUsage
                $fileSearchQueryCount += $webRefreshResult.SearchQueryCount
                if ($null -eq $webRefreshResult.ContentProfile) {
                    Write-ScriptLog -Level WARN -Message "Targeted web search for '$($candidate.Book.Title)' failed. The first audit result is kept."
                    continue
                }

                # The focus tags are recorded even when the search found nothing new, so the same definitions do not trigger another search; the existing profile is then kept.
                $storedTagHashes = @{}
                if ($null -ne $candidate.Book.PSObject.Properties['ContentProfileTagHashes']) {
                    $storedTagHashes = ConvertTo-TagHashTable -InputObject $candidate.Book.ContentProfileTagHashes
                }
                $mergedTagHashes = Merge-TagHashTable -StoredTagHashes $storedTagHashes -CurrentTagHashes $script:TagDefinitionHashes -TagNames $candidate.Tags
                $isRenewed = -not [string]::IsNullOrWhiteSpace($webRefreshResult.ContentProfile)
                if ($isRenewed) {
                    $refreshProfileData = [pscustomobject]@{ ContentProfile = $webRefreshResult.ContentProfile; Source = 'Web'; Sources = @($webRefreshResult.Sources); TagHashes = $mergedTagHashes }
                }
                else {
                    $refreshProfileData = [pscustomobject]@{ ContentProfile = [string]$candidate.Book.ContentProfile; Source = 'Web'; Sources = $candidate.Book.ContentProfileSources; TagHashes = $mergedTagHashes }
                }

                try {
                    if (-not (Update-BookCacheProfile -CacheDirectory $CacheDir -Book $candidate.Book -ProfileData $refreshProfileData)) {
                        Write-ScriptLog -Level WARN -Message "Refreshed web content profile of '$($candidate.Book.Title)' was not stored: no matching cache file for this book."
                    }
                }
                catch {
                    Write-ScriptLog -Level WARN -Message "Refreshed web content profile of '$($candidate.Book.Title)' was not stored: $($_.Exception.Message)"
                }

                Add-BookContentProfile -Book $candidate.Book -ProfileData $refreshProfileData
                if (-not $isRenewed) {
                    Write-ScriptLog -Level WARN -Message "Targeted web search found no reliable information for '$($candidate.Book.Title)' (open tags: $openTagText). The existing web profile and the first audit result are kept."
                    continue
                }

                $fileRenewedWebCount++
                $refreshRecords.Add((ConvertTo-BookAnalysisRecord -Book $candidate.Book -BookId $candidate.BookId))
                Write-ScriptLog "     Refresh with targeted web profile: $($candidate.Book.Title) (open tags: $openTagText; $($webRefreshResult.SearchQueryCount) search queries)"
            }

            $replacedBookCount = 0
            $savedRefreshProfileCount = 0
            if ($refreshRecords.Count -gt 0) {
                $refreshPayload = ConvertTo-BookAuditPayload -TagSection $tagPayloadSection -BookFileName $bookFile.Name -BookRecords $refreshRecords.ToArray()
                $refreshExpectedCount = Get-UniqueBookCount -Items @($refreshRecords | ForEach-Object { [pscustomobject]$_ })
                $refreshAudit = Invoke-BookAuditRequest -PayloadText $refreshPayload -SourceFile "$($bookFile.Name) (profile refresh)" -ExpectedUniqueBookCount $refreshExpectedCount
                if ($refreshAudit.Usage.Available) {
                    Add-TokenUsage -Counter $fileUsage -TokenUsage $refreshAudit.Usage
                }

                if ($null -ne $refreshAudit.RawText -and $null -ne $refreshAudit.ResultObject -and $refreshAudit.ResultObject.status -ne 'error') {
                    $replacedBookCount = Merge-RefreshedAuditRecord -ResultObject $resultObject -RefreshResultObject $refreshAudit.ResultObject -BookRecords $refreshRecords.ToArray()
                    if ($refreshTextBooksById.Count -gt 0) {
                        $savedRefreshProfileCount = Save-ContentProfile -ContentProfiles @($refreshAudit.ResultObject.content_profiles) -FullTextBooksById $refreshTextBooksById -CacheDirectory $CacheDir
                    }
                    Write-ScriptLog "  -> Profile refresh: results of $replacedBookCount of $($refreshRecords.Count) book(s) replaced, $savedRefreshProfileCount content profile(s) stored"
                }
                else {
                    Write-ScriptLog -Level WARN -Message "Profile refresh for '$($bookFile.Name)' failed. The first audit results are kept."
                }
            }

            $totalRefreshedTextCount += $savedRefreshProfileCount
            $totalRefreshedWebCount += $fileRenewedWebCount
            $profileRefreshSummary = [ordered]@{
                gap_book_count       = $fileProfileGapBookCount
                refreshed_books      = @($refreshRecords | ForEach-Object { [string]$_.Title })
                replaced_book_count  = $replacedBookCount
                text_profiles_stored = $savedRefreshProfileCount
                web_profiles_renewed = $fileRenewedWebCount
            }
        }

        if ($null -ne $resultObject) {
            $resultObject | Add-Member -MemberType NoteProperty -Name 'profile_refresh' -Value $profileRefreshSummary -Force
        }

        $totalSearchQueryCount += $fileSearchQueryCount
        if ($fileUsage.Available) {
            Add-TokenUsage -Counter $sessionUsage -TokenUsage $fileUsage
            Write-ScriptLog "  -> Token usage for $($bookFile.Name): $(Format-TokenUsage -Counter $fileUsage)"
        }
        else {
            Write-ScriptLog "  -> Token usage for $($bookFile.Name): unavailable"
        }

        $tokenUsage = ConvertTo-TokenUsageRecord -Counter $fileUsage -SearchQueryCount $fileSearchQueryCount

        # Store the content profiles of the books sent with their full text, so later runs can send the profile instead.
        if ($null -ne $apiResult -and $resultObject.status -ne 'error' -and $fullTextBooksById.Count -gt 0) {
            $fileSavedProfileCount = Save-ContentProfile -ContentProfiles @($resultObject.content_profiles) -FullTextBooksById $fullTextBooksById -CacheDirectory $CacheDir
            $totalSavedProfileCount += $fileSavedProfileCount
            Write-ScriptLog "  -> Content profiles stored: $fileSavedProfileCount of $($fullTextBooksById.Count)"
        }

        # Name every input book without a record, so it is listed in the run summary and in the ODS instead of disappearing. Books the book-by-book fallback already reported keep its reason and are not logged twice.
        $missingBookReason = 'no result in the LLM response'
        $fileRecords = @()
        if ($null -eq $apiResult) {
            $missingBookReason = 'API request failed'
            if (Test-ProhibitedContentError -StatusCode $script:LastApiStatusCode -ErrorBody $script:LastApiErrorBody) {
                $missingBookReason = 'blocked for prohibited content'
            }
        }
        elseif ($resultObject.status -eq 'error') {
            $missingBookReason = 'LLM response could not be parsed'
        }
        else {
            $fileRecords = @($resultObject.records)
        }

        $knownMissingReasons = @{}
        foreach ($knownMissingBook in $singleBookMissingBooks) {
            $knownMissingReasons[(Get-BookIdentityKey -Book $knownMissingBook)] = $knownMissingBook.Reason
        }

        $fileMissingBooks = @(Get-MissingBookRecord -Books @($parsedInputBooks) -Records $fileRecords -Reason $missingBookReason)
        foreach ($missingBook in $fileMissingBooks) {
            $missingBookKey = Get-BookIdentityKey -Book $missingBook
            if ($knownMissingReasons.ContainsKey($missingBookKey)) {
                $missingBook.Reason = $knownMissingReasons[$missingBookKey]
            }
            else {
                Write-ScriptLog -Level WARN -Message "No audit result for '$($missingBook.Title)' in '$($bookFile.Name)': $($missingBook.Reason)."
            }
            $allMissingBooks.Add([pscustomobject][ordered]@{ Title = $missingBook.Title; Author = $missingBook.Author; Reason = $missingBook.Reason; SourceFile = $bookFile.Name })
        }

        if ($null -ne $apiResult) {
            $resultObject | Add-Member -MemberType NoteProperty -Name 'missing_books' -Value $fileMissingBooks -Force
            $resultObject.token_usage = $tokenUsage
            $savedCount++

            # Store a valid JSON wrapper so parse errors and raw API output are preserved.
            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            Save-AtomicTextFile -Path $outPath -Content $jsonOutput

            $inputCountText = if ($null -ne $resultObject.input_unique_book_count) { $resultObject.input_unique_book_count } else { 'n/a' }
            Write-ScriptLog "  -> Validation check: input=$inputCountText, output=$($resultObject.output_unique_book_count)"

            if ($resultObject.status -eq 'success') {
                Write-ScriptLog "  -> Saved as: $outName"
            }
            elseif ($resultObject.status -eq 'warning') {
                $validationWarningText = "Validation warning in '$($bookFile.Name)': $($resultObject.validation_error)"
                Write-ScriptLog -Level WARN -Message $validationWarningText
                Write-ScriptLog "  -> Saved with validation warning: $outName"
            }
            else {
                $validationErrorText = "Validation error in '$($bookFile.Name)': $($resultObject.parse_error)"
                Write-ScriptLog -Level ERROR -Message $validationErrorText
                Write-ScriptLog "  -> Saved with parse error: $outName"
            }
        }
        else {
            $savedCount++

            $apiDetail = $script:LastApiErrorMessage
            if ([string]::IsNullOrWhiteSpace($apiDetail)) {
                $apiDetail = 'No response from API.'
            }

            if (-not [string]::IsNullOrWhiteSpace($script:LastApiErrorBody)) {
                $apiDetail = "$apiDetail | API response: $($script:LastApiErrorBody)"
            }

            $resultObject = [pscustomobject][ordered]@{
                source_file              = $bookFile.Name
                model                    = $Model
                status                   = 'error'
                input_unique_book_count  = if ($inputUniqueBookCount -ge 0) { $inputUniqueBookCount } else { $null }
                output_unique_book_count = 0
                unique_book_count_match  = $null
                validation_error         = $null
                records                  = @()
                missing_books            = $fileMissingBooks
                content_profiles         = @()
                profile_gaps             = @()
                profile_refresh          = $null
                token_usage              = $tokenUsage
                raw_response             = if (-not [string]::IsNullOrWhiteSpace($script:LastApiErrorBody)) { $script:LastApiErrorBody } else { $apiDetail }
                parse_error              = $apiDetail
            }

            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            Save-AtomicTextFile -Path $outPath -Content $jsonOutput

            Write-ScriptLog "  -> Saved with API error: $outName"
            $validationErrorText = "Validation error in '$($bookFile.Name)': $apiDetail"
            Write-ScriptLog -Level ERROR -Message $validationErrorText
        }

        # Pause between two requests to stay below the rate limit; after the last file there is nothing left to send.
        if ($counter -lt $total) {
            Start-Sleep -Seconds $script:InterFileDelaySeconds
        }
    }

    # Final summary for the completed run.
    $scriptEndTime = Get-Date
    $scriptDuration = $scriptEndTime - $scriptStartTime
    Write-Information -MessageData '' -InformationAction Continue
    Write-ScriptLog "--- Processing Complete ---"
    Write-ScriptLog "Start: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))  End: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))  Duration: $(Format-Duration -Duration $scriptDuration)"
    Write-ScriptLog "$total files processed, $retriedFileCount retried, $retriedFileSuccessCount successful after retries."
    if ($Resume) {
        Write-ScriptLog "Resumed: $skippedFileCount file(s) skipped as already processed. The counters below cover this session only; the pipeline summary totals the whole run from the token ledger (02-LLM-Result\LLM-TokenUsage.json)."
    }
    Write-ScriptLog "Books sent: $totalFullTextBookCount with full text, $totalProfileBookCount with content profile, $totalNoContentBookCount without content; $totalSavedProfileCount content profile(s) stored."
    Write-ScriptLog "Web search: $totalWebProfileCount web profile(s) written, $totalWebNotFoundCount book(s) not identified, $totalSearchQueryCount search queries (billed per query)."
    Write-ScriptLog "Profile gaps: $totalProfileGapBookCount book(s) with open tag decisions; refreshed $totalRefreshedTextCount with the full text and $totalRefreshedWebCount with a targeted web search."
    Write-ScriptLog "Total token usage: $(Format-TokenUsage -Counter $sessionUsage)"
    if ($allMissingBooks.Count -eq 0) {
        Write-ScriptLog "Books without audit result: 0"
    }
    else {
        Write-ScriptLog -Level WARN -Message "Books without audit result: $($allMissingBooks.Count) (listed in the ODS as NOT_AUDITED; check their tags manually)"
        foreach ($missingBook in $allMissingBooks) {
            Write-ScriptLog -Level WARN -Message "  - $($missingBook.Title) ($($missingBook.Author)): $($missingBook.Reason) [$($missingBook.SourceFile)]"
        }
    }
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

    Write-ScriptLog -Level ERROR -Message $errorMessage -ErrorRecord $_
    throw
}
finally {
    if ($ownsLogSession) {
        Stop-Log
    }
}