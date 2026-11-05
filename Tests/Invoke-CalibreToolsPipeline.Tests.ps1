<#
.SYNOPSIS
    Pester tests for the helper functions in Invoke-CalibreToolsPipeline.ps1.

.DESCRIPTION
    Covers the ChangedWithinDays, FullContent, and Resume script parameters, the resume functions Get-PipelineRunState, Save-PipelineRunState, Get-BookExportTimestamp, Test-PipelineRunResumable, Get-ResumeProgress, and Read-ResumeChoice (with files under $TestDrive and a mocked Read-Host), source checks of the resume flow (export steps skipped, run state written before the LLM step, -Resume not combinable with ChangedWithinDays or FullContent), Test-BookExportFile, which decides whether the pipeline continues after the book export, Get-StepScriptParameter, which forwards ChangedWithinDays to the book export and FullContent to the LLM step. The source tests also check that the summary counts the missing_books of the LLM result files, ends with the token total, and that a new run deletes the old token ledger. Add-TokenUsageCount and Get-RunTokenSummary are tested with result files and token ledgers under $TestDrive (ledger counts with the tokens of interrupted requests, fallback to the result files, total as prompt + tool use + completion). The Step loop tests check in the source that the pipeline leaves the step loop after the book export when no book export file was written. The pipeline runs all steps when it is executed, so the tests parse it and load only the function definitions under test. The parameter metadata is read with Get-Command, which does not run the script.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Invoke-CalibreToolsPipeline.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath 'Invoke-CalibreToolsPipeline.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
foreach ($functionName in @('Test-BookExportFile', 'Get-StepScriptParameter', 'Get-PipelineRunState', 'Save-PipelineRunState', 'Get-BookExportTimestamp', 'Test-PipelineRunResumable', 'Get-ResumeProgress', 'Read-ResumeChoice', 'Add-TokenUsageCount', 'Get-RunTokenSummary')) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Invoke-CalibreToolsPipeline.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }

    It 'has an optional integer parameter ChangedWithinDays limited to 0..36500' {
        $parameter = (Get-Command -Name $scriptPath).Parameters['ChangedWithinDays']
        $parameter.ParameterType | Should Be ([int])
        $range = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
        $range.MinRange | Should Be 0
        $range.MaxRange | Should Be 36500
        @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should Be 0
    }

    It 'has an optional switch parameter FullContent' {
        (Get-Command -Name $scriptPath).Parameters['FullContent'].ParameterType | Should Be ([switch])
    }

    It 'counts missing_books of the LLM result files only when the property exists' {
        $scriptAst.Extent.Text | Should Match "if \(\`$null -ne \`$result\.PSObject\.Properties\['missing_books'\]\) \{\s+\`$totalMissingBooks \+= "
    }

    It 'prints the number of books without audit result in the summary' {
        $scriptAst.Extent.Text | Should Match "'Books without audit result:', \`$runTokens\.MissingBookCount"
    }

    It 'prints the token total as the last line of the summary' {
        $summaryLines = @([regex]::Matches($scriptAst.Extent.Text, "Write-ScriptLog[^\r\n]*\`$runTokens\.[A-Za-z]+") | ForEach-Object { $_.Value })
        $summaryLines[-1] | Should Match "'Tokens total \(prompt \+ tool use \+ completion\):', \`$runTokens\.TotalTokens"
    }

    It 'deletes the token ledger of the old run when a new run starts' {
        $scriptAst.Extent.Text | Should Match "(?s)if \(-not \`$resumeRun -and \(Test-Path -LiteralPath \`$tokenLedgerPath -PathType Leaf\)\) \{\s+Remove-Item -LiteralPath \`$tokenLedgerPath"
    }
}

