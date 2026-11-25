<#
.SYNOPSIS
    Pester tests for the Calibre.Storage module.

.DESCRIPTION
    Covers the manifest, Save-AtomicTextFile (UTF-8 without BOM, replace of an existing file, no temporary file left, -WhatIf), Test-ResultFileComplete (missing, truncated, error, and complete result files), and Get-ExportTimestamp (export and result file names).
    All files are created in the Pester TestDrive.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Calibre.Storage.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$manifestPath = Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Storage.psd1'
Import-Module -Name $manifestPath -Force

Describe 'Calibre.Storage manifest' {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    It 'exports exactly the public functions' {
        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should Be 'Get-ExportTimestamp,Save-AtomicTextFile,Test-ResultFileComplete'
    }

    It 'requires PowerShell 5.1, names the author, and has a semantic version' {
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
        $manifest.Author | Should Be 'DonGrobione'
        $manifest.Version.ToString() | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'defines tags and release notes and no wildcard exports' {
        @($manifest.PrivateData.PSData.Tags).Count -gt 0 | Should Be $true
        [string]::IsNullOrWhiteSpace($manifest.PrivateData.PSData.ReleaseNotes) | Should Be $false
        (Get-Content -LiteralPath $manifestPath -Raw) -match "ToExport\s*=\s*'\*'" | Should Be $false
    }
}

Describe 'Save-AtomicTextFile' {
    $path = Join-Path -Path $TestDrive -ChildPath 'LLM-Result_01_2026-11-01_07-31-38.json'
    $temporaryPath = [System.IO.Path]::ChangeExtension($path, '.tmp')
    $text = '{ "status": "success", "Title": "Begr' + [char]0xFC + 'ndung" }'

    It 'writes the content as UTF-8 without BOM and leaves no temporary file' {
        Save-AtomicTextFile -Path $path -Content $text
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should Not Be 0xEF
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | Should BeExactly $text
        Test-Path -LiteralPath $temporaryPath | Should Be $false
    }

    It 'replaces an existing file' {
        Save-AtomicTextFile -Path $path -Content '{ "status": "warning" }'
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | Should BeExactly '{ "status": "warning" }'
        Test-Path -LiteralPath $temporaryPath | Should Be $false
    }

    It 'writes nothing with -WhatIf' {
        $whatIfPath = Join-Path -Path $TestDrive -ChildPath 'whatif.json'
        Save-AtomicTextFile -Path $whatIfPath -Content '{}' -WhatIf
        Test-Path -LiteralPath $whatIfPath | Should Be $false
    }
}

Describe 'Test-ResultFileComplete' {
    It 'returns $false for a missing file' {
        Test-ResultFileComplete -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') | Should Be $false
    }

    It 'returns $false for a truncated file' {
        $path = Join-Path -Path $TestDrive -ChildPath 'truncated.json'
        Set-Content -LiteralPath $path -Value '{ "status": "success", "records": [ {'
        Test-ResultFileComplete -Path $path | Should Be $false
    }

    It 'returns $false for a result with status error or without status' {
        $errorPath = Join-Path -Path $TestDrive -ChildPath 'error.json'
        $noStatusPath = Join-Path -Path $TestDrive -ChildPath 'nostatus.json'
        Set-Content -LiteralPath $errorPath -Value '{ "status": "error", "records": [] }'
        Set-Content -LiteralPath $noStatusPath -Value '{ "records": [] }'
        Test-ResultFileComplete -Path $errorPath | Should Be $false
        Test-ResultFileComplete -Path $noStatusPath | Should Be $false
    }

    It 'returns $true for results with status success or warning, with or without BOM' {
        $successPath = Join-Path -Path $TestDrive -ChildPath 'success.json'
        $warningPath = Join-Path -Path $TestDrive -ChildPath 'warning.json'
        [System.IO.File]::WriteAllText($successPath, '{ "status": "success", "records": [] }', (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
        Save-AtomicTextFile -Path $warningPath -Content '{ "status": "warning", "records": [] }'
        Test-ResultFileComplete -Path $successPath | Should Be $true
        Test-ResultFileComplete -Path $warningPath | Should Be $true
    }
}

Describe 'Get-ExportTimestamp' {
    It 'returns the timestamp of a book export, tag export, or result file name' {
        Get-ExportTimestamp -FileName '01-Export-CalibreBooks_01_2026-11-25_10-42-34.json' | Should Be '2026-11-25_10-42-34'
        Get-ExportTimestamp -FileName '02-Export-CalibreTags_2026-11-25_10-41-00.json' | Should Be '2026-11-25_10-41-00'
        Get-ExportTimestamp -FileName 'LLM-Result_12_2026-11-25_10-42-34.json' | Should Be '2026-11-25_10-42-34'
    }

    It 'returns $null for names without a timestamp' {
        Get-ExportTimestamp -FileName 'Pipeline-RunState.json' | Should Be $null
        Get-ExportTimestamp -FileName 'LLM-Result_01_2026-11-25_10-42-34.json.tmp' | Should Be $null
        Get-ExportTimestamp -FileName '' | Should Be $null
    }
}

Remove-Module -Name Calibre.Storage -Force -ErrorAction SilentlyContinue
