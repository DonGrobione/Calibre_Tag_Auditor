<#
.SYNOPSIS
    Pester tests for the Mistral agent functions in 02-Process-CalibreDataWithLLM.ps1.

.DESCRIPTION
    Covers Test-MistralAgent, Remove-MistralAgent, and New-MistralAgent. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. Invoke-RestMethod is mocked; no request reaches the Mistral API.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\02-Process-CalibreDataWithLLM.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '02-Process-CalibreDataWithLLM.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @('Test-MistralAgent', 'Remove-MistralAgent', 'New-MistralAgent', 'Get-ErrorMessageFromException', 'Get-ErrorBodyTextFromException')
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

$script:ApiKey = 'test-api-key'
$script:AgentsUrl = 'https://api.example.invalid/v1/agents'
$script:Model = 'test-model'
$script:PromptSystem = 'Test prompt'
$script:ApiTimeoutSec = 5

Describe '02-Process-CalibreDataWithLLM.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }
}

Describe 'Test-MistralAgent' {
    It 'returns $true when the agent can be retrieved' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-1' } }
        Test-MistralAgent -AgentId 'agent-1' | Should Be $true
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 1 -Exactly -ParameterFilter { $Method -eq 'Get' -and $Uri -eq 'https://api.example.invalid/v1/agents/agent-1' }
    }

    It 'returns $false when the request fails' {
        Mock Invoke-RestMethod { throw 'Not found' }
        Test-MistralAgent -AgentId 'agent-1' | Should Be $false
    }
}

Describe 'Remove-MistralAgent' {
    It 'does nothing for an empty agent ID' {
        Mock Invoke-RestMethod { }
        Remove-MistralAgent -AgentId ''
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 0 -Exactly
    }

    It 'does not delete when the agent no longer exists' {
        Mock Invoke-RestMethod { throw 'Not found' } -ParameterFilter { $Method -eq 'Get' }
        Mock Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Delete' }
        Remove-MistralAgent -AgentId 'agent-1'
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 0 -Exactly -ParameterFilter { $Method -eq 'Delete' }
    }

    It 'deletes an existing agent' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-1' } } -ParameterFilter { $Method -eq 'Get' }
        Mock Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Delete' }
        Remove-MistralAgent -AgentId 'agent-1'
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 1 -Exactly -ParameterFilter { $Method -eq 'Delete' -and $Uri -eq 'https://api.example.invalid/v1/agents/agent-1' }
    }

    It 'does not delete with -WhatIf' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-1' } } -ParameterFilter { $Method -eq 'Get' }
        Mock Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Delete' }
        Remove-MistralAgent -AgentId 'agent-1' -WhatIf
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 0 -Exactly -ParameterFilter { $Method -eq 'Delete' }
    }

    It 'logs a warning instead of failing when the deletion fails' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-1' } } -ParameterFilter { $Method -eq 'Get' }
        Mock Invoke-RestMethod { throw 'Server error' } -ParameterFilter { $Method -eq 'Delete' }
        Mock Write-ScriptLog { }
        { Remove-MistralAgent -AgentId 'agent-1' } | Should Not Throw
        Assert-MockCalled Write-ScriptLog -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'New-MistralAgent' {
    $script:AgentIdFile = Join-Path -Path $TestDrive -ChildPath 'Mistral_Agent_Id.txt'

    It 'creates the agent, stores its ID, and returns it' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-new' } } -ParameterFilter { $Method -eq 'Post' }
        New-MistralAgent | Should Be 'agent-new'
        (Get-Content -LiteralPath $script:AgentIdFile -Raw).Trim() | Should Be 'agent-new'
    }

    It 'sends the model and the prompt as agent instructions' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-new' } } -ParameterFilter { $Method -eq 'Post' }
        $null = New-MistralAgent
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 1 -Exactly -ParameterFilter {
            $body = $Body | ConvertFrom-Json
            $body.model -eq 'test-model' -and $body.instructions -eq 'Test prompt'
        }
    }

    It 'returns $null and sends no request with -WhatIf' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 'agent-new' } }
        New-MistralAgent -WhatIf | Should Be $null
        Assert-MockCalled Invoke-RestMethod -Scope It -Times 0 -Exactly
    }

    It 'throws when the response contains no agent ID' {
        Mock Invoke-RestMethod { [pscustomobject]@{ name = 'no id' } } -ParameterFilter { $Method -eq 'Post' }
        { New-MistralAgent } | Should Throw 'Agent creation failed: invalid agent ID in response.'
    }
}