Describe 'Add-TokenUsageCount' {
    It 'adds the counts of the hashtable keys and ignores missing and $null counts' {
        $total = @{ prompt_tokens = [int64]1; cached_tokens = [int64]0; tool_use_tokens = [int64]0 }
        Add-TokenUsageCount -Total $total -Record ([pscustomobject]@{ prompt_tokens = 10; cached_tokens = $null; other = 99 })
        $total['prompt_tokens'] | Should Be 11
        $total['cached_tokens'] | Should Be 0
        $total['tool_use_tokens'] | Should Be 0
        $total.ContainsKey('other') | Should Be $false
    }

    It 'leaves the total unchanged for a $null record' {
        $total = @{ prompt_tokens = [int64]5 }
        Add-TokenUsageCount -Total $total -Record $null
        $total['prompt_tokens'] | Should Be 5
    }
}

Describe 'Get-RunTokenSummary' {
    $resultDirectory = Join-Path -Path $TestDrive -ChildPath 'token-results'
    New-Item -Path $resultDirectory -ItemType Directory | Out-Null
    $ledgerPath = Join-Path -Path $resultDirectory -ChildPath 'LLM-TokenUsage.json'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_01_2026-11-01_07-31-38.json') -Value '{ "status": "success", "missing_books": [ { "Title": "A" } ], "token_usage": { "prompt_tokens": 100, "cached_tokens": 40, "tool_use_tokens": 10, "completion_tokens": 50, "total_tokens": 160, "web_search_queries": 2 } }'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_02_2026-11-01_07-31-38.json') -Value '{ "status": "success", "missing_books": [], "token_usage": { "prompt_tokens": 30, "completion_tokens": 20, "total_tokens": 50, "web_search_queries": 0 } }'

    It 'sums the result files and warns through LedgerFound $false when there is no ledger' {
        $summary = Get-RunTokenSummary -ResultDirectory $resultDirectory -LedgerPath $ledgerPath
        $summary.LedgerFound | Should Be $false
        $summary.PromptTokens | Should Be 130
        $summary.CachedTokens | Should Be 40
        $summary.ToolUseTokens | Should Be 10
        $summary.CompletionTokens | Should Be 70
        $summary.TotalTokens | Should Be 210
        $summary.SearchQueryCount | Should Be 2
        $summary.UnsavedTokens | Should Be 0
        $summary.MissingBookCount | Should Be 1
    }

    It 'takes the counts from the ledger and reports the tokens no result file holds' {
        Set-Content -LiteralPath $ledgerPath -Value '{ "prompt_tokens": 200, "cached_tokens": 60, "tool_use_tokens": 10, "completion_tokens": 90, "total_tokens": 300, "web_search_queries": 5, "requests": 6 }'
        $summary = Get-RunTokenSummary -ResultDirectory $resultDirectory -LedgerPath $ledgerPath
        $summary.LedgerFound | Should Be $true
        $summary.PromptTokens | Should Be 200
        $summary.CachedTokens | Should Be 60
        $summary.CompletionTokens | Should Be 90
        $summary.TotalTokens | Should Be 300
        $summary.SearchQueryCount | Should Be 5
        $summary.UnsavedTokens | Should Be 90
        $summary.MissingBookCount | Should Be 1
    }

    It 'computes the total as prompt + tool use + completion, not from total_tokens' {
        Set-Content -LiteralPath $ledgerPath -Value '{ "prompt_tokens": 200, "tool_use_tokens": 10, "completion_tokens": 90, "total_tokens": 1 }'
        (Get-RunTokenSummary -ResultDirectory $resultDirectory -LedgerPath $ledgerPath).TotalTokens | Should Be 300
    }

    It 'falls back to the result files for a ledger that is not valid JSON' {
        Set-Content -LiteralPath $ledgerPath -Value '{ "prompt_tokens": 2'
        $summary = Get-RunTokenSummary -ResultDirectory $resultDirectory -LedgerPath $ledgerPath
        $summary.LedgerFound | Should Be $false
        $summary.TotalTokens | Should Be 210
    }

    It 'returns zero counts without result folder' {
        $summary = Get-RunTokenSummary -ResultDirectory (Join-Path -Path $TestDrive -ChildPath 'missing') -LedgerPath (Join-Path -Path $TestDrive -ChildPath 'missing.json')
        $summary.TotalTokens | Should Be 0
        $summary.MissingBookCount | Should Be 0
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

Describe 'Get-StepScriptParameter' {
    It 'forwards ChangedWithinDays to the book export' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{ ChangedWithinDays = 7 }
        $result['ChangedWithinDays'] | Should Be 7
    }

    It 'forwards ChangedWithinDays 0 to export all books' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{ ChangedWithinDays = 0 }
        $result.ContainsKey('ChangedWithinDays') | Should Be $true
        $result['ChangedWithinDays'] | Should Be 0
    }

    It 'returns no parameters for the book export when ChangedWithinDays was not given' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters @{}
        $result.Count | Should Be 0
    }

    It 'returns no parameters for the other steps' {
        $result = Get-StepScriptParameter -ScriptName '01-Export-CalibreTags.ps1' -PipelineParameters @{ ChangedWithinDays = 7; FullContent = $true }
        $result.Count | Should Be 0
    }

    It 'forwards FullContent only to the LLM step' {
        $parameters = @{ ChangedWithinDays = 7; FullContent = $true }
        $llmStep = Get-StepScriptParameter -ScriptName '02-Process-CalibreDataWithLLM.ps1' -PipelineParameters $parameters
        $llmStep.Count | Should Be 1
        $llmStep['FullContent'] | Should Be $true
        (Get-StepScriptParameter -ScriptName '01-Export-CalibreBooks.ps1' -PipelineParameters $parameters).ContainsKey('FullContent') | Should Be $false
        (Get-StepScriptParameter -ScriptName '03-Convert-LLMResults2ODS.ps1' -PipelineParameters $parameters).Count | Should Be 0
    }

    It 'returns no parameters for the LLM step when FullContent was not given' {
        (Get-StepScriptParameter -ScriptName '02-Process-CalibreDataWithLLM.ps1' -PipelineParameters @{ ChangedWithinDays = 7 }).Count | Should Be 0
    }

    It 'forwards Resume and the stored FullContent only to the LLM step' {
        $parameters = @{ Resume = $true; FullContent = $true }
        $llmStep = Get-StepScriptParameter -ScriptName '02-Process-CalibreDataWithLLM.ps1' -PipelineParameters $parameters
        $llmStep['Resume'] | Should Be $true
        $llmStep['FullContent'] | Should Be $true
        (Get-StepScriptParameter -ScriptName '03-Convert-LLMResults2ODS.ps1' -PipelineParameters $parameters).Count | Should Be 0
    }
}

