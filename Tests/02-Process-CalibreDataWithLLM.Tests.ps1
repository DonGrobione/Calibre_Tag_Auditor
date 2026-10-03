<#
.SYNOPSIS
    Pester tests for the Gemini API functions in 02-Process-CalibreDataWithLLM.ps1.

.DESCRIPTION
    Covers Get-GeminiApiKey, Get-TokenUsageFromResponse, Get-GeminiResponseText, Get-GeminiSearchSummary (search queries and cited sources), ConvertFrom-Utf8JsonResponse, Invoke-GeminiRequest (UTF-8 request and response bytes, optional google_search tool and system instruction, retries on HTTP 500/502 and connection failures), Get-ConnectionFailureStatus, Test-ProhibitedContentError, the tag audit functions ConvertTo-BookAuditPayload, Invoke-BookAuditRequest, and Invoke-SingleBookAudit (book-by-book audit of a file blocked for prohibited content),Convert-ResponseTextToResultObject (object form with Results and ContentProfiles, and the plain array), ConvertTo-CompactJson, Add-TokenUsage, the content profile functions Test-ContentProfile, ConvertTo-BookAnalysisRecord, Update-BookCacheProfile, and Save-ContentProfile, the web profile functions for books without text Test-NoTextBook, Test-WebProfileRequired, ConvertTo-WebProfileRecord, ConvertFrom-WebProfileResponse, Request-WebContentProfile, and Add-BookContentProfile, and Test-TagDefinitionBaselineUpdate, which decides whether a run counts as a full-library audit of the tag definitions. The Web profile workflow tests check in the source that only the web profile request uses the google_search tool. The cache and scope files are created under $TestDrive. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. Invoke-WebRequest and Start-Sleep are mocked; no request reaches the Gemini API.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\02-Process-CalibreDataWithLLM.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '02-Process-CalibreDataWithLLM.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @(
    'Get-GeminiApiKey', 'Get-ErrorMessageFromException', 'Get-ErrorBodyTextFromException', 'Get-ConnectionFailureStatus', 'Test-ProhibitedContentError',
    'ConvertTo-BookAuditPayload', 'Invoke-BookAuditRequest', 'Invoke-SingleBookAudit',
    'Get-TokenUsageFromResponse', 'Get-GeminiResponseText', 'Get-GeminiSearchSummary', 'Invoke-GeminiRequest',
    'Repair-JsonArrayFormatting', 'Get-JsonText', 'ConvertFrom-Utf8JsonResponse', 'Get-BookIdentityKey', 'Get-UniqueBookCount', 'Convert-ResponseTextToResultObject',
    'ConvertTo-CompactJson', 'Test-ContentProfile', 'Test-NoTextBook', 'Test-WebProfileRequired', 'ConvertTo-WebProfileRecord', 'ConvertFrom-WebProfileResponse',
    'Add-TokenUsage', 'Request-WebContentProfile', 'Add-BookContentProfile', 'ConvertTo-BookAnalysisRecord', 'Update-BookCacheProfile', 'Save-ContentProfile',
    'Test-TagDefinitionBaselineUpdate'
)
foreach ($functionName in $functionNames) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Repair-MojibakeText comes from the Calibre.Text module, as in the script.
Import-Module -Name (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1') -Force

# Stands in for the Calibre.Console logging helper so the tests write no log file.
function Write-ScriptLog {
    param($Message, $Level, $ErrorRecord)
    $null = $Message, $Level, $ErrorRecord
}

# Stands in for the Calibre.Console path helper and returns the path unchanged.
function ConvertTo-DisplayPath {
    param($Path, $BasePath)
    $null = $BasePath
    return $Path
}

# Builds a Gemini interaction response with the given text items in one model output step.
function Get-TestInteractionResponse {
    param([string[]]$Text, [string]$Status = 'completed')

    $content = @($Text | ForEach-Object { [pscustomobject]@{ type = 'text'; text = $_ } })
    return [pscustomobject]@{
        status = $Status
        steps  = @(
            [pscustomobject]@{ type = 'user_input'; content = @([pscustomobject]@{ type = 'text'; text = 'ignored input' }) },
            [pscustomobject]@{ type = 'model_output'; content = @([pscustomobject]@{ type = 'thought'; signature = 'abc' }) + $content }
        )
        usage  = [pscustomobject]@{ total_input_tokens = 100; total_output_tokens = 20; total_thought_tokens = 30; total_tokens = 150 }
    }
}

$script:ApiKey = 'test-api-key'
$script:InteractionsUrl = 'https://api.example.invalid/v1beta/interactions'
$script:Model = 'test-model'
$script:ThinkingLevel = 'medium'
$script:PromptSystem = 'Test prompt'
$script:WebProfilePromptSystem = 'Web profile prompt'
$script:MaxContentRetries = 3
$script:ContentRetryDelaySeconds = 0
$script:ApiTimeoutSec = 5
$script:MaxRequestRetries = 3
$script:RateLimitRetryBaseSeconds = 1
$script:ServiceUnavailableRetryBaseSeconds = 1
$script:ServiceUnavailableRetryMaxSeconds = 1
$script:GatewayTimeoutRetryIntervalSeconds = 1
$script:ConnectionRetryBaseSeconds = 1
$script:ConnectionRetryMaxSeconds = 1
$script:LastApiStatusCode = $null
$script:LastApiErrorBody = $null
$script:ContentProfileVersion = 1

Describe '02-Process-CalibreDataWithLLM.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }

    It 'contains no Mistral code' {
        (Get-Content -LiteralPath $scriptPath -Raw) -match 'mistral' | Should Be $false
    }
}

Describe 'Get-GeminiApiKey' {
    It 'returns the trimmed APIKey property' {
        $path = Join-Path -Path $TestDrive -ChildPath 'valid.json.key'
        Set-Content -LiteralPath $path -Value '{ "APIKey": " key-123 ", "Name": "Test" }' -Encoding UTF8
        Get-GeminiApiKey -Path $path | Should Be 'key-123'
    }

    It 'throws when the file is not JSON' {
        $path = Join-Path -Path $TestDrive -ChildPath 'plain.json.key'
        Set-Content -LiteralPath $path -Value 'APIKey = key-123' -Encoding UTF8
        { Get-GeminiApiKey -Path $path } | Should Throw 'not valid JSON'
    }

    It 'throws when the APIKey property is missing' {
        $path = Join-Path -Path $TestDrive -ChildPath 'missing.json.key'
        Set-Content -LiteralPath $path -Value '{ "Name": "Test" }' -Encoding UTF8
        { Get-GeminiApiKey -Path $path } | Should Throw "no value for the property 'APIKey'"
    }

    It 'throws when the APIKey property is empty' {
        $path = Join-Path -Path $TestDrive -ChildPath 'empty.json.key'
        Set-Content -LiteralPath $path -Value '{ "APIKey": "  " }' -Encoding UTF8
        { Get-GeminiApiKey -Path $path } | Should Throw "no value for the property 'APIKey'"
    }
}

