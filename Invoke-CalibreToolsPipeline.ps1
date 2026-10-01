<#
.SYNOPSIS
    Run all Calibre Tag Auditor scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and ODS conversion scripts in order. Each script must complete successfully before the next one starts.
    On failure, the error is shown and the script waits for Enter before exit.
    The pipeline starts one DonGrobione.Logging (>= 2.2.0) log session (log directory 'Calibre_Tag_Auditor') that all child scripts share, and stops it in a finally block. Script output (info, warnings, and errors) is written both to terminal and to that log file via Write-ScriptLog from Modules\Calibre.Console.psm1. Start-Log keeps the 5 newest log files per computer. Size-based rotation is turned off (-MaxFileSizeMB 0), so each run stays in one log file. Every child script already logs and rethrows its own errors, so on failure the pipeline only prints the error to the terminal (never writes a second logfile entry) and exits with code 1 instead of rethrowing, avoiding stray failure entries from the host's own error handling.
    On successful completion, the pipeline prints the total prompt, completion, and combined token usage across all LLM result files.
    When 01-Export-CalibreBooks.ps1 writes no book export file (e.g. no book changed within ChangedWithinDays), there is nothing to validate: the pipeline skips the remaining steps, prints a short summary without token usage, and exits with code 0.

.PARAMETER ChangedWithinDays
    Exports only books changed within this number of days; 0 exports all books. Passed to 01-Export-CalibreBooks.ps1, where it overrides ChangedWithinDays from 01-CalibreExport.config.json for this run without changing the file. When omitted, the value from the configuration is used.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1
    Runs all steps with the settings from 01-CalibreExport.config.json.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 7
    Runs all steps for the books changed within the last 7 days.

.NOTES
    Version: 1.12
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(0, 36500)]
    [int]$ChangedWithinDays
)

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

# Clear the console to keep the output readable for each run.
Clear-Host

# Stop execution immediately on errors.
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# Start the log session shared by all child scripts. -MaxFileSizeMB 0 turns off size-based rotation, so each run stays in one log file.
Start-Log -LogDirectory 'Calibre_Tag_Auditor' -MaxFileSizeMB 0

# Returns $true when the export folder contains at least one book export file written by 01-Export-CalibreBooks.ps1.
function Test-BookExportFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportDirectory
    )

    if (-not (Test-Path -LiteralPath $ExportDirectory -PathType Container)) {
        return $false
    }

    return (@(Get-ChildItem -LiteralPath $ExportDirectory -Filter '01-Export-CalibreBooks_*.json' -File).Count -gt 0)
}

# Returns the parameters for a step script: the book export receives the pipeline's ChangedWithinDays override when it was given; all other steps receive none.
function Get-StepScriptParameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [hashtable]$PipelineParameters
    )

    $stepParameters = @{}
    if ($ScriptName -eq '01-Export-CalibreBooks.ps1' -and $PipelineParameters.ContainsKey('ChangedWithinDays')) {
        $stepParameters['ChangedWithinDays'] = $PipelineParameters['ChangedWithinDays']
    }

    return $stepParameters
}

# Collect the parameters given to the pipeline so they can be forwarded to the step scripts.
$pipelineParameters = @{}
if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) {
    $pipelineParameters['ChangedWithinDays'] = $ChangedWithinDays
}

try {
    # Define the order of scripts to run.
    $scripts = @(
        "01-Export-CalibreBooks.ps1",
        "01-Export-CalibreTags.ps1",
        "02-Process-CalibreDataWithLLM.ps1",
        "03-Convert-LLMResults2ODS.ps1"
    )

    # Run each script in sequence.
    $noBooksToProcess = $false
    foreach ($script in $scripts) {
        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $script
        $stepParameters = Get-StepScriptParameter -ScriptName $script -PipelineParameters $pipelineParameters
        Write-ScriptLog "=== Starting: $script ==="
        & $scriptPath @stepParameters

        # Check whether the script completed successfully.
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Script '$script' exited with code $LASTEXITCODE. Pipeline aborted."
        }

        Write-ScriptLog "=== Completed: $script ==="
        Write-Information -MessageData '' -InformationAction Continue

        # Without a book export there is nothing to validate, so the remaining steps are skipped.
        if ($script -eq '01-Export-CalibreBooks.ps1' -and -not (Test-BookExportFile -ExportDirectory (Join-Path -Path $PSScriptRoot -ChildPath '01-Export'))) {
            $noBooksToProcess = $true
            Write-ScriptLog "No book export file was written, so there is nothing to validate. The remaining steps are skipped."
            Write-Information -MessageData '' -InformationAction Continue
            break
        }
    }

    if ($noBooksToProcess) {
        $endTime = Get-Date
        Write-ScriptLog "--- Pipeline complete (no books to process) ---"
        Write-ScriptLog "Start:    $($startTime.ToString('HH:mm:ss'))"
        Write-ScriptLog "End:      $($endTime.ToString('HH:mm:ss'))"
        Write-ScriptLog "Duration: $(($endTime - $startTime).ToString('hh\:mm\:ss'))"
        return
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
    Write-Information -MessageData '' -InformationAction Continue
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
    Read-Host -Prompt 'Press Enter to close this window after reviewing the error' | Out-Null
    # Exit the orchestrator directly instead of rethrowing, so no uncaught exception reaches the host and triggers spurious failure log entries.
    exit 1
}
finally {
    Stop-Log
}