Describe 'Get-PipelineRunState and Save-PipelineRunState' {
    $statePath = Join-Path -Path $TestDrive -ChildPath 'Pipeline-RunState.json'

    It 'returns $null when the state file does not exist' {
        Get-PipelineRunState -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') | Should Be $null
    }

    It 'returns $null for a state file that is not valid JSON' {
        $brokenPath = Join-Path -Path $TestDrive -ChildPath 'broken.json'
        Set-Content -LiteralPath $brokenPath -Value '{ "RunTimestamp": "2026-11-01_07-31-38", "Sta'
        Get-PipelineRunState -Path $brokenPath | Should Be $null
    }

    It 'returns $null for a state file without Step' {
        $incompletePath = Join-Path -Path $TestDrive -ChildPath 'incomplete.json'
        Set-Content -LiteralPath $incompletePath -Value '{ "RunTimestamp": "2026-11-01_07-31-38", "Status": "Running" }'
        Get-PipelineRunState -Path $incompletePath | Should Be $null
    }

    It 'writes and reads back the run state without leaving a temporary file' {
        $state = [pscustomobject][ordered]@{ RunTimestamp = '2026-11-01_07-31-38'; StartTime = '2026-11-01 07:31:38'; FullContent = $true; ChangedWithinDays = 0; Status = 'Running'; Step = '02-Process' }
        Save-PipelineRunState -Path $statePath -State $state
        $readState = Get-PipelineRunState -Path $statePath
        $readState.RunTimestamp | Should Be '2026-11-01_07-31-38'
        $readState.FullContent | Should Be $true
        $readState.Step | Should Be '02-Process'
        Test-Path -LiteralPath "$statePath.tmp" | Should Be $false
    }

    It 'replaces an existing state file' {
        $state = Get-PipelineRunState -Path $statePath
        $state.Status = 'Completed'
        Save-PipelineRunState -Path $statePath -State $state
        (Get-PipelineRunState -Path $statePath).Status | Should Be 'Completed'
    }
}