Describe 'Get-TokenUsageFromResponse' {
    It 'counts thinking tokens as completion tokens' {
        $usage = Get-TokenUsageFromResponse -Response (Get-TestInteractionResponse -Text 'x')
        $usage.PromptTokens | Should Be 100
        $usage.CompletionTokens | Should Be 50
        $usage.TotalTokens | Should Be 150
    }

    It 'calculates the total when the response has no total' {
        $response = [pscustomobject]@{ usage = [pscustomobject]@{ total_input_tokens = 10; total_output_tokens = 5 } }
        (Get-TokenUsageFromResponse -Response $response).TotalTokens | Should Be 15
    }

    It 'returns $null without usage data' {
        Get-TokenUsageFromResponse -Response ([pscustomobject]@{ status = 'completed' }) | Should Be $null
    }
}

Describe 'Get-GeminiResponseText' {
    It 'joins the text items of the model output and ignores thoughts and input' {
        Get-GeminiResponseText -Response (Get-TestInteractionResponse -Text '[{"Title":', '"A"}]') | Should Be '[{"Title":"A"}]'
    }

    It 'repairs mojibake in the response text' {
        Get-GeminiResponseText -Response (Get-TestInteractionResponse -Text 'BegrÃ¼ndung') | Should Be 'Begründung'
    }

    It 'warns when the interaction is not completed' {
        Mock Write-ScriptLog { }
        $null = Get-GeminiResponseText -Response (Get-TestInteractionResponse -Text 'x' -Status 'incomplete')
        Assert-MockCalled Write-ScriptLog -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'incomplete' }
    }

    It 'returns the raw response as JSON when it contains no text' {
        Mock Write-ScriptLog { }
        $text = Get-GeminiResponseText -Response ([pscustomobject]@{ status = 'failed'; steps = @() })
        ($text | ConvertFrom-Json).status | Should Be 'failed'
    }
}

# Builds a Gemini interaction response with Google Search steps: one search call with the given queries and a model output with url_citation annotations for the given URLs.
function Get-TestSearchResponse {
    param([string]$Text, [string[]]$Queries, [string[]]$Urls)

    $annotations = @($Urls | ForEach-Object { [pscustomobject]@{ type = 'url_citation'; url = $_; title = ([uri]$_).Host; start_index = 0; end_index = 5 } })
    return [pscustomobject]@{
        status = 'completed'
        steps  = @(
            [pscustomobject]@{ type = 'user_input'; content = @([pscustomobject]@{ type = 'text'; text = 'ignored input' }) },
            [pscustomobject]@{ type = 'google_search_call'; arguments = [pscustomobject]@{ queries = $Queries } },
            [pscustomobject]@{ type = 'google_search_result'; call_id = 'search_001'; result = @([pscustomobject]@{ search_suggestions = '<div></div>' }) },
            [pscustomobject]@{ type = 'model_output'; content = @([pscustomobject]@{ type = 'text'; text = $Text; annotations = $annotations }) }
        )
        usage  = [pscustomobject]@{ total_input_tokens = 10; total_output_tokens = 5; total_tokens = 15 }
    }
}

Describe 'Get-GeminiSearchSummary' {
    It 'counts the search queries and returns the unique cited sources' {
        $response = Get-TestSearchResponse -Text 'x' -Queries @('query 1', 'query 2') -Urls @('https://a.example/1', 'https://b.example/2', 'https://a.example/1')
        $summary = Get-GeminiSearchSummary -Response $response
        $summary.QueryCount | Should Be 2
        @($summary.Sources).Count | Should Be 2
        $summary.Sources[0].Url | Should Be 'https://a.example/1'
        $summary.Sources[0].Title | Should Be 'a.example'
    }

    It 'returns 0 queries and no sources for a response without search' {
        $summary = Get-GeminiSearchSummary -Response (Get-TestInteractionResponse -Text 'x')
        $summary.QueryCount | Should Be 0
        @($summary.Sources).Count | Should Be 0
    }

    It 'handles a $null response' {
        (Get-GeminiSearchSummary -Response $null).QueryCount | Should Be 0
    }
}

# Builds a fake Invoke-WebRequest result whose raw content is the given object as UTF-8 JSON bytes, like a server response without charset handling.
function Get-TestWebResponse {
    param([Parameter(Mandatory = $true)][object]$InputObject)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($InputObject | ConvertTo-Json -Depth 10))
    return [pscustomobject]@{ RawContentStream = (New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $bytes)) }
}

# Text with an umlaut, an en dash, and a typographic apostrophe, built from character codes.
$specialText = "Begr$([char]0xFC)ndung $([char]0x2013) it$([char]0x2019)s"

Describe 'ConvertFrom-Utf8JsonResponse' {
    It 'decodes the raw response bytes as UTF-8' {
        $result = ConvertFrom-Utf8JsonResponse -WebResponse (Get-TestWebResponse -InputObject @{ text = $specialText })
        $result.text | Should BeExactly $specialText
    }

    It 'ignores a UTF-8 byte order mark' {
        $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('{ "a": 1 }')
        $webResponse = [pscustomobject]@{ RawContentStream = (New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [byte[]]$bytes)) }
        (ConvertFrom-Utf8JsonResponse -WebResponse $webResponse).a | Should Be 1
    }
}

# The response body of a Gemini request blocked for prohibited content, as logged on 2026-10-03.
$prohibitedContentBody = '{"error":{"message":"Request blocked due to prohibited content guidelines. Please modify your input and retry.","code":"The model output could not be generated. This output contains sensitive words that violate Google''s Generative AI Prohibited Use policy."}}'

# Builds a WebException without HTTP response with the given status, as Invoke-WebRequest throws it for DNS, connection, and timeout failures.
function Get-TestWebException {
    param([Parameter(Mandatory = $true)][System.Net.WebExceptionStatus]$Status)
    return (New-Object -TypeName System.Net.WebException -ArgumentList "Test failure $Status", $Status)
}

# Builds an exception with a fake HTTP response that carries the status code and returns the body from GetResponseStream.
function Get-TestHttpException {
    param([Parameter(Mandatory = $true)][int]$StatusCode, [string]$Body = '')

    $response = [pscustomobject]@{ StatusCode = [pscustomobject]@{ value__ = $StatusCode }; Body = $Body }
    $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
        New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [System.Text.Encoding]::UTF8.GetBytes($this.Body))
    }
    $exception = New-Object -TypeName System.Exception -ArgumentList "HTTP $StatusCode"
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
    return $exception
}

# Wraps an exception in an ErrorRecord, as a catch block receives it.
function Get-TestErrorRecord {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)
    return (New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $Exception, 'TestError', ([System.Management.Automation.ErrorCategory]::NotSpecified), $null)
}

