<#
.SYNOPSIS
    Pester tests for the helper functions in Invoke-CalibreToolsPipeline.ps1.

.DESCRIPTION
    Covers Test-BookExportFile, which decides whether the pipeline continues after the book export. The pipeline runs all steps when it is executed, so the tests parse it and load only the function definitions under test.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Invoke-CalibreToolsPipeline.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath 'Invoke-CalibreToolsPipeline.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$definition = $scriptAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-BookExportFile'
    }, $true)
. ([scriptblock]::Create($definition.Extent.Text))

Describe 'Invoke-CalibreToolsPipeline.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
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
