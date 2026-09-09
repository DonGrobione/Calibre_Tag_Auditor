<#
.SYNOPSIS
    Run all Calibre Tag Auditor scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and ODS conversion scripts in order. Each script must complete successfully before the next one starts.
    On failure, the error is shown and the script waits for Enter before exit.
    Script output (info, warnings, and errors) is written both to terminal and to the central log via Modules\Write-Log.psm1. Every child script already logs and rethrows its own errors, so on failure the pipeline only prints the error to the terminal (never writes a second logfile entry) and exits with code 1 instead of rethrowing, avoiding stray failure entries from the host's own error handling.
    On successful completion, the pipeline prints the total prompt, completion, and combined token usage across all LLM result files.

.NOTES
    Version: 1.7
#>

$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
$ClearLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Clear-LogFile.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '.\\Modules\\Write-Log.psm1'"
}
if (-not (Test-Path -Path $ClearLogModulePath)) {
    throw "Required module not found: '.\\Modules\\Clear-LogFile.psm1'"
}

Import-Module -Name $WriteLogModulePath -Force
Import-Module -Name $ClearLogModulePath -Force

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

# Clear the console to keep the output readable for each run.
clear-Host

# Stop execution immediately on errors.
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

try {
    # Clean old log entries before the pipeline starts.
    try {
        Push-Location -Path $PSScriptRoot
        Clear-LogFile
    }
    catch {
        Write-Warning "Log cleanup failed: $($_.Exception.Message). Pipeline continues."
    }
    finally {
        Pop-Location
    }

    # Define the order of scripts to run.
    $scripts = @(
        "01-Export-CalibreBooks.ps1",
        "01-Export-CalibreTags.ps1",
        "02-Process-CalibreDataWithLLM.ps1",
        "03-Convert-LLMResults2ODS.ps1"
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

    $totalPromptTokens = [int64]0
    $totalCompletionTokens = [int64]0
    $llmResultFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot "02-LLM-Result") -Filter "LLM-Result_*.json" -File -ErrorAction SilentlyContinue
    foreach ($resultFile in $llmResultFiles) {
        $result = Get-Content -Path $resultFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $result.token_usage) {
            if ($null -ne $result.token_usage.prompt_tokens) {
                $totalPromptTokens += [int64]$result.token_usage.prompt_tokens
            }
            if ($null -ne $result.token_usage.completion_tokens) {
                $totalCompletionTokens += [int64]$result.token_usage.completion_tokens
            }
        }
    }
    $totalTokens = $totalPromptTokens + $totalCompletionTokens

    # Print a summary when the pipeline finishes successfully.
    Write-Host "--- Pipeline complete ---" -ForegroundColor Cyan
    $endTime = Get-Date
    $duration = $endTime - $startTime
    Write-Host "Start:    $($startTime.ToString('HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "End:      $($endTime.ToString('HH:mm:ss'))" -ForegroundColor Gray
    Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Prompt tokens (input, all files):       $($totalPromptTokens.ToString('N0'))" -ForegroundColor Gray
    Write-Host "Completion tokens (output, all files):  $($totalCompletionTokens.ToString('N0'))" -ForegroundColor Gray
    Write-Host "Tokens total (Prompt + Completion):     $($totalTokens.ToString('N0'))" -ForegroundColor Gray
}
catch {
    # Report the error and stop execution. Every child script already logs and
    # rethrows its own errors, so this catch only prints to terminal (with -ErrorAction
    # Continue, so it cannot itself abort before the "Press Enter" prompt below) and
    # never writes a second logfile entry for the same failure.
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

    Microsoft.PowerShell.Utility\Write-Error $errorMessage -ErrorAction Continue
    Write-Host "Press Enter to close this window after reviewing the error..." -ForegroundColor Yellow
    Read-Host | Out-Null
    # Exit the orchestrator directly instead of rethrowing, so no uncaught
    # exception reaches the host and triggers spurious failure log entries.
    exit 1
}
finally {
    Remove-Item -Path Alias:Write-Host, Alias:Write-Warning, Alias:Write-Error -ErrorAction SilentlyContinue
}