Describe 'Invoke-GeminiRequest' {
    Mock Start-Sleep { }

    It 'sends model, system instruction, input, and thinking level with the API key header' {
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'ok') }
        $result = Invoke-GeminiRequest -PayloadText 'book data'
        $result.Text | Should Be 'ok'
        $result.TokenUsage.TotalTokens | Should Be 150
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter {
            $sent = [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json
            $Uri -eq 'https://api.example.invalid/v1beta/interactions' -and $Method -eq 'Post' -and $UseBasicParsing -and
            $Headers['x-goog-api-key'] -eq 'test-api-key' -and
            $sent.model -eq 'test-model' -and $sent.system_instruction -eq 'Test prompt' -and $sent.input -eq 'book data' -and
            $sent.generation_config.thinking_level -eq 'medium' -and $sent.store -eq $false
        }
    }

    It 'sends no tools without -UseGoogleSearch' {
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'ok') }
        $null = Invoke-GeminiRequest -PayloadText 'book data'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter {
            $null -eq ([System.Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json).PSObject.Properties['tools']
        }
    }

    It 'sends the google_search tool and the given system instruction with -UseGoogleSearch' {
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestSearchResponse -Text '{}' -Queries @('q1', 'q2', 'q3') -Urls @('https://a.example/1')) }
        $result = Invoke-GeminiRequest -PayloadText 'metadata' -SystemInstruction 'Other prompt' -UseGoogleSearch
        $result.SearchQueryCount | Should Be 3
        @($result.Sources).Count | Should Be 1
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter {
            $sent = [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json
            $sent.system_instruction -eq 'Other prompt' -and @($sent.tools).Count -eq 1 -and $sent.tools[0].type -eq 'google_search'
        }
    }

    It 'sends the request body as UTF-8 bytes' {
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'ok') }
        $null = Invoke-GeminiRequest -PayloadText $specialText
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly -ParameterFilter {
            $Body -is [byte[]] -and ([System.Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json).input -ceq $specialText
        }
    }

    It 'returns umlauts and typographic characters of the response unchanged' {
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text $specialText) }
        (Invoke-GeminiRequest -PayloadText 'book data').Text | Should BeExactly $specialText
    }

    It 'retries after a rate limit (429) and returns the later response' {
        $script:callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                $exception = New-Object System.Exception 'Too many requests'
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [pscustomobject]@{ value__ = 429 } })
                throw $exception
            }
            Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'second')
        }
        (Invoke-GeminiRequest -PayloadText 'book data').Text | Should Be 'second'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 2 -Exactly
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly
    }

    It 'returns $null and stores the error for a non-retryable error' {
        Mock Invoke-WebRequest { throw 'Bad request' }
        Invoke-GeminiRequest -PayloadText 'book data' | Should Be $null
        $script:LastApiErrorMessage | Should Match 'Bad request'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly
    }

    It 'retries after a DNS failure without HTTP response and returns the later response' {
        $script:callCount = 0
        Mock Invoke-WebRequest {
            $script:callCount++
            if ($script:callCount -eq 1) {
                throw (Get-TestWebException -Status NameResolutionFailure)
            }
            Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'second')
        }
        (Invoke-GeminiRequest -PayloadText 'book data').Text | Should Be 'second'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 2 -Exactly
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly
    }

    It 'gives up after the maximum number of attempts on repeated connection failures' {
        Mock Invoke-WebRequest { throw (Get-TestWebException -Status ConnectFailure) }
        Invoke-GeminiRequest -PayloadText 'book data' | Should Be $null
        $script:LastApiErrorMessage | Should Match 'aborted after 3 attempts'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 3 -Exactly
    }

    It 'retries after an HTTP 500 or 502 server error' {
        foreach ($statusCode in @(500, 502)) {
            $script:callCount = 0
            $script:testStatusCode = $statusCode
            Mock Invoke-WebRequest {
                $script:callCount++
                if ($script:callCount -eq 1) {
                    throw (Get-TestHttpException -StatusCode $script:testStatusCode -Body 'server error')
                }
                Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'second')
            }
            (Invoke-GeminiRequest -PayloadText 'book data').Text | Should Be 'second'
        }
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 4 -Exactly
    }

    It 'stores status code and body of a prohibited content block without retry' {
        Mock Invoke-WebRequest { throw (Get-TestHttpException -StatusCode 400 -Body $prohibitedContentBody) }
        Invoke-GeminiRequest -PayloadText 'book data' | Should Be $null
        $script:LastApiStatusCode | Should Be 400
        $script:LastApiErrorBody | Should Be $prohibitedContentBody
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 1 -Exactly
    }

    It 'resets the stored status code with the next request' {
        Mock Invoke-WebRequest { throw (Get-TestHttpException -StatusCode 400 -Body $prohibitedContentBody) }
        $null = Invoke-GeminiRequest -PayloadText 'book data'
        Mock Invoke-WebRequest { Get-TestWebResponse -InputObject (Get-TestInteractionResponse -Text 'ok') }
        $null = Invoke-GeminiRequest -PayloadText 'book data'
        $script:LastApiStatusCode | Should Be $null
    }
}

Describe 'Get-ConnectionFailureStatus' {
    It 'returns the status name of a transient connection failure without response' {
        foreach ($status in @('NameResolutionFailure', 'ConnectFailure', 'Timeout', 'ReceiveFailure')) {
            Get-ConnectionFailureStatus -ErrorRecord (Get-TestErrorRecord -Exception (Get-TestWebException -Status $status)) | Should Be $status
        }
    }

    It 'finds the WebException as inner exception' {
        $exception = New-Object -TypeName System.Exception -ArgumentList 'outer', (Get-TestWebException -Status NameResolutionFailure)
        Get-ConnectionFailureStatus -ErrorRecord (Get-TestErrorRecord -Exception $exception) | Should Be 'NameResolutionFailure'
    }

    It 'returns $null for a non-transient status, another exception, or $null' {
        Get-ConnectionFailureStatus -ErrorRecord (Get-TestErrorRecord -Exception (Get-TestWebException -Status TrustFailure)) | Should Be $null
        Get-ConnectionFailureStatus -ErrorRecord (Get-TestErrorRecord -Exception (New-Object -TypeName System.Exception -ArgumentList 'other')) | Should Be $null
        Get-ConnectionFailureStatus -ErrorRecord $null | Should Be $null
    }
}

Describe 'Test-ProhibitedContentError' {
    It 'returns $true for HTTP 400 with a prohibited content message' {
        Test-ProhibitedContentError -StatusCode 400 -ErrorBody $prohibitedContentBody | Should Be $true
    }

    It 'returns $false for another HTTP 400, another status code, or a missing body' {
        Test-ProhibitedContentError -StatusCode 400 -ErrorBody '{"error":{"message":"API key not valid."}}' | Should Be $false
        Test-ProhibitedContentError -StatusCode 500 -ErrorBody $prohibitedContentBody | Should Be $false
        Test-ProhibitedContentError -StatusCode $null -ErrorBody $prohibitedContentBody | Should Be $false
        Test-ProhibitedContentError -StatusCode 400 -ErrorBody $null | Should Be $false
    }
}

Describe 'ConvertTo-BookAuditPayload' {
    It 'joins the tag section and the book records as JSON array with the file name' {
        $payload = ConvertTo-BookAuditPayload -TagSection 'TAGS: [{"Tag":"T"}]' -BookFileName 'books_001.json' -BookRecords @([ordered]@{ BookId = 2; Title = 'A' })
        $payload | Should Match '^TAGS: \[\{"Tag":"T"\}\]'
        $payload | Should Match 'CURRENT CALIBRE TAGS \(from books_001\.json\)'
        $payload | Should Match '\[\{"BookId":2,"Title":"A"\}\]$'
    }
}

