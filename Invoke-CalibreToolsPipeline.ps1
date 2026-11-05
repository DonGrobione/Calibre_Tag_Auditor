<#
.SYNOPSIS
    Run all Calibre Tag Auditor scripts in sequence.

.DESCRIPTION
    Executes the export, LLM processing, and ODS conversion scripts in order. Each script must complete successfully before the next one starts. A step fails only by throwing an error; exit codes of external programs that a step ran are not checked.
    On failure, the error is shown and the script waits for Enter before exit.
    The pipeline starts one DonGrobione.Logging (>= 2.2.0) log session (log directory 'Calibre_Tag_Auditor') that all child scripts share, and stops it in a finally block. Script output (info, warnings, and errors) is written both to terminal and to that log file via Write-ScriptLog from Modules\Calibre.Console.psm1. Start-Log keeps the 5 newest log files per computer. Size-based rotation is turned off (-MaxFileSizeMB 0), so each run stays in one log file. Every child script already logs and rethrows its own errors, so on failure the pipeline only prints the error to the terminal (never writes a second logfile entry) and exits with code 1 instead of rethrowing, avoiding stray failure entries from the host's own error handling.
    On successful completion, the pipeline prints the number of books without audit result (missing_books, e.g. blocked by Gemini for prohibited content), which the ODS lists as NOT_AUDITED, the number of Google Search queries (billed per query, used for web content profiles of books without text), and the token usage of the run: the tokens of interrupted or repeated requests (already included in the following counts), prompt tokens with their cached part (billed at a lower rate), tool use tokens (search results added to the input), completion tokens (output including thinking), and as last line the total (prompt + tool use + completion). The counts come from the token ledger 02-LLM-Result\LLM-TokenUsage.json, which the LLM step updates after every Gemini response, so they include requests whose export file never got a result file. Without a ledger the counts come from the result files and a warning says so. A new run deletes the ledger of the old run.
    When 01-Export-CalibreBooks.ps1 writes no book export file (e.g. no book changed within ChangedWithinDays), there is nothing to validate: the pipeline skips the remaining steps, prints a short summary without token usage, and exits with code 0.
    Resume: a run can be cancelled (Ctrl+C) or stopped by a crash or power outage during the LLM step or the ODS conversion and continued later. After both export steps succeeded, the pipeline writes the run state file 02-LLM-Result\Pipeline-RunState.json (run timestamp, start time, FullContent, ChangedWithinDays, Status Running, Step 02-Process); after the LLM step it sets Step to 03-Convert, and after the ODS conversion Status to Completed. A new run deletes the old state file first, so a run interrupted during the export is simply started again. When a run is resumable (Status Running, its book export files and the tag export file still in 01-Export) and the pipeline is started without -Resume, it shows the progress and asks: [R]esume, [N]ew run, or [A]bort (an empty answer aborts). A resumed run skips both export steps and, at Step 03-Convert, also the LLM step; the LLM step runs with -Resume and the FullContent setting of the original run, so it keeps the existing results and skips every export file that already has a complete result. At most the export file in progress when the run stopped is processed again. The LLM step continues the token ledger of the earlier sessions, so the token and search query totals of the summary cover the whole run.

.PARAMETER ChangedWithinDays
    Exports only books changed within this number of days; 0 exports all books. Passed to 01-Export-CalibreBooks.ps1, where it overrides ChangedWithinDays from 01-CalibreExport.config.json for this run without changing the file. When omitted, the value from the configuration is used.

.PARAMETER FullContent
    Passed to 02-Process-CalibreDataWithLLM.ps1, which then sends the full book text for every book instead of stored content profiles. Use it after tag definitions with new concepts were added.

.PARAMETER Resume
    Continues the unfinished run recorded in 02-LLM-Result\Pipeline-RunState.json without asking. Fails when there is no unfinished run. Cannot be combined with ChangedWithinDays or FullContent, because a resumed run keeps the settings it was started with.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1
    Runs all steps with the settings from 01-CalibreExport.config.json.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 7
    Runs all steps for the books changed within the last 7 days.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 0 -FullContent
    Validates all books with their full text, e.g. after the tag definitions were changed.

.EXAMPLE
    .\Invoke-CalibreToolsPipeline.ps1 -Resume
    Continues the last run where it was cancelled or stopped.

.NOTES
    Version: 1.21
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(0, 36500)]
    [int]$ChangedWithinDays,

    [Parameter()]
    [switch]$FullContent,

    [Parameter()]
    [switch]$Resume
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

