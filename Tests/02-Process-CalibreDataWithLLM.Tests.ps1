<#
.SYNOPSIS
    Pester tests for the Gemini API functions in 02-Process-CalibreDataWithLLM.ps1.

.DESCRIPTION
    Covers Get-GeminiApiKey, Get-TokenUsageFromResponse, Get-GeminiResponseText, Invoke-GeminiRequest, and Convert-ResponseTextToResultObject. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. Invoke-RestMethod and Start-Sleep are mocked; no request reaches the Gemini API.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\02-Process-CalibreDataWithLLM.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '02-Process-CalibreDataWithLLM.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @(
    'Get-GeminiApiKey', 'Repair-MojibakeText', 'Get-ErrorMessageFromException', 'Get-ErrorBodyTextFromException',
    'Get-TokenUsageFromResponse', 'Get-GeminiResponseText', 'Invoke-GeminiRequest',
    'Repair-JsonArrayFormatting', 'Get-JsonText', 'Get-BookIdentityKey', 'Get-UniqueBookCount', 'Convert-ResponseTextToResultObject'
)
foreach ($functionName in $functionNames) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Stands in for the Calibre.Console logging helper so the tests write no log file.
function Write-ScriptLog {
    param($Message, $Level, $ErrorRecord)
    $null = $Message, $Level, $ErrorRecord
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
$script:ApiTimeoutSec = 5
$script:MaxRequestRetries = 3
$script:RateLimitRetryBaseSeconds = 1
$script:ServiceUnavailableRetryBaseSeconds = 1
$script:ServiceUnavailableRetryMaxSeconds = 1
$script:GatewayTimeoutRetryIntervalSeconds = 1

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

Describe 'Invoke-GeminiRequest' {
    Mock Start-Sleep { }

    It 'sends model, system instruction, input, and thinking level with the API key header' {
        Mock Invoke-RestMethod { Get-TestInteractionResponse -Text 'ok' }
        $result = Invoke-GeminiRequest -PayloadText 'book data'
        $result.Text | Should Be 'ok'
        $result.TokenUsage.TotalTokens | Should Be 150
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 1 -Exactly -ParameterFilter {
            $sent = $Body | ConvertFrom-Json
            $Uri -eq 'https://api.example.invalid/v1beta/interactions' -and $Method -eq 'Post' -and
            $Headers['x-goog-api-key'] -eq 'test-api-key' -and
            $sent.model -eq 'test-model' -and $sent.system_instruction -eq 'Test prompt' -and $sent.input -eq 'book data' -and
            $sent.generation_config.thinking_level -eq 'medium' -and $sent.store -eq $false
        }
    }

    It 'retries after a rate limit (429) and returns the later response' {
        $script:callCount = 0
        Mock Invoke-RestMethod {
            $script:callCount++
            if ($script:callCount -eq 1) {
                $exception = New-Object System.Exception 'Too many requests'
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [pscustomobject]@{ value__ = 429 } })
                throw $exception
            }
            Get-TestInteractionResponse -Text 'second'
        }
        (Invoke-GeminiRequest -PayloadText 'book data').Text | Should Be 'second'
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 2 -Exactly
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly
    }

    It 'returns $null and stores the error for a non-retryable error' {
        Mock Invoke-RestMethod { throw 'Bad request' }
        Invoke-GeminiRequest -PayloadText 'book data' | Should Be $null
        $script:LastApiErrorMessage | Should Match 'Bad request'
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 1 -Exactly
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
}