# Returns a fresh token usage counter.
function Get-TestUsageCounter {
    return [pscustomobject]@{ Available = $false; PromptTokens = [int64]0; CompletionTokens = [int64]0; TotalTokens = [int64]0 }
}

# Returns a successful Invoke-GeminiRequest result with the given text and 15 tokens.
function Get-TestRequestResult {
    param([string]$Text)
    return [pscustomobject]@{ Text = $Text; TokenUsage = [pscustomobject]@{ PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15 }; SearchQueryCount = 0; Sources = @() }
}

Describe 'Invoke-BookAuditRequest' {
    Mock Start-Sleep { }
    Mock Write-ScriptLog { }

    It 'returns the parsed result, the raw text, and the token usage of a valid response' {
        Mock Invoke-GeminiRequest { Get-TestRequestResult -Text '{"Results":[{"Title":"A","Author":"X"}]}' }
        $result = Invoke-BookAuditRequest -PayloadText 'payload' -SourceFile 'file.json' -ExpectedUniqueBookCount 1
        $result.ResultObject.status | Should Be 'success'
        $result.RawText | Should Match '"Title":"A"'
        $result.Attempts | Should Be 1
        $result.Usage.TotalTokens | Should Be 15
    }

    It 'retries an invalid response and adds the tokens of all attempts' {
        $script:auditAttempt = 0
        Mock Invoke-GeminiRequest {
            $script:auditAttempt++
            $text = if ($script:auditAttempt -eq 1) { 'no json' } else { '{"Results":[{"Title":"A","Author":"X"}]}' }
            Get-TestRequestResult -Text $text
        }
        $result = Invoke-BookAuditRequest -PayloadText 'payload' -SourceFile 'file.json' -ExpectedUniqueBookCount 1
        $result.ResultObject.status | Should Be 'success'
        $result.Attempts | Should Be 2
        $result.Usage.TotalTokens | Should Be 30
    }

    It 'returns no result when the request fails' {
        Mock Invoke-GeminiRequest { $null }
        $result = Invoke-BookAuditRequest -PayloadText 'payload' -SourceFile 'file.json'
        $result.RawText | Should Be $null
        $result.ResultObject | Should Be $null
        $result.Attempts | Should Be 1
        $result.Usage.Available | Should Be $false
    }
}

Describe 'Invoke-SingleBookAudit' {
    Mock Start-Sleep { }
    Mock Write-ScriptLog { }

    $bookRecords = @(
        [ordered]@{ BookId = 1; Title = 'Good A'; Author = 'X'; Series = $null; SeriesIndex = $null; ExistingCalibreTags = 'T'; BookContent = 'text a' },
        [ordered]@{ BookId = 2; Title = 'Bad B'; Author = 'Y'; Series = $null; SeriesIndex = $null; ExistingCalibreTags = 'T'; BookContent = 'text b' },
        [ordered]@{ BookId = 3; Title = 'Good C'; Author = 'Z'; Series = $null; SeriesIndex = $null; ExistingCalibreTags = 'T'; ContentProfile = 'profile c' }
    )

    # Answers each single-book request for its title, except that 'Bad B' is blocked for prohibited content.
    Mock Invoke-GeminiRequest {
        $script:LastApiStatusCode = $null
        $script:LastApiErrorBody = $null
        if ($PayloadText -match '"Title":"Bad B"') {
            $script:LastApiStatusCode = 400
            $script:LastApiErrorBody = $prohibitedContentBody
            return $null
        }
        $match = [regex]::Match($PayloadText, '"BookId":(\d+),"Title":"([^"]+)","Author":"([^"]+)"')
        $text = '{"Results":[{"Title":"' + $match.Groups[2].Value + '","Author":"' + $match.Groups[3].Value + '"}],"ContentProfiles":[{"BookId":' + $match.Groups[1].Value + ',"ContentProfile":"P"}]}'
        Get-TestRequestResult -Text $text
    }

    It 'sends each book in its own request with its original BookId' {
        $null = Invoke-SingleBookAudit -BookRecords $bookRecords -TagSection 'TAGS' -BookFileName 'books_001.json'
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 3 -Exactly
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 1 -Exactly -ParameterFilter { $PayloadText -match '^TAGS' -and $PayloadText -match '\[\{"BookId":3,' -and $PayloadText -notmatch 'Good A' }
    }

    It 'merges the results of the other books and names the blocked book' {
        $result = Invoke-SingleBookAudit -BookRecords $bookRecords -TagSection 'TAGS' -BookFileName 'books_001.json'
        $merged = $result.ResultObject
        $merged.source_file | Should Be 'books_001.json'
        $merged.status | Should Be 'warning'
        @($merged.records).Count | Should Be 2
        @($merged.content_profiles | ForEach-Object { $_.BookId }) -join ',' | Should Be '1,3'
        $merged.input_unique_book_count | Should Be 3
        $merged.output_unique_book_count | Should Be 2
        $merged.validation_error | Should Match "'Bad B' \(blocked for prohibited content\)"
        @($merged.raw_response).Count | Should Be 2
        $result.Usage.TotalTokens | Should Be 30
    }

    It 'returns success when no book is blocked' {
        $result = Invoke-SingleBookAudit -BookRecords @($bookRecords[0], $bookRecords[2]) -TagSection 'TAGS' -BookFileName 'books_001.json'
        $result.ResultObject.status | Should Be 'success'
        $result.ResultObject.validation_error | Should Be $null
    }

    It 'returns no result object when every book is blocked' {
        $result = Invoke-SingleBookAudit -BookRecords @($bookRecords[1]) -TagSection 'TAGS' -BookFileName 'books_001.json'
        $result.ResultObject | Should Be $null
    }
}

Describe 'Prohibited content fallback workflow' {
    It 'sends the books one at a time only after a prohibited content block of a file with several books' {
        $scriptAst.Extent.Text | Should Match '(?s)if \(\$null -eq \$apiResult -and \$bookAnalysisRecords\.Count -gt 1 -and \(Test-ProhibitedContentError [^\r\n]+\r?\n.*?Invoke-SingleBookAudit '
    }
}