# Returns the parameters for a step script: the book export receives the pipeline's ChangedWithinDays override and the LLM step receives the FullContent and Resume switches when they were given; the other steps receive none.
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

    if ($ScriptName -eq '02-Process-CalibreDataWithLLM.ps1' -and $PipelineParameters.ContainsKey('FullContent') -and $PipelineParameters['FullContent']) {
        $stepParameters['FullContent'] = $true
    }

    if ($ScriptName -eq '02-Process-CalibreDataWithLLM.ps1' -and $PipelineParameters.ContainsKey('Resume') -and $PipelineParameters['Resume']) {
        $stepParameters['Resume'] = $true
    }

    return $stepParameters
}

# Reads the run state file of the last pipeline run. Returns $null when the file is missing, is not valid JSON, or has no RunTimestamp, Status, or Step.
function Get-PipelineRunState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $state = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    foreach ($propertyName in @('RunTimestamp', 'Status', 'Step')) {
        if ($null -eq $state -or $null -eq $state.PSObject.Properties[$propertyName] -or [string]::IsNullOrWhiteSpace([string]$state.$propertyName)) {
            return $null
        }
    }

    return $state
}

# Writes the run state as UTF-8 JSON. The content goes to a temporary file first, which then replaces the state file, so an interruption never leaves a truncated state file.
function Save-PipelineRunState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$State
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write pipeline run state')) {
        return
    }

    $temporaryPath = "$Path.tmp"
    $json = $State | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # [NullString]::Value passes a real null for the backup file; PowerShell would turn $null into an empty, invalid path.
        [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($temporaryPath, $Path)
    }
}

# Returns the timestamp of the book export files (the part yyyy-MM-dd_HH-mm-ss of 01-Export-CalibreBooks_<nn>_<timestamp>.json), or $null when there is no book export file.
function Get-BookExportTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportDirectory
    )

    if (-not (Test-Path -LiteralPath $ExportDirectory -PathType Container)) {
        return $null
    }

    foreach ($exportFile in @(Get-ChildItem -LiteralPath $ExportDirectory -Filter '01-Export-CalibreBooks_*.json' -File | Sort-Object -Property Name)) {
        if ($exportFile.Name -match '_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.json$') {
            return $Matches[1]
        }
    }

    return $null
}

# Returns $true when the run state describes an unfinished run (Status Running) whose book export files and tag export file are still in the export folder, so the run can be continued.
function Test-PipelineRunResumable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportDirectory
    )

    if ($null -eq $State -or [string]$State.Status -ne 'Running') {
        return $false
    }

    if (-not (Test-Path -LiteralPath $ExportDirectory -PathType Container)) {
        return $false
    }

    $bookExportFiles = @(Get-ChildItem -LiteralPath $ExportDirectory -Filter "01-Export-CalibreBooks_*_$([string]$State.RunTimestamp).json" -File)
    $tagExportFiles = @(Get-ChildItem -LiteralPath $ExportDirectory -Filter '02-Export-CalibreTags_*.json' -File)
    return ($bookExportFiles.Count -gt 0 -and $tagExportFiles.Count -gt 0)
}

# Returns the progress of a run: Total is the number of book export files with the run timestamp, Done the number of them with a complete result file (valid JSON whose status is not error), the same rule the LLM step uses to skip a file on resume.
function Get-ResumeProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResultDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RunTimestamp
    )

    $exportFiles = @()
    if (Test-Path -LiteralPath $ExportDirectory -PathType Container) {
        $exportFiles = @(Get-ChildItem -LiteralPath $ExportDirectory -Filter "01-Export-CalibreBooks_*_$RunTimestamp.json" -File)
    }

    $doneCount = 0
    foreach ($exportFile in $exportFiles) {
        $resultPath = Join-Path -Path $ResultDirectory -ChildPath ($exportFile.Name -replace '^01-Export-CalibreBooks_', 'LLM-Result_')
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            continue
        }

        try {
            $result = [System.IO.File]::ReadAllText($resultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        if ($null -ne $result -and $null -ne $result.PSObject.Properties['status'] -and [string]$result.status -ne 'error') {
            $doneCount++
        }
    }

    return [pscustomobject]@{ Done = $doneCount; Total = $exportFiles.Count }
}

