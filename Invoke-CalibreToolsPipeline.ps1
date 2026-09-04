<#
.SYNOPSIS
    Run all Calibre Tag Auditor scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, CSV conversion, and ODS conversion scripts in order.
    Each script must complete successfully before the next one starts.
    On failure, the error is shown and the script waits for Enter before exit.
    Script output (info, warnings, and errors) is written both to terminal and
    to the central log via Modules\Write-Log.psm1. If a child script already
    logged an error and marked it, the pipeline shows the error in terminal
    without writing a duplicate ERROR entry to the logfile.

.NOTES
    Version: 1.6
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
    $alreadyLoggedByChildScript = $false

    if ($null -ne $_.Exception -and $null -ne $_.Exception.Data -and $_.Exception.Data.Contains('LoggedByScript')) {
        $alreadyLoggedByChildScript = [bool]$_.Exception.Data['LoggedByScript']
    }

    if ($null -ne $_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        $errorMessage = $_.Exception.Message
    }
    elseif ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
        $errorMessage = $_.ErrorDetails.Message
    }
    else {
        $errorMessage = $_.ToString()
    }

    # Avoid duplicate logfile entries: if the child script already logged this
    # error, print it to terminal directly without invoking the logging alias.
    if ($alreadyLoggedByChildScript) {
        Microsoft.PowerShell.Utility\Write-Error $errorMessage
    }
    else {
        Write-Error $errorMessage
    }
    Write-Host "Press Enter to close this window after reviewing the error..." -ForegroundColor Yellow
    Read-Host | Out-Null
    throw
}