Describe 'Convert-ResponseTextToResultObject' {
    It 'stores the model and validates the unique-book count' {
        $result = Convert-ResponseTextToResultObject -RawText '```json [{"Title":"A","Author":"X"}] ```' -SourceFile 'file.json' -Model 'test-model' -ExpectedUniqueBookCount 1
        $result.model | Should Be 'test-model'
        $result.status | Should Be 'success'
        $result.output_unique_book_count | Should Be 1
    }

    It 'reports a parse error for text without JSON' {
        $result = Convert-ResponseTextToResultObject -RawText 'no json here' -SourceFile 'file.json' -Model 'test-model'
        $result.status | Should Be 'error'
        $result.parse_error | Should Match 'Gemini response'
    }

    It 'reads the records from Results and the profiles from ContentProfiles' {
        $rawText = '{"Results":[{"Title":"A","Author":"X","ProposedAction":"ADD","Tag":"T","Reason":"R"},{"Title":"B","Author":"Y","ProposedAction":"NO_CHANGES","Tag":null,"Reason":null}],"ContentProfiles":[{"BookId":1,"ContentProfile":"Profile A"}]}'
        $result = Convert-ResponseTextToResultObject -RawText $rawText -SourceFile 'file.json' -Model 'test-model' -ExpectedUniqueBookCount 2
        $result.status | Should Be 'success'
        @($result.records).Count | Should Be 2
        $result.records[0].Title | Should Be 'A'
        @($result.content_profiles).Count | Should Be 1
        $result.content_profiles[0].ContentProfile | Should Be 'Profile A'
    }

    It 'accepts an object form without ContentProfiles' {
        $result = Convert-ResponseTextToResultObject -RawText '{"Results":[{"Title":"A","Author":"X"}]}' -SourceFile 'file.json' -Model 'test-model' -ExpectedUniqueBookCount 1
        $result.status | Should Be 'success'
        @($result.content_profiles).Count | Should Be 0
    }

    It 'reports a count mismatch in the object form' {
        $result = Convert-ResponseTextToResultObject -RawText '{"Results":[{"Title":"A","Author":"X"}],"ContentProfiles":[]}' -SourceFile 'file.json' -Model 'test-model' -ExpectedUniqueBookCount 2
        $result.status | Should Be 'warning'
    }

    It 'still accepts a plain array without profiles' {
        $result = Convert-ResponseTextToResultObject -RawText '[{"Title":"A","Author":"X"},{"Title":"B","Author":"Y"}]' -SourceFile 'file.json' -Model 'test-model' -ExpectedUniqueBookCount 2
        $result.status | Should Be 'success'
        @($result.records).Count | Should Be 2
        @($result.content_profiles).Count | Should Be 0
    }
}

Describe 'ConvertTo-CompactJson' {
    It 'writes JSON without line breaks or indentation' {
        $json = ConvertTo-CompactJson -InputObject @([ordered]@{ Title = 'A'; Tags = 'X, Y' })
        $json | Should Not Match "`n"
        $json | Should Not Match '\{ '
    }

    It 'writes &, apostrophe, <, and > as characters instead of \u escapes' {
        $text = "it's <b> & more"
        $json = ConvertTo-CompactJson -InputObject ([ordered]@{ Text = $text })
        $json | Should Not Match '\\u00'
        (ConvertFrom-Json -InputObject $json).Text | Should BeExactly $text
    }

    It 'keeps literal backslash-u text in the content unchanged' {
        # Built from parts, so no editor turns the escape sequences into characters.
        $text = 'literal \' + 'u0027 and \\' + 'u0026'
        $json = ConvertTo-CompactJson -InputObject ([ordered]@{ Text = $text })
        (ConvertFrom-Json -InputObject $json).Text | Should BeExactly $text
    }

    It 'keeps umlauts and typographic characters' {
        (ConvertFrom-Json -InputObject (ConvertTo-CompactJson -InputObject ([ordered]@{ Text = $specialText }))).Text | Should BeExactly $specialText
    }
}

# Builds a book export record as written by 01-Export-CalibreBooks.ps1.
function Get-TestExportBook {
    param(
        [AllowNull()]
        [string]$ContentProfile,
        [AllowNull()]
        [object]$ContentProfileVersion = 1,
        [string]$Uuid = '0f8fad5b-d9cb-469f-a165-70867728950e'
    )

    return [pscustomobject]@{
        Uuid                  = $Uuid
        Title                 = 'Book'
        Author                = 'Author'
        Series                = 'Series'
        SeriesIndex           = 2
        Tags                  = 'Fantasy, LitRPG'
        ContentHash           = 'hash-1'
        ContentProfile        = $ContentProfile
        ContentProfileVersion = $ContentProfileVersion
        BookContent           = 'Full book text'
    }
}

# Builds a book export record of a book without text (ContentStatus NoText) with the given profile, source, and profile version.
function Get-TestNoTextBook {
    param(
        [AllowNull()]
        [string]$ContentProfile,
        [AllowNull()]
        [string]$ContentProfileSource,
        [AllowNull()]
        [object]$ContentProfileVersion = 1
    )

    return [pscustomobject]@{
        Uuid                  = '0f8fad5b-d9cb-469f-a165-70867728950e'
        Title                 = 'Manga 3'
        Author                = 'Mangaka'
        Series                = 'Manga'
        SeriesIndex           = 3
        Tags                  = 'Manga'
        IDs                   = 'isbn:9781234567897'
        Publisher             = 'Publisher'
        Year                  = 2020
        Description           = 'Publisher description'
        ContentStatus         = 'NoText'
        ContentHash           = 'meta-hash'
        ContentProfile        = $ContentProfile
        ContentProfileVersion = $ContentProfileVersion
        ContentProfileSource  = $ContentProfileSource
        ContentProfileSources = $null
        BookContent           = $null
    }
}

Describe 'ConvertTo-BookAnalysisRecord' {
    It 'marks a web profile with ContentProfileSource Web' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web') -BookId 1
        $record.ContentProfile | Should Be 'Web profile'
        $record.ContentProfileSource | Should Be 'Web'
        $record.Contains('BookContent') | Should Be $false
    }

    It 'sends the web profile of a book without text also with -FullContent' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web') -BookId 1 -FullContent
        $record.ContentProfile | Should Be 'Web profile'
    }

    It 'sends a book without text and with a WebNotFound marker without content' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestNoTextBook -ContentProfile '' -ContentProfileSource 'WebNotFound') -BookId 1
        $record.Contains('ContentProfile') | Should Be $false
        $record.BookContent | Should Be $null
    }

    It 'does not send ContentProfileSource for a profile written from the book text' {
        $book = Get-TestExportBook -ContentProfile 'Profile'
        $book | Add-Member -NotePropertyName ContentProfileSource -NotePropertyValue 'Text'
        (ConvertTo-BookAnalysisRecord -Book $book -BookId 1).Contains('ContentProfileSource') | Should Be $false
    }

    It 'does not send the description or identifiers to the tag audit' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web') -BookId 1
        $record.Contains('Description') | Should Be $false
        $record.Contains('IDs') | Should Be $false
    }

    It 'sends the content profile instead of the book text when a current profile exists' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestExportBook -ContentProfile 'Profile') -BookId 3
        $record.BookId | Should Be 3
        $record.ExistingCalibreTags | Should Be 'Fantasy, LitRPG'
        $record.ContentProfile | Should Be 'Profile'
        $record.Contains('BookContent') | Should Be $false
    }

    It 'sends the book text with -FullContent' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestExportBook -ContentProfile 'Profile') -BookId 1 -FullContent
        $record.BookContent | Should Be 'Full book text'
        $record.Contains('ContentProfile') | Should Be $false
    }

    It 'sends the book text when the profile version is outdated' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestExportBook -ContentProfile 'Profile' -ContentProfileVersion 0) -BookId 1
        $record.Contains('ContentProfile') | Should Be $false
        $record.BookContent | Should Be 'Full book text'
    }

    It 'sends the book text when the profile is empty' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestExportBook -ContentProfile ' ') -BookId 1
        $record.Contains('ContentProfile') | Should Be $false
    }

    It 'sends the book text for an export record without profile fields' {
        $book = [pscustomobject]@{ Title = 'Old'; Author = 'A'; Series = $null; SeriesIndex = $null; Tags = 'X'; BookContent = 'Text' }
        $record = ConvertTo-BookAnalysisRecord -Book $book -BookId 1
        $record.BookContent | Should Be 'Text'
        $record.Contains('ContentProfile') | Should Be $false
    }

    It 'does not send Uuid or ContentHash to the LLM' {
        $record = ConvertTo-BookAnalysisRecord -Book (Get-TestExportBook -ContentProfile 'Profile') -BookId 1
        $record.Contains('Uuid') | Should Be $false
        $record.Contains('ContentHash') | Should Be $false
    }
}

