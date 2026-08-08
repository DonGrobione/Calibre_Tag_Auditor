<#
.SYNOPSIS
    Run all Calibre Tools scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and CSV conversion scripts in order.
    Each script must complete successfully before the next one starts.

.NOTES
    Version: 1.1
#>

$ErrorActionPreference = 'Stop'

try {
    $llmResultDir = Join-Path -Path $PSScriptRoot -ChildPath "02-LLM-Result"
    if (Test-Path -Path $llmResultDir) {
        $jsonFiles = Get-ChildItem -Path $llmResultDir -Filter "*.json" -File
        if ($jsonFiles.Count -gt 0) {
            Write-Host "Cleaning $($jsonFiles.Count) JSON file(s) from 02-LLM-Result..." -ForegroundColor Yellow
            $jsonFiles | Remove-Item -Force
            Write-Host "Done." -ForegroundColor Green
            Write-Host ""
        }
    }

    $scripts = @(
        "01-Export-CalibreBooks.ps1",
        "01-Export-CalibreTags.ps1",
        "02-Process-CalibreDataWithLLM.ps1",
        "03-Convert-LLMResultsToCsv.ps1"
    )

    foreach ($script in $scripts) {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $script
        Write-Host "=== Starting: $script ===" -ForegroundColor Cyan
        & $scriptPath
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script '$script' exited with code $LASTEXITCODE. Pipeline aborted."
        }
        Write-Host "=== Completed: $script ===" -ForegroundColor Green
        Write-Host ""
    }

    Write-Host "--- Pipeline complete ---" -ForegroundColor Cyan
}
catch {
    Write-Error $_.Exception.Message
    throw
}
