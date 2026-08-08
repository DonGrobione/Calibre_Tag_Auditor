<#
.SYNOPSIS
    Run all Calibre Tools scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and CSV conversion scripts in order.
    Each script must complete successfully before the next one starts.

.NOTES
    Version: 1.1
#>

# Clear the console to keep the output readable for each run.
clear-Host

# Stop execution immediately on errors.
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

try {
    # Set the target folder for LLM result files.
    $llmResultDir = Join-Path -Path $PSScriptRoot -ChildPath "02-LLM-Result"

    # Remove old JSON result files from a previous run so only current data remains.
    if (Test-Path -Path $llmResultDir) {
        $jsonFiles = Get-ChildItem -Path $llmResultDir -Filter "*.json" -File
        if ($jsonFiles.Count -gt 0) {
            Write-Host "Cleaning $($jsonFiles.Count) JSON file(s) from 02-LLM-Result..." -ForegroundColor Yellow
            $jsonFiles | Remove-Item -Force
            Write-Host "Done." -ForegroundColor Green
            Write-Host ""
        }
    }

    # Define the order of scripts to run.
    $scripts = @(
        "01-Export-CalibreBooks.ps1",
        "01-Export-CalibreTags.ps1",
        "02-Process-CalibreDataWithLLM.ps1",
        "03-Convert-LLMResultsToCsv.ps1"
    )

    # Run each script in sequence.
    foreach ($script in $scripts) {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $script
        Write-Host "=== Starting: $script ===" -ForegroundColor Cyan
        & $scriptPath

        # Check whether the script completed successfully.
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script '$script' exited with code $LASTEXITCODE. Pipeline aborted."
        }

        Write-Host "=== Completed: $script ===" -ForegroundColor Green
        Write-Host ""
    }

    # Print a summary when the pipeline finishes successfully.
    Write-Host "--- Pipeline complete ---" -ForegroundColor Cyan
    $endTime = Get-Date
    $duration = $endTime - $startTime
    Write-Host "Start:    $($startTime.ToString('HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "End:      $($endTime.ToString('HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
}
catch {
    # Report the error and stop execution.
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

    Write-Error $errorMessage
    throw
}