# Writes a cache file for the test book with the given content hash and returns its path.
function Add-TestBookCacheFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ContentHash
    )

    $null = New-Item -Path $CacheDirectory -ItemType Directory -Force
    $path = Join-Path -Path $CacheDirectory -ChildPath '0f8fad5b-d9cb-469f-a165-70867728950e.json'
    $json = '{ "CacheVersion": 1, "LastModified": "x", "Uuid": "0f8fad5b-d9cb-469f-a165-70867728950e", "ContentHash": "' + $ContentHash + '", "BookContent": "Full book text" }'
    [System.IO.File]::WriteAllText($path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    return $path
}

# Builds the profile data of a profile written from the book text, as Save-ContentProfile passes it to Update-BookCacheProfile.
function Get-TestTextProfile {
    param([string]$Text)

    return [pscustomobject]@{ ContentProfile = $Text; Source = 'Text'; Sources = $null }
}

Describe 'Update-BookCacheProfile' {
    It 'stores a web profile with its source and cited sources' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-web'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'meta-hash'
        $profileData = [pscustomobject]@{ ContentProfile = 'Web profile'; Source = 'Web'; Sources = @([pscustomobject]@{ Title = 'a.example'; Url = 'https://a.example/1' }) }
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestNoTextBook) -ProfileData $profileData | Should Be $true
        $cached = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
        $cached.ContentProfileSource | Should Be 'Web'
        $cached.ContentProfileSources[0].Url | Should Be 'https://a.example/1'
    }

    It 'stores a WebNotFound marker with an empty profile' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-notfound'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'meta-hash'
        $profileData = [pscustomobject]@{ ContentProfile = ''; Source = 'WebNotFound'; Sources = @() }
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestNoTextBook) -ProfileData $profileData | Should Be $true
        $cached = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
        $cached.ContentProfileSource | Should Be 'WebNotFound'
        $cached.ContentProfile | Should Be ''
        $cached.ContentProfileSources | Should Be $null
    }

    It 'writes nothing for an empty Text or Web profile or an unknown source' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-invalid'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text ' ') | Should Be $false
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData ([pscustomobject]@{ ContentProfile = ''; Source = 'Web' }) | Should Be $false
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData ([pscustomobject]@{ ContentProfile = 'P'; Source = 'Other' }) | Should Be $false
        [System.IO.File]::ReadAllText($path) | Should Not Match 'ContentProfile'
    }

    It 'stores the source Text for a profile written from the book text' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-text-source'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        $null = Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile')
        (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))).ContentProfileSource | Should Be 'Text'
    }

    It 'stores the profile and its version in the cache file and keeps the other fields' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-match'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text $specialText) | Should Be $true

        [System.IO.File]::ReadAllBytes($path)[0] | Should Not Be 0xEF
        $cached = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
        $cached.ContentProfile | Should BeExactly $specialText
        $cached.ContentProfileVersion | Should Be 1
        $cached.BookContent | Should Be 'Full book text'
        $cached.ContentHash | Should Be 'hash-1'
    }

    It 'replaces an older profile' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-replace'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        $null = Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'First')
        $null = Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Second')
        (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))).ContentProfile | Should Be 'Second'
    }

    It 'writes nothing when the cache file holds a different book text' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-mismatch'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-other'
        $before = [System.IO.File]::ReadAllText($path)
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile') | Should Be $false
        [System.IO.File]::ReadAllText($path) | Should BeExactly $before
    }

    It 'returns $false when the cache file is missing' {
        Update-BookCacheProfile -CacheDirectory (Join-Path -Path $TestDrive -ChildPath 'update-missing') -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile') | Should Be $false
    }

    It 'returns $false for an invalid UUID' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-uuid'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook -Uuid '..\evil') -ProfileData (Get-TestTextProfile -Text 'Profile') | Should Be $false
    }

    It 'logs the stored cache file as DEBUG' {
        Mock Write-ScriptLog { }
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-log'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        $null = Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile')
        Assert-MockCalled Write-ScriptLog -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'DEBUG' -and $Message -match '\(Text\).*0f8fad5b-d9cb-469f-a165-70867728950e\.json$' }
    }

    It 'logs nothing when the cache file is not written' {
        Mock Write-ScriptLog { }
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-nolog'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-other'
        $null = Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile')
        Assert-MockCalled Write-ScriptLog -Scope It -Times 0 -Exactly
    }

    It 'writes nothing with -WhatIf' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'update-whatif'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Update-BookCacheProfile -CacheDirectory $cacheDirectory -Book (Get-TestExportBook) -ProfileData (Get-TestTextProfile -Text 'Profile') -WhatIf | Should Be $false
        [System.IO.File]::ReadAllText($path) | Should Not Match 'ContentProfile'
    }
}

Describe 'Save-ContentProfile' {
    It 'stores only profiles of books that were sent with their full text' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'save-filter'
        $path = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        $profiles = @(
            [pscustomobject]@{ BookId = 1; ContentProfile = ' Stored profile ' },
            [pscustomobject]@{ BookId = 2; ContentProfile = 'Book sent as profile' },
            [pscustomobject]@{ BookId = 9; ContentProfile = 'Unknown book' },
            [pscustomobject]@{ ContentProfile = 'No BookId' }
        )
        Save-ContentProfile -ContentProfiles $profiles -FullTextBooksById @{ 1 = (Get-TestExportBook) } -CacheDirectory $cacheDirectory | Should Be 1
        (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))).ContentProfile | Should BeExactly 'Stored profile'
    }

    It 'accepts a BookId given as a string' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'save-string'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Save-ContentProfile -ContentProfiles @([pscustomobject]@{ BookId = '1'; ContentProfile = 'Profile' }) -FullTextBooksById @{ 1 = (Get-TestExportBook) } -CacheDirectory $cacheDirectory | Should Be 1
    }

    It 'skips empty profiles' {
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'save-empty'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-1'
        Save-ContentProfile -ContentProfiles @([pscustomobject]@{ BookId = 1; ContentProfile = '  ' }) -FullTextBooksById @{ 1 = (Get-TestExportBook) } -CacheDirectory $cacheDirectory | Should Be 0
    }

    It 'warns and continues when the cache file does not match' {
        Mock Write-ScriptLog { }
        $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'save-mismatch'
        $null = Add-TestBookCacheFile -CacheDirectory $cacheDirectory -ContentHash 'hash-other'
        Save-ContentProfile -ContentProfiles @([pscustomobject]@{ BookId = 1; ContentProfile = 'Profile' }) -FullTextBooksById @{ 1 = (Get-TestExportBook) } -CacheDirectory $cacheDirectory | Should Be 0
        Assert-MockCalled Write-ScriptLog -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'returns 0 for an empty profile list' {
        Save-ContentProfile -ContentProfiles @() -FullTextBooksById @{} -CacheDirectory $TestDrive | Should Be 0
    }
}

