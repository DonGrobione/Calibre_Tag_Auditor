<#
.SYNOPSIS
    Validate Calibre export data with the Google Gemini API.

.DESCRIPTION
    Reads the latest Calibre book export and tag-definition JSON files, sends each book's extracted content (or its stored content profile, see below) and existing tags together with the tag definitions to the Gemini Interactions API (prompt as system instruction), and writes the LLM responses to the 02-LLM-Result folder as individual JSON files.
    It validates unique-book counts per file, repairs mojibake in LLM responses, and stores the validation outcome in the output metadata.
    Before contacting the API, the script verifies that the export folder exists and that at least one book export and one tag export JSON file are present; otherwise it stops with an error.
    If a response is invalid or incomplete (e.g. a wrong unique-book count or a parse error), the request for that file is retried up to $MaxContentRetries times before the result is saved.
    A per-file validation check, per-file token usage, and a final run summary (start/end time, duration, retry statistics, and total token usage) are printed after processing.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 2.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

    Content profiles: for every book sent with its full text, the LLM also returns a short content profile (a factual summary of the excerpt). The script stores it in the book's cache file 01-Cache/<uuid>.json, but only when that file still holds the same book text (same ContentHash). On later runs, 01-Export-CalibreBooks.ps1 exports the profile with the book, and this script sends the profile instead of the full text while the profile has the current $ContentProfileVersion. This cuts the input tokens of a re-audited book from about 28,000 to a few hundred. Increase $ContentProfileVersion when the profile instructions in the prompt change, so all profiles are rebuilt.
    Web content profiles: a book without text (ContentStatus NoText, e.g. a comic, manga, or graphic novel made of images) has no excerpt to write a profile from. Before the tag audit of each export file, the script sends each such book's metadata (title, author, series, identifiers, publisher, year, Calibre description) with the tag definitions in a separate request with the google_search tool and the prompt 02-CalibreWebProfile-Prompt.txt. The LLM identifies the exact work and writes a profile only from facts found in the search results and the description. The profile is stored in the cache file with ContentProfileSource Web and the cited web sources; when the work cannot be identified reliably, a WebNotFound marker is stored instead, so the book is not searched again until its identity metadata changes. The tag audit request itself never uses search. Google bills grounded requests per executed search query, so the number of search queries is logged per file and in the run summary.
    The book data and tag definitions are sent as compact JSON without indentation.
    Tag definition baseline: when the book export covered the whole library (01-Export\01-Export-Scope.json with FullLibrary true) and no file ended with an error, the used tag definitions are saved to 01-Cache\TagDefinitions.json. 01-Export-CalibreTags.ps1 compares later exports with this baseline and warns about changed definitions.

.PARAMETER FullContent
    Sends the full book text for every book, even when a content profile exists, and stores new profiles from the responses. Books without text get a new web content profile from a new Google Search (this costs search queries). Use it after tag definitions with new concepts were added, so the decisions and profiles are based on the full text again.

.EXAMPLE
    .\02-Process-CalibreDataWithLLM.ps1
    Validates the latest book export and uses stored content profiles where available.

.EXAMPLE
    .\02-Process-CalibreDataWithLLM.ps1 -FullContent
    Validates the latest book export with the full book text of every book.

.NOTES
    Version: 6.2
    Requires a JSON file Secrets/Gemini_API.json.key with the API key in the property APIKey and the prompt files 02-CalibreDataLLM-Prompt.txt and 02-CalibreWebProfile-Prompt.txt in the script folder.
    Each output file is written as a valid JSON object with metadata, records, content profiles, token usage, the raw response text, parse errors, and validation details for unique-book counts.
    All retry counts and wait intervals (429/503/504 API retries, content-validation retries, inter-file delay) are configured via $script: variables near the top of the script.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$FullContent
)

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

$CalibreTagDefinitionsModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.TagDefinitions.psd1"
if (-not (Test-Path -LiteralPath $CalibreTagDefinitionsModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.TagDefinitions.psd1'"
}

Import-Module -Name $CalibreTagDefinitionsModulePath -Force

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
    $ApiKeyFile = Join-Path -Path $ScriptDir -ChildPath "Secrets\Gemini_API.json.key"
    $PromptFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreDataLLM-Prompt.txt"
    $WebProfilePromptFile = Join-Path -Path $ScriptDir -ChildPath "02-CalibreWebProfile-Prompt.txt"
    $CacheDir = Join-Path -Path $ScriptDir -ChildPath "01-Cache"
    $ScopePath = Join-Path -Path $ExportDir -ChildPath "01-Export-Scope.json"
    $TagDefinitionBaselinePath = Join-Path -Path $CacheDir -ChildPath "TagDefinitions.json"

    # Increase ContentProfileVersion whenever the profile instructions in the prompt change, so all stored content profiles are rebuilt from the full text.
    $script:ContentProfileVersion = 1

    $Model = "gemini-3.8-flash"
    $ThinkingLevel = "medium"                             # Gemini thinking level: low, medium, or high.
    $InteractionsUrl = "https://generativelanguage.googleapis.com/v1beta/interactions"
    $ApiTimeoutSec = 300

    # Retry/backoff configuration for all retry activities in this script.
    $script:MaxRequestRetries = 3                       # Max retries per API request on 429/503/504 errors.
    $script:RateLimitRetryBaseSeconds = 30               # 429: base seconds for exponential backoff (wait = base * 2^attempt).
    $script:ServiceUnavailableRetryBaseSeconds = 5        # 503: base seconds for exponential backoff.
    $script:ServiceUnavailableRetryMaxSeconds = 60        # 503: cap (seconds) for exponential backoff.
    $script:GatewayTimeoutRetryIntervalSeconds = 300      # 504: fixed wait interval (seconds) between retries.
    $script:MaxContentRetries = 3                         # Max retries per file for invalid/incomplete LLM responses.
    $script:ContentRetryDelaySeconds = 15                 # Wait (seconds) between content-validation retries.
    $script:InterFileDelaySeconds = 15                    # Wait (seconds) between processing each book file.

    $script:LastApiErrorMessage = $null
    $script:LastApiErrorBody = $null

    # Ensure the output folder exists before writing results and remove stale JSON files from a previous run.
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }
    else {
        $jsonFiles = Get-ChildItem -Path $OutputDir -Filter "*.json" -File
        if ($jsonFiles.Count -gt 0) {
            Write-ScriptLog "Cleaning $($jsonFiles.Count) JSON file(s) from 02-LLM-Result..."
            $jsonFiles | Remove-Item -Force
            Write-ScriptLog "Done."
            Write-Information -MessageData '' -InformationAction Continue
        }
    }

    if (-not (Test-Path -Path $ApiKeyFile -PathType Leaf) -or -not (Test-Path -Path $PromptFile -PathType Leaf) -or -not (Test-Path -Path $WebProfilePromptFile -PathType Leaf)) {
        throw "API key or prompt file is missing in the script folder (Secrets\Gemini_API.json.key, 02-CalibreDataLLM-Prompt.txt, 02-CalibreWebProfile-Prompt.txt)."
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

    # Load the API key and the prompt system from external files.
    $ApiKey = Get-GeminiApiKey -Path $ApiKeyFile
    $PromptSystem = (Get-Content -Path $PromptFile -Raw -Encoding UTF8).Trim()
    $WebProfilePromptSystem = (Get-Content -Path $WebProfilePromptFile -Raw -Encoding UTF8).Trim()

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

    # Repairs mojibake, i.e. UTF-8 text that was decoded as Windows-1252 or ISO-8859-1 (such as "Ã¼" instead of "ü" or "â€™" instead of "’"), in up to four rounds for text that was garbled several times.
    # Only the garbled character sequences are replaced, each by exactly one valid UTF-8 character, so correct text around them stays unchanged; a sequence that does not decode cleanly is kept as it is.
    # Detected are the UTF-8 lead bytes 0xC2-0xC5 (Latin-1 letters such as umlauts and accents, Œ, Š, Ž) and 0xE2 (punctuation such as – — ’ “ ” … € ™), which cover Western text; the check is case-sensitive, so correct letters such as "ã" or "â" do not start a repair.
    function Repair-MojibakeText {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return $Text
        }

        # Map the characters that Windows-1252 shows for the bytes 0x80-0x9F back to their byte values.
        $windows1252 = [System.Text.Encoding]::GetEncoding(1252)
        $byteByCharacter = @{}
        foreach ($byteValue in 0x80..0x9F) {
            $character = $windows1252.GetString([byte[]]@($byteValue))
            if ($character.Length -eq 1 -and [int][char]$character -gt 0xFF) {
                $byteByCharacter[[int][char]$character] = [byte]$byteValue
            }
        }

        $continuation = '[\u0080-\u00BF\u0152\u0153\u0160\u0161\u0178\u017D\u017E\u0192\u02C6\u02DC\u2013\u2014\u2018-\u201A\u201C-\u201E\u2020-\u2022\u2026\u2030\u2039\u203A\u20AC\u2122]'
        $pattern = '[\u00C2-\u00C5]{0}|\u00E2{0}{0}' -f $continuation
        $strictUtf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true

        $repairSequence = {
            param($match)

            $bytes = New-Object -TypeName 'byte[]' -ArgumentList $match.Value.Length
            for ($index = 0; $index -lt $match.Value.Length; $index++) {
                $code = [int]$match.Value[$index]
                if ($code -le 0xFF) {
                    $bytes[$index] = [byte]$code
                }
                elseif ($byteByCharacter.ContainsKey($code)) {
                    $bytes[$index] = $byteByCharacter[$code]
                }
                else {
                    return $match.Value
                }
            }

            try {
                $decoded = $strictUtf8.GetString($bytes)
            }
            catch {
                return $match.Value
            }

            if ($decoded.Length -ne 1) {
                return $match.Value
            }

            return $decoded
        }

        $current = $Text
        for ($round = 0; $round -lt 4; $round++) {
            if ($current -cnotmatch $pattern) {
                break
            }

            $repaired = [System.Text.RegularExpressions.Regex]::Replace($current, $pattern, $repairSequence)
            if ($repaired -ceq $current) {
                break
            }

            $current = $repaired
        }

        return $current
    }

    # Extracts a human-readable error message string from an ErrorRecord object.
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

    # Reads the HTTP error response body stream from an ErrorRecord object.
    function Get-ErrorBodyTextFromException {
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

    # Extracts prompt, completion (output plus thinking), and total token usage from a Gemini interaction response.
    function Get-TokenUsageFromResponse {
        param($Response)

        if ($null -eq $Response -or $null -eq $Response.PSObject.Properties['usage'] -or $null -eq $Response.usage) {
            return $null
        }

        $usage = $Response.usage
        $promptTokens = $null
        $completionTokens = $null
        $totalTokens = $null

        if ($null -ne $usage.PSObject.Properties['total_input_tokens']) {
            $promptTokens = [int64]$usage.total_input_tokens
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

        if ($null -ne $usage.PSObject.Properties['total_tokens']) {
            $totalTokens = [int64]$usage.total_tokens
        }
        elseif ($null -ne $promptTokens -and $null -ne $completionTokens) {
            $totalTokens = $promptTokens + $completionTokens
        }

        return [pscustomobject]@{
            PromptTokens     = $promptTokens
            CompletionTokens = $completionTokens
            TotalTokens      = $totalTokens
        }
    }

    # Joins the text items of all model output steps of a Gemini interaction response and logs the raw response when it contains no text.
    function Get-GeminiResponseText {
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
        return $Response | ConvertTo-Json -Depth 3
    }

    # Returns the number of Google Search queries (google_search_call steps, arguments.queries) and the unique cited web sources (url_citation annotations of the model output, as Title and Url) of a Gemini interaction response.
    function Get-GeminiSearchSummary {
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

    # Extracts the first valid JSON array or object substring from a raw text payload.
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

            if ($character -eq '\') {
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

    # Generates a normalized identity key string for a book object using its title, author, and series metadata.
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

    # Counts the number of unique book records in an array by computing normalized identity keys.
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

    # Parses raw LLM text response into a structured result object with book records and validation metadata.
    function Convert-ResponseTextToResultObject {
        param(
            [string]$RawText,
            [string]$SourceFile,
            [string]$Model,
            [int]$ExpectedUniqueBookCount = -1
        )

        $result = [ordered]@{
            source_file             = $SourceFile
            model                   = $Model
            status                  = 'success'
            input_unique_book_count = $null
            output_unique_book_count = 0
            unique_book_count_match = $null
            validation_error        = $null
            records                 = @()
            content_profiles        = @()
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

        # The prompt asks for an object with Results and ContentProfiles; a plain array of result objects is still accepted.
        if ($parsed -isnot [System.Array] -and $null -ne $parsed.PSObject.Properties['Results']) {
            $result.records = @($parsed.Results | Where-Object { $null -ne $_ })
            if ($null -ne $parsed.PSObject.Properties['ContentProfiles']) {
                $result.content_profiles = @($parsed.ContentProfiles | Where-Object { $null -ne $_ })
            }
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

    # Decodes the raw bytes of a web response as UTF-8 and parses them as JSON, independent of the charset in the server's Content-Type header (Windows PowerShell 5.1 falls back to ISO-8859-1 without one).
    function ConvertFrom-Utf8JsonResponse {
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

    # Returns $true when the run counts as a full-library audit: the scope file of the book export says FullLibrary and no export file ended with an error. A missing or unreadable scope file counts as not full.
    function Test-TagDefinitionBaselineUpdate {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$ScopePath,
            [Parameter(Mandatory = $true)]
            [ValidateRange(0, [int]::MaxValue)]
            [int]$ErrorFileCount
        )

        if ($ErrorFileCount -gt 0 -or -not (Test-Path -LiteralPath $ScopePath -PathType Leaf)) {
            return $false
        }

        try {
            $scope = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($ScopePath, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
        }
        catch {
            return $false
        }

        return ($null -ne $scope -and $null -ne $scope.PSObject.Properties['FullLibrary'] -and $scope.FullLibrary -eq $true)
    }

    # Converts an object to JSON without indentation and turns the \u00XX escapes that Windows PowerShell 5.1 writes for &, ', <, and > back into the characters, because every escape costs several tokens. An escaped backslash before such a sequence is kept, so literal backslash-u text in the content stays unchanged.
    function ConvertTo-CompactJson {
        param(
            [Parameter(Mandatory = $true)]
            [AllowNull()]
            [object]$InputObject,
            [ValidateRange(1, 100)]
            [int]$Depth = 10
        )

        $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
        return [System.Text.RegularExpressions.Regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u00(26|27|3[cCeE])', {
            param($match)
            return $match.Groups[1].Value + [char][Convert]::ToInt32($match.Groups[2].Value, 16)
        })
    }

    # Returns $true when the book export record holds a non-empty content profile of the current $script:ContentProfileVersion.
    function Test-ContentProfile {
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
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book
        )

        return ($null -ne $Book.PSObject.Properties['ContentStatus'] -and [string]$Book.ContentStatus -eq 'NoText')
    }

    # Returns $true when a book without text needs a new web content profile: it has a UUID and ContentHash to store the profile under, and FullContent is set or it has neither a current profile nor a current WebNotFound marker.
    function Test-WebProfileRequired {
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

    # Adds the prompt, completion, and total tokens of one request to a usage counter object (Available, PromptTokens, CompletionTokens, TotalTokens); a $null token usage leaves the counter unchanged.
    function Add-TokenUsage {
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
        if ($null -ne $TokenUsage.PromptTokens) {
            $Counter.PromptTokens += [int64]$TokenUsage.PromptTokens
        }
        if ($null -ne $TokenUsage.CompletionTokens) {
            $Counter.CompletionTokens += [int64]$TokenUsage.CompletionTokens
        }
        if ($null -ne $TokenUsage.TotalTokens) {
            $Counter.TotalTokens += [int64]$TokenUsage.TotalTokens
        }
    }

    # Requests a web content profile for one book without text: sends the tag definitions and the book metadata with the web profile prompt and the google_search tool, retries invalid responses up to $MaxContentRetries times, and adds the token usage to the counter. Returns ContentProfile ($null when the request failed, empty when the work was not identified), the cited Sources, and the SearchQueryCount of all attempts.
    function Request-WebContentProfile {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]$TagDefinitions,
            [Parameter(Mandatory = $true)]
            [object]$UsageCounter
        )

        $bookInput = ConvertTo-CompactJson -InputObject (ConvertTo-WebProfileRecord -Book $Book) -Depth 5
        $payload = @"
===================================
TAG DEFINITIONS:
===================================
$TagDefinitions

===================================
BOOK METADATA:
===================================
$bookInput
"@

        $searchQueryCount = 0
        for ($attempt = 1; $attempt -le $script:MaxContentRetries; $attempt++) {
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

            if ($attempt -lt $script:MaxContentRetries) {
                Write-ScriptLog -Level WARN -Message "Invalid web profile response for '$($Book.Title)' (attempt $attempt/$($script:MaxContentRetries)). Retrying..."
                Start-Sleep -Seconds $script:ContentRetryDelaySeconds
            }
        }

        return [pscustomobject]@{
            ContentProfile   = $null
            Sources          = @()
            SearchQueryCount = $searchQueryCount
        }
    }

    # Adds the content profile fields (ContentProfile, current ContentProfileVersion, ContentProfileSource, ContentProfileSources) to the export record in memory, so the tag audit of this run uses the new profile.
    function Add-BookContentProfile {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Book,
            [Parameter(Mandatory = $true)]
            [object]$ProfileData
        )

        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfile' -Value ([string]$ProfileData.ContentProfile) -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileVersion' -Value $script:ContentProfileVersion -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileSource' -Value ([string]$ProfileData.Source) -Force
        $Book | Add-Member -MemberType NoteProperty -Name 'ContentProfileSources' -Value $ProfileData.Sources -Force
    }

    # Builds the LLM input record of one book with a request-local BookId: the identity fields, the current tags, and either the stored content profile (when it is valid and FullContent is not set, or always for a book without text) or the extracted BookContent. A web profile is marked with ContentProfileSource Web.
    function ConvertTo-BookAnalysisRecord {
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

    # Stores a content profile (ProfileData with ContentProfile, Source Text/Web/WebNotFound, and optional Sources) in the book's cache file 01-Cache/<uuid>.json and returns $true. Returns $false without writing when the profile is empty without being a WebNotFound marker, the UUID is invalid, the cache file is missing or unreadable, or the file holds a different ContentHash, so a profile never belongs to another text or other metadata.
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

        $uuid = $null
        $contentHash = $null
        if ($null -ne $Book.PSObject.Properties['Uuid']) { $uuid = [string]$Book.Uuid }
        if ($null -ne $Book.PSObject.Properties['ContentHash']) { $contentHash = [string]$Book.ContentHash }

        # \z instead of $, because $ also matches before a trailing line break.
        if ($uuid -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z' -or [string]::IsNullOrEmpty($contentHash)) {
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

        if (-not $PSCmdlet.ShouldProcess($path, 'Store content profile')) {
            return $false
        }

        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $cached -Depth 10), $utf8NoBom)
        return $true
    }

    # Stores the content profiles of an LLM response in the cache files and returns the number of stored profiles. Only profiles whose BookId belongs to a book of this request that was sent with its full text are stored; unknown IDs, books sent as a profile, and empty profiles are skipped.
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
                $profileData = [pscustomobject]@{ ContentProfile = $profileText; Source = 'Text'; Sources = $null }
                if (Update-BookCacheProfile -CacheDirectory $CacheDirectory -Book $book -ProfileData $profileData) {
                    $savedCount++
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

    # Sends the payload with a system instruction (by default the tag audit prompt) to the Gemini Interactions API with automatic retry on rate limits and HTTP server errors, and returns the response text, token usage, search query count, and cited sources. -UseGoogleSearch enables the google_search tool. The request body is sent as UTF-8 bytes and the response is decoded as UTF-8, so umlauts and typographic characters do not depend on PowerShell's encoding defaults.
    function Invoke-GeminiRequest {
        param(
            [string]$PayloadText,
            [string]$SystemInstruction = $script:PromptSystem,
            [switch]$UseGoogleSearch
        )

        $script:LastApiErrorMessage = $null
        $script:LastApiErrorBody = $null

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

        $maxRetries = $script:MaxRequestRetries
        $retryCount = 0

        while ($retryCount -lt $maxRetries) {
            try {
                $webResponse = Invoke-WebRequest -Uri $script:InteractionsUrl -Method Post -Headers $headers -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec $script:ApiTimeoutSec -UseBasicParsing
                $response = ConvertFrom-Utf8JsonResponse -WebResponse $webResponse
                $text = Get-GeminiResponseText -Response $response
                $searchSummary = Get-GeminiSearchSummary -Response $response
                return [pscustomobject]@{
                    Text             = $text
                    TokenUsage       = Get-TokenUsageFromResponse -Response $response
                    SearchQueryCount = $searchSummary.QueryCount
                    Sources          = $searchSummary.Sources
                }
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                }

                if ($statusCode -eq 429) {
                    $retryCount++
                    $waitTime = [math]::Pow(2, $retryCount) * $script:RateLimitRetryBaseSeconds
                    Write-ScriptLog -Level WARN -Message "Rate limit (429). Waiting $waitTime seconds... ($retryCount/$maxRetries)"
                    Start-Sleep -Seconds $waitTime
                }
                elseif ($statusCode -eq 503) {
                    $retryCount++
                    $waitTime = [math]::Min($script:ServiceUnavailableRetryMaxSeconds, [math]::Pow(2, $retryCount) * $script:ServiceUnavailableRetryBaseSeconds)
                    Write-ScriptLog -Level WARN -Message "Service unavailable (503). Waiting $waitTime seconds before retry... ($retryCount/$maxRetries, exponential backoff)"
                    Start-Sleep -Seconds $waitTime
                }
                elseif ($statusCode -eq 504) {
                    $retryCount++
                    $waitTime = $script:GatewayTimeoutRetryIntervalSeconds
                    Write-ScriptLog -Level WARN -Message "Gateway timeout (504). Waiting $waitTime seconds before retry... ($retryCount/$maxRetries)"
                    Start-Sleep -Seconds $waitTime
                }
                else {
                    Write-ScriptLog -Level WARN -Message "API request failed: HTTP $statusCode"

                    if ($statusCode -eq 400) {
                        Write-ScriptLog -Level WARN -Message "Possible causes: invalid API key (Gemini reports it as HTTP 400), invalid model name, malformed payload. See the API response body below."
                    }
                    elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        Write-ScriptLog -Level WARN -Message "Possible cause: API key is invalid or expired."
                    }
                    elseif ($statusCode -eq 500 -or $statusCode -eq 502) {
                        Write-ScriptLog -Level WARN -Message "Server error at Google - retry later."
                    }

                    $errorBody = Get-ErrorBodyTextFromException -ErrorRecord $_
                    $originalError = Get-ErrorMessageFromException -ErrorRecord $_
                    if ([string]::IsNullOrWhiteSpace($originalError)) {
                        $originalError = $_.ToString()
                    }

                    $script:LastApiErrorMessage = ("HTTP {0}: {1}" -f $statusCode, $originalError)
                    $script:LastApiErrorBody = $errorBody

                    if (-not [string]::IsNullOrEmpty($errorBody)) {
                        Write-ScriptLog -Level WARN -Message "API response body: $errorBody"
                    }

                    Write-ScriptLog -Level WARN -Message "Original error: $originalError"
                    return $null
                }
            }
        }

        $script:LastApiErrorMessage = "API request aborted after $maxRetries attempts."
        Write-ScriptLog -Level ERROR -Message "API request aborted after $maxRetries attempts."
        return $null
    }

    # Send the tag definitions as compact JSON; the indentation of the export file only costs tokens.
    try {
        $tagContent = ConvertTo-CompactJson -InputObject @(ConvertFrom-Json -InputObject $tagContent -ErrorAction Stop) -Depth 5
    }
    catch {
        throw "The tag export file '$($tagFile.Name)' is not valid JSON: $($_.Exception.Message)"
    }

    Write-ScriptLog "Model:    $Model (thinking level: $ThinkingLevel)"
    Write-Information -MessageData '' -InformationAction Continue

    # Process each book file one by one and save every LLM response separately.
    $counter = 0
    $total = $bookFiles.Count
    $savedCount = 0
    $retriedFileCount = 0
    $retriedFileSuccessCount = 0
    $totalPromptTokens = [int64]0
    $totalCompletionTokens = [int64]0
    $totalTokens = [int64]0
    $totalFullTextBookCount = 0
    $totalProfileBookCount = 0
    $totalSavedProfileCount = 0
    $totalNoContentBookCount = 0
    $totalWebProfileCount = 0
    $totalWebNotFoundCount = 0
    $totalSearchQueryCount = 0
    $errorFileCount = 0

    if ($FullContent) {
        Write-ScriptLog "FullContent: the full book text is sent for every book; stored content profiles are not used."
        Write-Information -MessageData '' -InformationAction Continue
    }

    foreach ($bookFile in $bookFiles) {
        $counter++
        Write-ScriptLog "[$counter/$total] Processing $($bookFile.Name)..."

        # Read the current book export and build the full prompt payload.
        $bookContent = Get-Content -Path $bookFile.FullName -Raw -Encoding UTF8
        $inputUniqueBookCount = -1
        $parsedInputBooks = $null

        # Count the number of unique books in the input file for output validation.
        try {
            $parsedInputBooks = ConvertFrom-Json -InputObject $bookContent -ErrorAction Stop
            if ($parsedInputBooks -is [System.Collections.IEnumerable] -and -not ($parsedInputBooks -is [string])) {
                $inputUniqueBookCount = Get-UniqueBookCount -Items $parsedInputBooks -TitlePropertyName 'Title' -AuthorPropertyName 'Author' -SeriesPropertyName 'Series' -SeriesIndexPropertyName 'SeriesIndex'
            }
            else {
                $inputUniqueBookCount = 1
            }
        }
        catch {
            $validationWarningText = "Validation warning in '$($bookFile.Name)': Could not parse input book JSON for count validation. $($_.Exception.Message)"
            Write-ScriptLog -Level WARN -Message $validationWarningText
        }

        $fileUsage = [pscustomobject]@{ Available = $false; PromptTokens = [int64]0; CompletionTokens = [int64]0; TotalTokens = [int64]0 }
        $fileSearchQueryCount = 0

        # Books without text first get a content profile from a Google Search in a separate request, so the tag audit below can use it like any other profile. The audit request itself never searches.
        $webProfileBooks = @($parsedInputBooks | Where-Object { $null -ne $_ -and (Test-WebProfileRequired -Book $_ -FullContent:$FullContent) })
        if ($webProfileBooks.Count -gt 0) {
            Write-ScriptLog "  -> Web search for $($webProfileBooks.Count) book(s) without text..."
        }

        $fileWebProfileCount = 0
        $fileWebNotFoundCount = 0
        foreach ($webProfileBook in $webProfileBooks) {
            $webProfileResult = Request-WebContentProfile -Book $webProfileBook -TagDefinitions $tagContent -UsageCounter $fileUsage
            $fileSearchQueryCount += $webProfileResult.SearchQueryCount
            if ($null -eq $webProfileResult.ContentProfile) {
                Write-ScriptLog -Level WARN -Message "No web content profile for '$($webProfileBook.Title)': the request failed. The book is checked without content."
                continue
            }

            $profileData = [pscustomobject]@{
                ContentProfile = $webProfileResult.ContentProfile
                Source         = if ([string]::IsNullOrWhiteSpace($webProfileResult.ContentProfile)) { 'WebNotFound' } else { 'Web' }
                Sources        = @($webProfileResult.Sources)
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

        # Send the current tags with either the stored content profile or the extracted content of each book. Books sent with their full text are remembered by BookId, so their new content profiles can be stored after the response.
        $bookAnalysisRecords = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $fullTextBooksById = @{}
        $fileProfileBookCount = 0
        $fileNoContentBookCount = 0
        $bookId = 0
        foreach ($inputBook in @($parsedInputBooks | Where-Object { $null -ne $_ })) {
            $bookId++
            $bookAnalysisRecord = ConvertTo-BookAnalysisRecord -Book $inputBook -BookId $bookId -FullContent:$FullContent
            $bookAnalysisRecords.Add($bookAnalysisRecord)
            if ($bookAnalysisRecord.Contains('ContentProfile')) {
                $fileProfileBookCount++
            }
            elseif (-not [string]::IsNullOrEmpty([string]$inputBook.BookContent)) {
                $fullTextBooksById[$bookId] = $inputBook
            }
            else {
                $fileNoContentBookCount++
            }
        }
        $bookAnalysisInput = ConvertTo-CompactJson -InputObject $bookAnalysisRecords.ToArray() -Depth 10
        $totalProfileBookCount += $fileProfileBookCount
        $totalFullTextBookCount += $fullTextBooksById.Count
        $totalNoContentBookCount += $fileNoContentBookCount
        Write-ScriptLog "  -> Input: $($fullTextBooksById.Count) book(s) with full text, $fileProfileBookCount with content profile, $fileNoContentBookCount without content"

        # The prompt itself is sent as system instruction, so the input holds only the data.
        $bookPayload = @"
===================================
TAG DEFINITIONS (from $($tagFile.Name)):
===================================
$tagContent

===================================
BOOK CONTENT AND CURRENT CALIBRE TAGS (from $($bookFile.Name)):
===================================
$bookAnalysisInput
"@

        # Send the book data to the Gemini Interactions API, retrying on incomplete or invalid responses (e.g. a wrong unique-book count or text that is not JSON).
        $apiResult = $null
        $resultObject = $null
        $contentAttempt = 0

        while ($contentAttempt -lt $script:MaxContentRetries) {
            $contentAttempt++
            $requestResult = Invoke-GeminiRequest -PayloadText $bookPayload

            if ($null -eq $requestResult) {
                break
            }

            $apiResult = $requestResult.Text
            Add-TokenUsage -Counter $fileUsage -TokenUsage $requestResult.TokenUsage

            $resultObject = Convert-ResponseTextToResultObject -RawText $apiResult -SourceFile $bookFile.Name -Model $Model -ExpectedUniqueBookCount $inputUniqueBookCount

            if ($resultObject.status -eq 'success') {
                break
            }

            $retryReason = if (-not [string]::IsNullOrWhiteSpace($resultObject.validation_error)) { $resultObject.validation_error } else { $resultObject.parse_error }
            if ($contentAttempt -lt $script:MaxContentRetries) {
                Write-ScriptLog -Level WARN -Message "Invalid/incomplete response for '$($bookFile.Name)' (attempt $contentAttempt/$($script:MaxContentRetries)): $retryReason. Retrying..."
                Start-Sleep -Seconds $script:ContentRetryDelaySeconds
            }
            else {
                Write-ScriptLog -Level WARN -Message "All $($script:MaxContentRetries) attempt(s) for '$($bookFile.Name)' failed validation. Last reason: $retryReason"
            }
        }

        if ($contentAttempt -gt 1) {
            $retriedFileCount++
            if ($null -ne $resultObject -and $resultObject.status -eq 'success') {
                $retriedFileSuccessCount++
                Write-ScriptLog "  -> Retry succeeded for '$($bookFile.Name)' on attempt $contentAttempt/$($script:MaxContentRetries)."
            }
        }

        $totalSearchQueryCount += $fileSearchQueryCount
        if ($fileUsage.Available) {
            $totalPromptTokens += $fileUsage.PromptTokens
            $totalCompletionTokens += $fileUsage.CompletionTokens
            $totalTokens += $fileUsage.TotalTokens
            Write-ScriptLog "  -> Token usage for $($bookFile.Name): prompt=$($fileUsage.PromptTokens.ToString('N0')), completion=$($fileUsage.CompletionTokens.ToString('N0')), total=$($fileUsage.TotalTokens.ToString('N0'))"
        }
        else {
            Write-ScriptLog "  -> Token usage for $($bookFile.Name): unavailable"
        }

        $tokenUsage = [ordered]@{
            prompt_tokens      = if ($fileUsage.Available) { $fileUsage.PromptTokens } else { $null }
            completion_tokens  = if ($fileUsage.Available) { $fileUsage.CompletionTokens } else { $null }
            total_tokens       = if ($fileUsage.Available) { $fileUsage.TotalTokens } else { $null }
            web_search_queries = $fileSearchQueryCount
        }

        # Store the content profiles of the books sent with their full text, so later runs can send the profile instead.
        if ($null -ne $apiResult -and $resultObject.status -ne 'error' -and $fullTextBooksById.Count -gt 0) {
            $fileSavedProfileCount = Save-ContentProfile -ContentProfiles @($resultObject.content_profiles) -FullTextBooksById $fullTextBooksById -CacheDirectory $CacheDir
            $totalSavedProfileCount += $fileSavedProfileCount
            Write-ScriptLog "  -> Content profiles stored: $fileSavedProfileCount of $($fullTextBooksById.Count)"
        }

        if ($null -ne $apiResult) {
            $resultObject.token_usage = $tokenUsage
            $savedCount++
            $outName = $bookFile.Name -replace "^01-Export-CalibreBooks_", "LLM-Result_"
            $outPath = Join-Path -Path $OutputDir -ChildPath $outName

            # Store a valid JSON wrapper so parse errors and raw API output are preserved.
            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($outPath, $jsonOutput, $utf8WithBom)

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
                $errorFileCount++
                $validationErrorText = "Validation error in '$($bookFile.Name)': $($resultObject.parse_error)"
                Write-ScriptLog -Level ERROR -Message $validationErrorText
                Write-ScriptLog "  -> Saved with parse error: $outName"
            }
        }
        else {
            $savedCount++
            $errorFileCount++
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
                model                    = $Model
                status                   = 'error'
                input_unique_book_count  = if ($inputUniqueBookCount -ge 0) { $inputUniqueBookCount } else { $null }
                output_unique_book_count = 0
                unique_book_count_match  = $null
                validation_error         = $null
                records                  = @()
                content_profiles         = @()
                token_usage              = $tokenUsage
                raw_response             = if (-not [string]::IsNullOrWhiteSpace($script:LastApiErrorBody)) { $script:LastApiErrorBody } else { $apiDetail }
                parse_error              = $apiDetail
            }

            $jsonOutput = $resultObject | ConvertTo-Json -Depth 20
            $utf8WithBom = [System.Text.UTF8Encoding]::new($true)
            [System.IO.File]::WriteAllText($outPath, $jsonOutput, $utf8WithBom)

            Write-ScriptLog "  -> Saved with API error: $outName"
            $validationErrorText = "Validation error in '$($bookFile.Name)': $apiDetail"
            Write-ScriptLog -Level ERROR -Message $validationErrorText
        }

        Start-Sleep -Seconds $script:InterFileDelaySeconds
    }

    # Final summary for the completed run.
    $scriptEndTime = Get-Date
    $scriptDuration = $scriptEndTime - $scriptStartTime
    Write-Information -MessageData '' -InformationAction Continue
    Write-ScriptLog "--- Processing Complete ---"
    Write-ScriptLog "Start: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))  End: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))  Duration: $($scriptDuration.ToString('hh\:mm\:ss'))"
    Write-ScriptLog "$total files processed, $retriedFileCount retried, $retriedFileSuccessCount successful after retries."
    Write-ScriptLog "Books sent: $totalFullTextBookCount with full text, $totalProfileBookCount with content profile, $totalNoContentBookCount without content; $totalSavedProfileCount content profile(s) stored."
    Write-ScriptLog "Web search: $totalWebProfileCount web profile(s) written, $totalWebNotFoundCount book(s) not identified, $totalSearchQueryCount search queries (billed per query)."
    Write-ScriptLog "Total token usage: prompt=$($totalPromptTokens.ToString('N0')), completion=$($totalCompletionTokens.ToString('N0')), total=$($totalTokens.ToString('N0'))"

    # A completed full-library audit records the used tag definitions as the new baseline, so the change warning of 01-Export-CalibreTags.ps1 stops.
    if (Test-TagDefinitionBaselineUpdate -ScopePath $ScopePath -ErrorFileCount $errorFileCount) {
        try {
            Save-TagDefinitionBaseline -Path $TagDefinitionBaselinePath -Definitions @(Read-TagDefinitionFile -Path $tagFile.FullName)
            Write-ScriptLog "Full-library audit complete. Tag definitions recorded as audited in '$(ConvertTo-DisplayPath -Path $TagDefinitionBaselinePath -BasePath $PSScriptRoot)'."
        }
        catch {
            Write-ScriptLog -Level WARN -Message "Could not record the audited tag definitions: $($_.Exception.Message)"
        }
    }
    elseif ($errorFileCount -gt 0 -and (Test-TagDefinitionBaselineUpdate -ScopePath $ScopePath -ErrorFileCount 0)) {
        Write-ScriptLog -Level WARN -Message "$errorFileCount file(s) ended with an error, so this full-library run does not count as audit of the tag definitions. Run again with -ChangedWithinDays 0."
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