Describe 'Get-BookExportTimestamp' {
    It 'returns the timestamp of the book export files' {
        $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'timestamp'
        New-Item -Path $exportDirectory -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '01-Export-CalibreBooks_01_2026-11-01_07-31-38.json') -Value '[]'
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '02-Export-CalibreTags_2026-11-01_07-31-40.json') -Value '[]'
        Get-BookExportTimestamp -ExportDirectory $exportDirectory | Should Be '2026-11-01_07-31-38'
    }

    It 'returns $null without book export files' {
        Get-BookExportTimestamp -ExportDirectory (Join-Path -Path $TestDrive -ChildPath 'missing') | Should Be $null
    }
}

Describe 'Test-PipelineRunResumable' {
    $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'resumable'
    New-Item -Path $exportDirectory -ItemType Directory | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '01-Export-CalibreBooks_01_2026-11-01_07-31-38.json') -Value '[]'
    Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath '02-Export-CalibreTags_2026-11-01_07-31-40.json') -Value '[]'
    $runningState = [pscustomobject]@{ RunTimestamp = '2026-11-01_07-31-38'; Status = 'Running'; Step = '02-Process' }

    It 'returns $true for a running state whose export files exist' {
        Test-PipelineRunResumable -State $runningState -ExportDirectory $exportDirectory | Should Be $true
    }

    It 'returns $false without a state' {
        Test-PipelineRunResumable -State $null -ExportDirectory $exportDirectory | Should Be $false
    }

    It 'returns $false for a completed run' {
        $completedState = [pscustomobject]@{ RunTimestamp = '2026-11-01_07-31-38'; Status = 'Completed'; Step = '03-Convert' }
        Test-PipelineRunResumable -State $completedState -ExportDirectory $exportDirectory | Should Be $false
    }

    It 'returns $false when the book export files belong to another run' {
        $otherState = [pscustomobject]@{ RunTimestamp = '2026-10-01_10-00-00'; Status = 'Running'; Step = '02-Process' }
        Test-PipelineRunResumable -State $otherState -ExportDirectory $exportDirectory | Should Be $false
    }

    It 'returns $false when the tag export file is missing' {
        $noTagDirectory = Join-Path -Path $TestDrive -ChildPath 'no-tags'
        New-Item -Path $noTagDirectory -ItemType Directory | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $noTagDirectory -ChildPath '01-Export-CalibreBooks_01_2026-11-01_07-31-38.json') -Value '[]'
        Test-PipelineRunResumable -State $runningState -ExportDirectory $noTagDirectory | Should Be $false
    }
}

Describe 'Get-ResumeProgress' {
    $exportDirectory = Join-Path -Path $TestDrive -ChildPath 'progress-export'
    $resultDirectory = Join-Path -Path $TestDrive -ChildPath 'progress-result'
    New-Item -Path $exportDirectory, $resultDirectory -ItemType Directory | Out-Null
    foreach ($number in '01', '02', '03', '04', '05') {
        Set-Content -LiteralPath (Join-Path -Path $exportDirectory -ChildPath "01-Export-CalibreBooks_${number}_2026-11-01_07-31-38.json") -Value '[]'
    }
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_01_2026-11-01_07-31-38.json') -Value '{ "status": "success" }'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_02_2026-11-01_07-31-38.json') -Value '{ "status": "warning" }'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_03_2026-11-01_07-31-38.json') -Value '{ "status": "error" }'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_04_2026-11-01_07-31-38.json') -Value '{ "status": "succ'
    Set-Content -LiteralPath (Join-Path -Path $resultDirectory -ChildPath 'LLM-Result_05_2026-11-01_07-31-38.tmp') -Value '{ "status": "success" }'

    It 'counts only complete results that are not errors' {
        $progress = Get-ResumeProgress -ExportDirectory $exportDirectory -ResultDirectory $resultDirectory -RunTimestamp '2026-11-01_07-31-38'
        $progress.Total | Should Be 5
        $progress.Done | Should Be 2
    }
}