Describe 'Test-NoTextBook' {
    It 'returns $true only for ContentStatus NoText' {
        Test-NoTextBook -Book (Get-TestNoTextBook) | Should Be $true
        Test-NoTextBook -Book (Get-TestExportBook) | Should Be $false
        Test-NoTextBook -Book ([pscustomobject]@{ ContentStatus = 'Failed' }) | Should Be $false
    }
}

Describe 'Test-WebProfileRequired' {
    It 'returns $true for a book without text and without profile' {
        Test-WebProfileRequired -Book (Get-TestNoTextBook) | Should Be $true
    }

    It 'returns $false for a book without text with a current web profile or WebNotFound marker' {
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web') | Should Be $false
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile '' -ContentProfileSource 'WebNotFound') | Should Be $false
    }

    It 'returns $true when the profile or marker has an outdated version' {
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web' -ContentProfileVersion 0) | Should Be $true
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile '' -ContentProfileSource 'WebNotFound' -ContentProfileVersion $null) | Should Be $true
    }

    It 'returns $true with -FullContent even when a profile or marker exists' {
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile 'Web profile' -ContentProfileSource 'Web') -FullContent | Should Be $true
        Test-WebProfileRequired -Book (Get-TestNoTextBook -ContentProfile '' -ContentProfileSource 'WebNotFound') -FullContent | Should Be $true
    }

    It 'returns $false for a book with text' {
        Test-WebProfileRequired -Book (Get-TestExportBook) -FullContent | Should Be $false
    }

    It 'returns $false without UUID or ContentHash, because the profile could not be stored' {
        $noUuid = Get-TestNoTextBook
        $noUuid.Uuid = $null
        $noHash = Get-TestNoTextBook
        $noHash.ContentHash = ''
        Test-WebProfileRequired -Book $noUuid | Should Be $false
        Test-WebProfileRequired -Book $noHash | Should Be $false
    }
}

Describe 'ConvertTo-WebProfileRecord' {
    It 'holds the identity metadata and the description, but no tags, hash, or UUID' {
        $record = ConvertTo-WebProfileRecord -Book (Get-TestNoTextBook)
        $record.Title | Should Be 'Manga 3'
        $record.IDs | Should Be 'isbn:9781234567897'
        $record.Description | Should Be 'Publisher description'
        $record.Year | Should Be 2020
        foreach ($key in @('Tags', 'ContentHash', 'Uuid', 'ContentProfile')) {
            $record.Contains($key) | Should Be $false
        }
    }
}

Describe 'ConvertFrom-WebProfileResponse' {
    It 'returns the trimmed profile' {
        (ConvertFrom-WebProfileResponse -RawText '{"ContentProfile": " Manga profile "}').ContentProfile | Should BeExactly 'Manga profile'
    }

    It 'accepts a response in a markdown code block' {
        (ConvertFrom-WebProfileResponse -RawText ('```json' + "`n" + '{"ContentProfile":"P"}' + "`n" + '```')).ContentProfile | Should Be 'P'
    }

    It 'returns an empty profile for an empty string or null (work not identified)' {
        (ConvertFrom-WebProfileResponse -RawText '{"ContentProfile": ""}').ContentProfile | Should BeExactly ''
        (ConvertFrom-WebProfileResponse -RawText '{"ContentProfile": null}').ContentProfile | Should BeExactly ''
    }

    It 'returns $null for text without JSON, an array, or an object without ContentProfile' {
        ConvertFrom-WebProfileResponse -RawText 'no json' | Should Be $null
        ConvertFrom-WebProfileResponse -RawText '[{"ContentProfile":"P"}]' | Should Be $null
        ConvertFrom-WebProfileResponse -RawText '{"Profile":"P"}' | Should Be $null
    }
}

Describe 'Add-TokenUsage' {
    It 'adds the token counts and marks the counter as available' {
        $counter = [pscustomobject]@{ Available = $false; PromptTokens = [int64]1; CompletionTokens = [int64]2; TotalTokens = [int64]3 }
        Add-TokenUsage -Counter $counter -TokenUsage ([pscustomobject]@{ PromptTokens = 10; CompletionTokens = 20; TotalTokens = 30 })
        $counter.Available | Should Be $true
        $counter.PromptTokens | Should Be 11
        $counter.CompletionTokens | Should Be 22
        $counter.TotalTokens | Should Be 33
    }

    It 'leaves the counter unchanged for $null' {
        $counter = [pscustomobject]@{ Available = $false; PromptTokens = [int64]0; CompletionTokens = [int64]0; TotalTokens = [int64]0 }
        Add-TokenUsage -Counter $counter -TokenUsage $null
        $counter.Available | Should Be $false
    }
}

Describe 'Request-WebContentProfile' {
    Mock Start-Sleep { }
    Mock Write-ScriptLog { }

    It 'sends the tag definitions and metadata with the web profile prompt and the google_search tool' {
        Mock Invoke-GeminiRequest { [pscustomobject]@{ Text = '{"ContentProfile":"Web profile"}'; TokenUsage = [pscustomobject]@{ PromptTokens = 10; CompletionTokens = 5; TotalTokens = 15 }; SearchQueryCount = 2; Sources = @([pscustomobject]@{ Title = 'a'; Url = 'https://a.example/1' }) } }
        $counter = Get-TestUsageCounter
        $result = Request-WebContentProfile -Book (Get-TestNoTextBook) -TagDefinitions '[{"Tag":"Manga"}]' -UsageCounter $counter
        $result.ContentProfile | Should Be 'Web profile'
        $result.SearchQueryCount | Should Be 2
        @($result.Sources).Count | Should Be 1
        $counter.TotalTokens | Should Be 15
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 1 -Exactly -ParameterFilter {
            $UseGoogleSearch -and $SystemInstruction -eq 'Web profile prompt' -and $PayloadText -match '\[\{"Tag":"Manga"\}\]' -and $PayloadText -match 'isbn:9781234567897' -and $PayloadText -match 'Publisher description'
        }
    }

    It 'retries an invalid response and adds the searches of all attempts' {
        $script:webAttempt = 0
        Mock Invoke-GeminiRequest {
            $script:webAttempt++
            $text = if ($script:webAttempt -eq 1) { 'not json' } else { '{"ContentProfile":""}' }
            [pscustomobject]@{ Text = $text; TokenUsage = $null; SearchQueryCount = 1; Sources = @() }
        }
        $result = Request-WebContentProfile -Book (Get-TestNoTextBook) -TagDefinitions '[]' -UsageCounter (Get-TestUsageCounter)
        $result.ContentProfile | Should BeExactly ''
        $result.SearchQueryCount | Should Be 2
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 2 -Exactly
    }

    It 'returns a $null profile when the API request fails' {
        Mock Invoke-GeminiRequest { $null }
        $result = Request-WebContentProfile -Book (Get-TestNoTextBook) -TagDefinitions '[]' -UsageCounter (Get-TestUsageCounter)
        $result.ContentProfile | Should Be $null
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 1 -Exactly
    }

    It 'returns a $null profile after the last invalid response' {
        Mock Invoke-GeminiRequest { [pscustomobject]@{ Text = 'not json'; TokenUsage = $null; SearchQueryCount = 1; Sources = @() } }
        $result = Request-WebContentProfile -Book (Get-TestNoTextBook) -TagDefinitions '[]' -UsageCounter (Get-TestUsageCounter)
        $result.ContentProfile | Should Be $null
        $result.SearchQueryCount | Should Be 3
        Assert-MockCalled Invoke-GeminiRequest -Scope It -Times 3 -Exactly
    }
}