# Adds the counts of a token_usage object (from a result file or the token ledger) to a total hashtable, for every key of the hashtable; missing or $null counts add nothing.
function Add-TokenUsageCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Total,
        [AllowNull()]
        [object]$Record
    )

    if ($null -eq $Record) {
        return
    }

    foreach ($propertyName in @($Total.Keys)) {
        if ($null -ne $Record.PSObject.Properties[$propertyName] -and $null -ne $Record.$propertyName) {
            $Total[$propertyName] += [int64]$Record.$propertyName
        }
    }
}

# Sums the token usage of a run for the summary. The counts come from the token ledger of the LLM step, which holds every Gemini response of the run, including the requests of interrupted or repeated export files; without a valid ledger (a run started before the ledger existed) they come from the result files, and LedgerFound is $false. TotalTokens is prompt + tool use + completion (cached tokens are part of the prompt tokens). UnsavedTokens is the part of the ledger total that no result file holds. MissingBookCount counts the missing_books of the result files.
function Get-RunTokenSummary {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResultDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LedgerPath
    )

    $countNames = @('prompt_tokens', 'cached_tokens', 'tool_use_tokens', 'completion_tokens', 'web_search_queries')
    $resultTotal = @{}
    foreach ($countName in $countNames) {
        $resultTotal[$countName] = [int64]0
    }

    $totalMissingBooks = 0
    if (Test-Path -LiteralPath $ResultDirectory -PathType Container) {
        foreach ($resultFile in @(Get-ChildItem -LiteralPath $ResultDirectory -Filter 'LLM-Result_*.json' -File)) {
            $result = [System.IO.File]::ReadAllText($resultFile.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $result.PSObject.Properties['token_usage']) {
                Add-TokenUsageCount -Total $resultTotal -Record $result.token_usage
            }
            if ($null -ne $result.PSObject.Properties['missing_books']) {
                $totalMissingBooks += @($result.missing_books | Where-Object { $null -ne $_ }).Count
            }
        }
    }
    $resultTokens = $resultTotal['prompt_tokens'] + $resultTotal['tool_use_tokens'] + $resultTotal['completion_tokens']

    $ledger = $null
    if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
        try {
            $ledger = [System.IO.File]::ReadAllText($LedgerPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $ledger = $null
        }
    }

    $runTotal = $resultTotal
    if ($null -ne $ledger) {
        $runTotal = @{}
        foreach ($countName in $countNames) {
            $runTotal[$countName] = [int64]0
        }
        Add-TokenUsageCount -Total $runTotal -Record $ledger
    }
    $runTokens = $runTotal['prompt_tokens'] + $runTotal['tool_use_tokens'] + $runTotal['completion_tokens']

    return [pscustomobject]@{
        LedgerFound      = ($null -ne $ledger)
        PromptTokens     = $runTotal['prompt_tokens']
        CachedTokens     = $runTotal['cached_tokens']
        ToolUseTokens    = $runTotal['tool_use_tokens']
        CompletionTokens = $runTotal['completion_tokens']
        TotalTokens      = $runTokens
        SearchQueryCount = $runTotal['web_search_queries']
        UnsavedTokens    = [math]::Max([int64]0, $runTokens - $resultTokens)
        MissingBookCount = $totalMissingBooks
    }
}

# Asks whether an unfinished run is resumed, replaced by a new run, or left alone, and returns R, N, or A. An empty answer, or a host that cannot prompt, returns A, so nothing is lost by accident.
function Read-ResumeChoice {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    while ($true) {
        try {
            $answer = Read-Host -Prompt '[R]esume the unfinished run, start a [N]ew run (discards its results), or [A]bort'
        }
        catch {
            return 'A'
        }

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return 'A'
        }

        $choice = $answer.Trim().Substring(0, 1).ToUpperInvariant()
        if ($choice -in @('R', 'N', 'A')) {
            return $choice
        }
    }
}

# Collect the parameters given to the pipeline so they can be forwarded to the step scripts.
$pipelineParameters = @{}
if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) {
    $pipelineParameters['ChangedWithinDays'] = $ChangedWithinDays
}
if ($FullContent) {
    $pipelineParameters['FullContent'] = $true
}

$exportDirectory = Join-Path -Path $PSScriptRoot -ChildPath '01-Export'
$resultDirectory = Join-Path -Path $PSScriptRoot -ChildPath '02-LLM-Result'
$runStatePath = Join-Path -Path $resultDirectory -ChildPath 'Pipeline-RunState.json'
$tokenLedgerPath = Join-Path -Path $resultDirectory -ChildPath 'LLM-TokenUsage.json'
$runState = $null
$runStateWritten = $false
$runFinished = $false

