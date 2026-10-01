<#
.SYNOPSIS
    Pester tests for the helper functions in Invoke-CalibreToolsPipeline.ps1.

.DESCRIPTION
    Covers the ChangedWithinDays script parameter, Test-BookExportFile, which decides whether the pipeline continues after the book export, and Get-StepScriptParameter, which forwards the parameter to the book export. The pipeline runs all steps when it is executed, so the tests parse it and load only the function definitions under test. The parameter metadata is read with Get-Command, which does not run the script.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Invoke-CalibreToolsPipeline.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath 'Invoke-CalibreToolsPipeline.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
foreach ($functionName in @('Test-BookExportFile', 'Get-StepScriptParameter')) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Invoke-CalibreToolsPipeline.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }

    It 'has an optional integer parameter ChangedWithinDays limited to 0..36500' {
        $parameter = (Get-Command -Name $scriptPath).Parameters['ChangedWithinDays']
        $parameter.ParameterType | Should Be ([int])
        $range = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
        $range.MinRange | Should Be 0
        $range.MaxRange | Should Be 36500
        @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should Be 0
    }
}

Describe 'Test-BookExportFile' {
    It 'returns $false when the export folder does not exist' {
        Test-BookExportFile -ExportDirectory (Join-Path -Path $TestDrive -ChildPath 'missing') | Should Be $false
    }

    It 'returns $false when the folder contains only the tag export' {
        $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'tags-only'
        New-Item -Path $exportDirectory -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '02-Export-CalibreTags_2026-10-01_15-40-59.json') -Value '[]'
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '.gitkeep') -Value ''
        Test-BookExportFile -ExportDirectory $exportDirectory | Should Be $false
    }

    It 'returns $true when a book export file exists' {
        $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'books'
        New-Item -Path $exportDirectory -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '01-Export-CalibreBooks_01_2026-10-01_15-40-56.json') -Value '[]'
        Test-BookExportFile -ExportDirectory $exportDirectory | Should Be $true
    }

    It 'ignores folders that match the book export pattern' {
        $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'folder-only'
        New-Item -Path (Join-Path -Path $exportDirectory -ChildPath '01-Export-CalibreBooks_folder.json') -ItemType Directory -Force | Out-Null
        Test-BookExportFile -ExportDirectory $exportDirectory | Should Be $false
    }
}

Describe 'Get-StepScriptParameter' {
    It 'forwards ChangedWithinDays to the book export' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{ ChangedWithinDays = 7 }
        $result['ChangedWithinDays'] | Should Be 7
    }

    It 'forwards ChangedWithinDays 0 to export all books' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{ ChangedWithinDays = 0 }
        $result.ContainsKey('ChangedWithinDays') | Should Be $true
        $result['ChangedWithinDays'] | Should Be 0
    }

    It 'returns no parameters for the book export when ChangedWithinDays was not given' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{}
        $result.Count | Should Be 0
    }

    It 'returns no parameters for the other steps' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreTags.ps1' -PipelineParameters @{ ChangedWithinDays = 7 }
        $result.Count | Should Be 0
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