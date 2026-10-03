<#
.SYNOPSIS
    Pester tests for the source of 01-Export-CalibreTags.ps1.

.DESCRIPTION
    The script runs its whole workflow when it is executed (Calibre's calibre-debug.exe and a temporary Python script), so the tests only parse it. They check that it parses without errors, that it compares the exported tag definitions with the baseline of the last full-library audit (and saves a baseline only when none exists), and that it imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\01-Export-CalibreTags.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '01-Export-CalibreTags.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)

Describe '01-Export-CalibreTags.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }
}

Describe 'Tag definition change check' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $saveCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Save-TagDefinitionBaseline' })
    $compareCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Compare-TagDefinition' })

    It 'imports the Calibre.TagDefinitions module' {
        $scriptAst.Extent.Text | Should Match 'Modules\\Calibre\.TagDefinitions\.psd1'
    }

    It 'uses the baseline file 01-Cache\TagDefinitions.json' {
        $scriptAst.Extent.Text | Should Match '01-Cache\\TagDefinitions\.json'
    }

    It 'saves a baseline only when none exists' {
        $saveCalls.Count | Should Be 1
        $condition = $saveCalls[0].Parent
        while ($null -ne $condition -and $condition -isnot [System.Management.Automation.Language.IfStatementAst]) {
            $condition = $condition.Parent
        }
        $condition.Clauses[0].Item1.Extent.Text | Should Match '\$null -eq \$Baseline'
    }

    It 'compares the exported definitions with the baseline and logs changes as warnings' {
        $compareCalls.Count | Should Be 1
        $scriptAst.Extent.Text | Should Match 'Write-ScriptLog -Level WARN -Message \$Line'
    }

    It 'checks the definitions after the export succeeded' {
        $exportCheck = $scriptAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match 'SUCCESS'
            }, $true)
        $exportCheck.Extent.EndOffset -lt $compareCalls[0].Extent.StartOffset | Should Be $true
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