try {
    if ($Resume -and ($PSBoundParameters.ContainsKey('ChangedWithinDays') -or $FullContent)) {
        throw "-Resume cannot be combined with -ChangedWithinDays or -FullContent: a resumed run keeps the settings it was started with."
    }

    # Decide whether the unfinished run recorded in the run state file is continued.
    $runState = Get-PipelineRunState -Path $runStatePath
    $isResumable = Test-PipelineRunResumable -State $runState -ExportDirectory $exportDirectory
    $resumeRun = $false
    if ($Resume) {
        if (-not $isResumable) {
            throw "There is no unfinished run to resume. Start a new run without -Resume."
        }
        $resumeRun = $true
    }
    elseif ($isResumable) {
        $progress = Get-ResumeProgress -ExportDirectory $exportDirectory -ResultDirectory $resultDirectory -RunTimestamp $runState.RunTimestamp
        Write-ScriptLog "Unfinished run from $($runState.StartTime): $($progress.Done) of $($progress.Total) export file(s) processed (step $($runState.Step))."
        $choice = Read-ResumeChoice
        if ($choice -eq 'A') {
            Write-ScriptLog "Aborted. The unfinished run is kept and can be continued with -Resume."
            $runFinished = $true
            return
        }
        $resumeRun = ($choice -eq 'R')
    }

    # Define the order of scripts to run. A resumed run starts at the step it stopped in, with the settings of the original run.
    $scripts = @(
        "01-Export-CalibreBooks.ps1",
        "01-Export-CalibreTags.ps1",
        "02-Process-CalibreDataWithLLM.ps1",
        "03-Convert-LLMResults2ODS.ps1"
    )
    $skippedScripts = @()
    if ($resumeRun) {
        $skippedScripts = @("01-Export-CalibreBooks.ps1", "01-Export-CalibreTags.ps1")
        if ([string]$runState.Step -eq '03-Convert') {
            $skippedScripts += "02-Process-CalibreDataWithLLM.ps1"
        }
        $pipelineParameters = @{ Resume = $true }
        if ($runState.FullContent -eq $true) {
            $pipelineParameters['FullContent'] = $true
        }
        $runStateWritten = $true
        Write-ScriptLog "Resuming the run from $($runState.StartTime) (step $($runState.Step))."
        Write-Information -MessageData '' -InformationAction Continue
    }
    elseif (Test-Path -LiteralPath $runStatePath -PathType Leaf) {
        # A new run discards the old state first, so a run interrupted during the export is never offered for resume.
        Remove-Item -LiteralPath $runStatePath -Force -ErrorAction Stop
    }

    # A new run also discards the token ledger of the old run, so a later resume never continues it, even when the LLM step stops before it starts its own ledger.
    if (-not $resumeRun -and (Test-Path -LiteralPath $tokenLedgerPath -PathType Leaf)) {
        Remove-Item -LiteralPath $tokenLedgerPath -Force -ErrorAction Stop
    }

    # Run each script in sequence.
    $noBooksToProcess = $false
    foreach ($script in $scripts) {
        if ($skippedScripts -contains $script) {
            Write-ScriptLog "=== Skipped (resume): $script ==="
            continue
        }

        # The run becomes resumable once both exports are complete: write the run state right before the LLM step.
        if ($script -eq '02-Process-CalibreDataWithLLM.ps1' -and -not $resumeRun) {
            if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
                New-Item -Path $resultDirectory -ItemType Directory -ErrorAction Stop | Out-Null
            }
            $runState = [pscustomobject][ordered]@{
                RunTimestamp      = Get-BookExportTimestamp -ExportDirectory $exportDirectory
                StartTime         = $startTime.ToString('yyyy-MM-dd HH:mm:ss')
                FullContent       = [bool]$FullContent
                ChangedWithinDays = if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) { $ChangedWithinDays } else { $null }
                Status            = 'Running'
                Step              = '02-Process'
            }
            Save-PipelineRunState -Path $runStatePath -State $runState
            $runStateWritten = $true
        }

        $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $script
        $stepParameters = Get-StepScriptParameter -ScriptName $script -PipelineParameters $pipelineParameters
        Write-ScriptLog "=== Starting: $script ==="
        # A failed step rethrows its error, which ends the loop. $LASTEXITCODE is not checked, because it only holds the exit code of the last external program a step ran, including failures the step already handled.
        & $scriptPath @stepParameters

        Write-ScriptLog "=== Completed: $script ==="
        Write-Information -MessageData '' -InformationAction Continue

        if ($script -eq '02-Process-CalibreDataWithLLM.ps1') {
            $runState.Step = '03-Convert'
            Save-PipelineRunState -Path $runStatePath -State $runState
        }

        # Without a book export there is nothing to validate, so the remaining steps are skipped.
        if ($script -eq '01-Export-CalibreBooks.ps1' -and -not (Test-BookExportFile -ExportDirectory $exportDirectory)) {
            $noBooksToProcess = $true
            Write-ScriptLog "No book export file was written, so there is nothing to validate. The remaining steps are skipped."
            Write-Information -MessageData '' -InformationAction Continue
            break
        }
    }

    $runFinished = $true
    if ($runStateWritten) {
        $runState.Status = 'Completed'
        Save-PipelineRunState -Path $runStatePath -State $runState
    }

    if ($noBooksToProcess) {
        $endTime = Get-Date
        Write-ScriptLog "--- Pipeline complete (no books to process) ---"
        Write-ScriptLog "Start:    $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-ScriptLog "End:      $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-ScriptLog "Duration: $(Format-Duration -Duration ($endTime - $startTime))"
        return
    }

    $runTokens = Get-RunTokenSummary -ResultDirectory $resultDirectory -LedgerPath $tokenLedgerPath

    # Print a summary when the pipeline finishes successfully. The token lines end with the total, which is the sum of all billed token counts above it (the cached tokens are part of the prompt tokens).
    Write-ScriptLog "--- Pipeline complete ---"
    $endTime = Get-Date
    $duration = $endTime - $startTime
    if ($resumeRun) {
        Write-ScriptLog "Run started: $($runState.StartTime) (resumed in this session)"
    }
    Write-ScriptLog "Start:    $($startTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-ScriptLog "End:      $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    if ($resumeRun) {
        Write-ScriptLog "Duration (this session): $(Format-Duration -Duration $duration)"
    }
    else {
        Write-ScriptLog "Duration: $(Format-Duration -Duration $duration)"
    }
    Write-Information -MessageData '' -InformationAction Continue
    if ($runTokens.MissingBookCount -gt 0) {
        Write-ScriptLog -Level WARN -Message ('{0,-50}{1} (rows with ProposedAction NOT_AUDITED in the ODS; the LLM step summary lists them)' -f 'Books without audit result:', $runTokens.MissingBookCount)
    }
    else {
        Write-ScriptLog ('{0,-50}{1}' -f 'Books without audit result:', 0)
    }
    Write-ScriptLog ('{0,-50}{1}' -f 'Web search queries (billed per query):', $runTokens.SearchQueryCount.ToString('N0'))
    if ($runTokens.LedgerFound) {
        Write-ScriptLog ('{0,-50}{1} (included in the counts below)' -f 'Tokens of interrupted or repeated requests:', $runTokens.UnsavedTokens.ToString('N0'))
    }
    else {
        Write-ScriptLog -Level WARN -Message "No token ledger (02-LLM-Result\LLM-TokenUsage.json) found: the counts below come from the result files and miss the requests of interrupted export files."
    }
    Write-ScriptLog ('{0,-50}{1}' -f 'Prompt tokens (input):', $runTokens.PromptTokens.ToString('N0'))
    Write-ScriptLog ('{0,-50}{1}' -f '  of which cached (billed at a lower rate):', $runTokens.CachedTokens.ToString('N0'))
    Write-ScriptLog ('{0,-50}{1}' -f 'Tool use tokens (input from Google Search):', $runTokens.ToolUseTokens.ToString('N0'))
    Write-ScriptLog ('{0,-50}{1}' -f 'Completion tokens (output including thinking):', $runTokens.CompletionTokens.ToString('N0'))
    Write-ScriptLog ('{0,-50}{1}' -f 'Tokens total (prompt + tool use + completion):', $runTokens.TotalTokens.ToString('N0'))
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
    # Reached after an error, after Ctrl+C, or after the run finished. An unfinished run with a run state can be continued; a crash or power outage skips this block, but leaves the state Running, so the next start offers the resume as well.
    if (-not $runFinished -and $runStateWritten) {
        Write-ScriptLog -Level WARN -Message "The run did not finish. Continue it later with .\Invoke-CalibreToolsPipeline.ps1 -Resume (or start the pipeline and choose R)."
    }
    Stop-Log
}