Describe 'Add-BookContentProfile' {
    It 'adds the profile fields with the current version to the export record' {
        $book = Get-TestNoTextBook -ContentProfileVersion $null
        Add-BookContentProfile -Book $book -ProfileData ([pscustomobject]@{ ContentProfile = 'Web profile'; Source = 'Web'; Sources = @() })
        $book.ContentProfile | Should Be 'Web profile'
        $book.ContentProfileSource | Should Be 'Web'
        $book.ContentProfileVersion | Should Be 1
        Test-ContentProfile -Book $book | Should Be $true
    }
}

Describe 'Web profile workflow' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $geminiCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-GeminiRequest' })

    It 'uses the google_search tool only in the web profile request' {
        $searchCalls = @($geminiCalls | Where-Object { $_.Extent.Text -match '-UseGoogleSearch' })
        $searchCalls.Count | Should Be 1
        $function = $searchCalls[0].Parent
        while ($null -ne $function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $function = $function.Parent
        }
        $function.Name | Should Be 'Request-WebContentProfile'
    }

    It 'requires the web profile prompt file' {
        $scriptAst.Extent.Text | Should Match '-ChildPath "02-CalibreWebProfile-Prompt\.txt"'
        (Test-Path -LiteralPath (Join-Path -Path $projectRoot -ChildPath '02-CalibreWebProfile-Prompt.txt') -PathType Leaf) | Should Be $true
    }

    It 'stores the search query count in the token usage of the result file' {
        $scriptAst.Extent.Text | Should Match 'web_search_queries = \$fileSearchQueryCount'
    }
}

Describe 'Test-TagDefinitionBaselineUpdate' {
    It 'returns $true for a full-library export without error files' {
        $path = Join-Path -Path $TestDrive -ChildPath 'scope-full.json'
        Set-Content -LiteralPath $path -Value '{ "FullLibrary": true, "BookCount": 2326 }'
        Test-TagDefinitionBaselineUpdate -ScopePath $path -ErrorFileCount 0 | Should Be $true
    }

    It 'returns $false when a file ended with an error' {
        $path = Join-Path -Path $TestDrive -ChildPath 'scope-full-errors.json'
        Set-Content -LiteralPath $path -Value '{ "FullLibrary": true }'
        Test-TagDefinitionBaselineUpdate -ScopePath $path -ErrorFileCount 1 | Should Be $false
    }

    It 'returns $false for a partial export' {
        $path = Join-Path -Path $TestDrive -ChildPath 'scope-partial.json'
        Set-Content -LiteralPath $path -Value '{ "FullLibrary": false }'
        Test-TagDefinitionBaselineUpdate -ScopePath $path -ErrorFileCount 0 | Should Be $false
    }

    It 'returns $false for a missing, corrupt, or incomplete scope file' {
        Test-TagDefinitionBaselineUpdate -ScopePath (Join-Path -Path $TestDrive -ChildPath 'no-scope.json') -ErrorFileCount 0 | Should Be $false
        $corrupt = Join-Path -Path $TestDrive -ChildPath 'scope-corrupt.json'
        Set-Content -LiteralPath $corrupt -Value '{ not json'
        Test-TagDefinitionBaselineUpdate -ScopePath $corrupt -ErrorFileCount 0 | Should Be $false
        $incomplete = Join-Path -Path $TestDrive -ChildPath 'scope-incomplete.json'
        Set-Content -LiteralPath $incomplete -Value '{ "BookCount": 5 }'
        Test-TagDefinitionBaselineUpdate -ScopePath $incomplete -ErrorFileCount 0 | Should Be $false
    }

    It 'returns $false when FullLibrary is a string instead of a boolean' {
        $path = Join-Path -Path $TestDrive -ChildPath 'scope-string.json'
        Set-Content -LiteralPath $path -Value '{ "FullLibrary": "yes" }'
        Test-TagDefinitionBaselineUpdate -ScopePath $path -ErrorFileCount 0 | Should Be $false
    }
}

Describe 'Tag definition baseline update' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $saveCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Save-TagDefinitionBaseline' })

    It 'saves the baseline once, only after the full-library check' {
        $saveCalls.Count | Should Be 1
        $condition = $saveCalls[0].Parent
        while ($null -ne $condition -and $condition -isnot [System.Management.Automation.Language.IfStatementAst]) {
            $condition = $condition.Parent
        }
        $condition.Clauses[0].Item1.Extent.Text | Should Match 'Test-TagDefinitionBaselineUpdate -ScopePath \$ScopePath -ErrorFileCount \$errorFileCount'
    }

    It 'counts parse errors and API errors as error files' {
        @([regex]::Matches($scriptAst.Extent.Text, '\$errorFileCount\+\+')).Count | Should Be 2
    }
}

Describe 'Content profile workflow' {
    It 'has an optional switch parameter FullContent' {
        $parameter = (Get-Command -Name $scriptPath).Parameters['FullContent']
        $parameter.ParameterType | Should Be ([switch])
    }

    It 'sends the book data and the tag definitions as compact JSON' {
        $scriptAst.Extent.Text | Should Match '\$bookAnalysisInput = ConvertTo-CompactJson'
        $scriptAst.Extent.Text | Should Match '\$tagContent = ConvertTo-CompactJson'
    }

    It 'stores the profiles in the 01-Cache folder' {
        $scriptAst.Extent.Text | Should Match '-ChildPath "01-Cache"'
    }
}

Describe 'Logging setup' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $startLogCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Start-Log' })
    $loggingImports = @($commands | Where-Object { $_.GetCommandName() -eq 'Import-Module' -and $_.Extent.Text -match '\bDonGrobione\.Logging\b' })

    It 'starts a log session' {
        $startLogCalls.Count | Should BeGreaterThan 0
    }

    It 'turns off size-based rotation in every Start-Log call' {
        foreach ($call in $startLogCalls) {
            $call.Extent.Text | Should Match '-MaxFileSizeMB\s+0\b'
        }
    }

    It 'requires DonGrobione.Logging 2.2.0 or later, which supports -MaxFileSizeMB' {
        $loggingImports.Count | Should Be 1
        $loggingImports[0].Extent.Text | Should Match '-MinimumVersion\s+2\.2\.0\b'
    }

    It 'imports DonGrobione.Logging without -Force, which would reset a running log session' {
        $loggingImports[0].Extent.Text | Should Not Match '-Force\b'
    }
}