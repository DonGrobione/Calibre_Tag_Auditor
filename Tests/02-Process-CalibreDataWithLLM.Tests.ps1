<#
.SYNOPSIS
    Pester tests for the Gemini API functions in 02-Process-CalibreDataWithLLM.ps1.

.DESCRIPTION
    Covers Get-GeminiApiKey, Repair-MojibakeText, Get-TokenUsageFromResponse, Get-GeminiResponseText, ConvertFrom-Utf8JsonResponse, Invoke-GeminiRequest (UTF-8 request and response bytes), and Convert-ResponseTextToResultObject. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. Invoke-WebRequest and Start-Sleep are mocked; no request reaches the Gemini API.
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
    'Get-GeminiApiKey', 'Repair-MojibakeText', 'Get-ErrorMessageFromException', 'Get-ErrorBodyTextFromException',
    'Get-TokenUsageFromResponse', 'Get-GeminiResponseText', 'Invoke-GeminiRequest',
    'Repair-JsonArrayFormatting', 'Get-JsonText', 'ConvertFrom-Utf8JsonResponse', 'Get-BookIdentityKey', 'Get-UniqueBookCount', 'Convert-ResponseTextToResultObject'
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

Describe 'Repair-MojibakeText' {
    # The test strings are built from character codes, so this file does not depend on how an editor shows the garbled characters.
    $uUmlaut = [string][char]0xFC
    $garbledUUmlaut = [string][char]0xC3 + [char]0xBC
    $doubleGarbledUUmlaut = [string][char]0xC3 + [char]0x0192 + [char]0xC2 + [char]0xBC
    $rightQuote = [string][char]0x2019
    $garbledRightQuote = [string][char]0xE2 + [char]0x20AC + [char]0x2122
    $enDash = [string][char]0x2013
    $garbledEnDash = [string][char]0xE2 + [char]0x20AC + [char]0x201C
    $garbledLatin1EnDash = [string][char]0xE2 + [char]0x80 + [char]0x93
    $sharpS = [string][char]0xDF
    $leftLowQuote = [string][char]0x201E
    $leftQuote = [string][char]0x201C

    It 'repairs a garbled umlaut' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung" | Should BeExactly "Begr$($uUmlaut)ndung"
    }

    It 'repairs garbled umlauts next to correct umlauts' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung f$($uUmlaut)r" | Should BeExactly "Begr$($uUmlaut)ndung f$($uUmlaut)r"
    }

    It 'keeps typographic characters that are not garbled' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung $enDash it$($rightQuote)s" | Should BeExactly "Begr$($uUmlaut)ndung $enDash it$($rightQuote)s"
    }

    It 'repairs garbled typographic characters from Windows-1252 and ISO-8859-1' {
        Repair-MojibakeText -Text "it$($garbledRightQuote)s" | Should BeExactly "it$($rightQuote)s"
        Repair-MojibakeText -Text "A $garbledEnDash B" | Should BeExactly "A $enDash B"
        Repair-MojibakeText -Text "A $garbledLatin1EnDash B" | Should BeExactly "A $enDash B"
    }

    It 'repairs text that was garbled twice' {
        Repair-MojibakeText -Text "Begr$($doubleGarbledUUmlaut)ndung" | Should BeExactly "Begr$($uUmlaut)ndung"
    }

    It 'leaves correct text with a-circumflex, a-tilde, and capital A-tilde unchanged' {
        $text = "liver p$([char]0xE2)t$([char]0xE9), S$([char]0xE3)o Paulo, S$([char]0xC3)O PAULO"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'leaves a word ending in sharp s before a closing German quote unchanged' {
        $text = "$($leftLowQuote)Gro$($sharpS)$($leftQuote)"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'keeps a sequence that is not valid UTF-8' {
        $text = "A$([char]0xC3) B"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'returns empty and whitespace text unchanged' {
        Repair-MojibakeText -Text '' | Should BeExactly ''
        Repair-MojibakeText -Text '  ' | Should BeExactly '  '
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