Describe 'Read-ResumeChoice' {
    It 'returns R for the answer resume' {
        Mock Read-Host { 'resume' }
        Read-ResumeChoice | Should Be 'R'
    }

    It 'returns N for the answer n' {
        Mock Read-Host { 'n' }
        Read-ResumeChoice | Should Be 'N'
    }

    It 'returns A for an empty answer' {
        Mock Read-Host { '' }
        Read-ResumeChoice | Should Be 'A'
    }

    It 'asks again after an invalid answer' {
        $script:answers = New-Object -TypeName System.Collections.Queue
        $script:answers.Enqueue('x')
        $script:answers.Enqueue('a')
        Mock Read-Host { $script:answers.Dequeue() }
        Read-ResumeChoice | Should Be 'A'
        Assert-MockCalled Read-Host -Scope It -Times 2 -Exactly
    }

    It 'returns A when the host cannot prompt' {
        Mock Read-Host { throw 'non-interactive' }
        Read-ResumeChoice | Should Be 'A'
    }
}

Describe 'Resume flow' {
    $scriptText = $scriptAst.Extent.Text

    It 'has an optional switch parameter Resume' {
        (Get-Command -Name $scriptPath).Parameters['Resume'].ParameterType | Should Be ([switch])
    }

    It 'rejects -Resume together with -ChangedWithinDays or -FullContent' {
        $scriptText | Should Match "if \(\`$Resume -and \(\`$PSBoundParameters\.ContainsKey\('ChangedWithinDays'\) -or \`$FullContent\)\) \{\s+throw"
    }

    It 'skips both export steps in a resumed run and the LLM step at step 03-Convert' {
        $scriptText | Should Match '\$skippedScripts = @\("01-Export-CalibreBooks\.ps1", "01-Export-CalibreTags\.ps1"\)'
        $scriptText | Should Match "(?s)if \(\[string\]\`$runState\.Step -eq '03-Convert'\) \{\s+\`$skippedScripts \+= `"02-Process-CalibreDataWithLLM\.ps1`""
    }

    It 'writes the run state right before the LLM step of a new run' {
        $scriptText | Should Match "(?s)if \(\`$script -eq '02-Process-CalibreDataWithLLM\.ps1' -and -not \`$resumeRun\) \{.*?Status\s+= 'Running'.*?Save-PipelineRunState"
    }

    It 'deletes the old run state before a new run' {
        $scriptText | Should Match '(?s)elseif \(Test-Path -LiteralPath \$runStatePath -PathType Leaf\) \{[^}]*Remove-Item -LiteralPath \$runStatePath'
    }
}

Describe 'Step loop without a book export' {
    $stepLoop = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$scripts'
        }, $true)
    $noBooksCheck = $stepLoop.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match 'Test-BookExportFile'
        }, $true)

    It 'checks for a book export only after the book export step' {
        $noBooksCheck.Clauses[0].Item1.Extent.Text | Should Match "\`$script -eq '01-Export-CalibreBooks\.ps1'"
    }

    It 'leaves the step loop, so no later step runs' {
        $breakStatement = $noBooksCheck.Clauses[0].Item2.Find({ param($node) $node -is [System.Management.Automation.Language.BreakStatementAst] }, $true)
        $null -ne $breakStatement | Should Be $true
    }

    It 'no longer uses the removed tag definition baseline' {
        $scriptAst.Extent.Text | Should Not Match 'TagDefinition'
    }

    It 'does not treat a stale $LASTEXITCODE from a handled external program failure as a step failure' {
        $exitCodeReads = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'LASTEXITCODE' }, $true))
        $exitCodeReads.Count | Should Be 0
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