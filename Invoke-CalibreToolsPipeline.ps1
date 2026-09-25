<#
.SYNOPSIS
    Run all Calibre Tag Auditor scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and ODS conversion scripts in order. Each script must complete successfully before the next one starts.
    On failure, the error is shown and the script waits for Enter before exit.
    The pipeline starts one DonGrobione.Logging (>= 1.2.0) log session (log directory 'Calibre_Tag_Auditor') that all child scripts share, and stops it in a finally block. Script output (info, warnings, and errors) is written both to terminal and to that log file via Write-ScriptLog from Modules\Calibre.Console.psm1. Log rotation is handled by Start-Log. Every child script already logs and rethrows its own errors, so on failure the pipeline only prints the error to the terminal (never writes a second logfile entry) and exits with code 1 instead of rethrowing, avoiding stray failure entries from the host's own error handling.
    On successful completion, the pipeline prints the total prompt, completion, and combined token usage across all LLM result files.

.NOTES
    Version: 1.8
#>

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 1.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psm1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psm1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

# Clear the console to keep the output readable for each run.
clear-Host

# Stop execution immediately on errors.
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Start the log session shared by all child scripts.
Start-Log -LogDirectory 'Calibre_Tag_Auditor'

try {
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
        Write-ScriptLog "=== Starting: $script ==="
        & $scriptPath

        # Check whether the script completed successfully.
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script '$script' exited with code $LASTEXITCODE. Pipeline aborted."
        }

        Write-ScriptLog "=== Completed: $script ==="
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
    Write-ScriptLog "--- Pipeline complete ---"
    $endTime = Get-Date
    $duration = $endTime - $startTime
    Write-ScriptLog "Start:    $($startTime.ToString('HH:mm:ss'))"
    Write-ScriptLog "End:      $($endTime.ToString('HH:mm:ss'))"
    Write-ScriptLog "Duration: $($duration.ToString('hh\:mm\:ss'))"
    Write-Host ""
    Write-ScriptLog "Prompt tokens (input, all files):       $($totalPromptTokens.ToString('N0'))"
    Write-ScriptLog "Completion tokens (output, all files):  $($totalCompletionTokens.ToString('N0'))"
    Write-ScriptLog "Tokens total (Prompt + Completion):     $($totalTokens.ToString('N0'))"
}
catch {
    # Report the error and stop execution. Every child script already logs and rethrows its own errors, so this catch block only prints to terminal and never writes a second logfile entry for the same failure.
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
    # Exit the orchestrator directly instead of rethrowing, so no uncaught exception reaches the host and triggers spurious failure log entries.
    exit 1
}
finally {
    Stop-Log
}
