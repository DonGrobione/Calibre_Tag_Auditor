# Copilot Project Rules

## 1. Documentation
- Keep README.md current: project structure, purpose of every user-facing file and directory, prerequisites, configuration, and usage.
- Write code, comments, comment-based help, output, log messages, and documentation in English.
- Do not insert line breaks in the middle of a sentence in README.md, comment-based help, or regular comments. Start new lines only between complete sentences or list items.
- Give every commit a clear message describing what changed and why.
- After code changes, verify that examples, file structure, and guidelines match the codebase.

## 2. Comment-Based Help And Comments
- Each .ps1/.psm1 file must contain exactly one comment-based help block as the first content in the file. Only an optional #requires statement may precede it.
- Comment-based help blocks inside functions or elsewhere in the file are strictly forbidden.
- All other comments must be regular single-line # comments.
- Every function must have a concise regular comment immediately before its definition, describing its responsibility and observable behavior.

## 3. PowerShell Standards (Windows PowerShell 5.1)
- All .ps1 and .psm1 files must parse and run in Windows PowerShell 5.1. Do not use PowerShell 6+ syntax, operators, automatic variables, or cmdlets.
- Use approved verbs for function names (verify with Get-Verb) and descriptive PascalCase/camelCase names without abbreviations (except loop counters).
- Keep functions single-responsibility, action-oriented, with early returns to reduce nesting.
- Validate inputs and paths at boundaries. Use Join-Path for constructed paths, Test-Path with -PathType before dependent operations, and -ErrorAction Stop for operations handled by try/catch.
- Avoid aliases, Invoke-Expression, wildcard exports, global state, and unnecessary side effects.
- Enable Set-StrictMode -Version Latest only after verifying that the complete script and all imported modules support it in PowerShell 5.1.

## 4. Logging And Error Handling
- Logging uses only the external module DonGrobione.Logging (>= 1.2.0), installed in the default PowerShell module path and imported with Import-Module DonGrobione.Logging -MinimumVersion 1.2.0 -ErrorAction Stop. Never use -Force for this import because it resets a running log session. The project does not install, bundle, or update the module.
- Log files are written only by DonGrobione.Logging to <Documents>\Logs\Calibre_Tag_Auditor\. Nothing writes log files into the project folder.
- Invoke-CalibreToolsPipeline.ps1 calls Start-Log -LogDirectory 'Calibre_Tag_Auditor' once and Stop-Log in its finally block. Every other script uses $ownsLogSession = -not (Test-LogSession), starts a session only when it owns it, and stops it in finally only when it owns it.
- Scripts write terminal and log output through Write-ScriptLog from Modules\Calibre.Console.psm1, which forwards @PSBoundParameters unchanged to DonGrobione.Logging\Write-Log and also writes to the information stream. Levels are DEBUG, INFO, WARN, ERROR, and FATAL. Plain Write-Host is used only for console-only output such as blank lines and prompts.
- Never define a function named Write-Log and never read the logging module's private state ($script:LogConfig, & (Get-Module ...) { ... }, .SessionState). Use Test-LogSession and Get-LogSession; code that needs the log directory must handle a $null result from Get-LogSession.
- Modules and library scripts must not contain logging code or write log files. They return data, status objects, exception records, or error objects to the calling script. Modules\Calibre.Console.psm1 is the only exception because it provides Write-ScriptLog.
- Child scripts must catch their own errors, log them once with Write-ScriptLog -Level ERROR -ErrorRecord $_, and rethrow with throw so failures bubble to the orchestrator.
- The orchestrator prints errors to terminal only. It must not write duplicate log entries for errors already logged.
- Scripts return exit code 0 on success and 1 on unhandled failure. Standalone entry points and orchestrators use exit codes; sub-scripts called by an orchestrator rely on the orchestrator's exit handling.
- Project-internal paths are logged as relative paths from the repository root; paths under $env:TEMP are logged as absolute paths.
- Temporary files must be created under $env:TEMP and removed after use.

## 5. Security
- Never trust user input. Apply defense in depth, least privilege, and fail-securely principles.
- Never store secrets in code. Read credentials, tokens, and API keys at runtime from a .psd1 file under Secrets/.
- Do not log secret values.

## 6. Validation
- Parse changed PowerShell files with Windows PowerShell 5.1 before completing work.
- Run PSScriptAnalyzer where available and fix diagnostics introduced by the change.

## 7. Versioning
- For modules (.psm1 with manifest .psd1): the .psd1 manifest is the single source of truth for versioning. Do not duplicate version metadata inside comment-based help blocks.
- For standalone scripts (.ps1 without manifest): include a version number in the comment-based help block and keep it current when behavior changes.

## 8. Copilot Rules And Memory
- Project rules live only in .github/copilot-instructions.md.
- Repository memory lives only in .github/repo-memory.md. No other files are permitted inside .github/.
- Read .github/repo-memory.md before starting work on the repository.

## 9. Project-Specific Rules (Calibre_Tag_Auditor)
- Store secrets under Secrets/ as per the unified standard.
- Do not alias Write-Host, Write-Warning, or Write-Error. Messages that must appear in both terminal and log are written with Write-ScriptLog.
- LLM agent prompt instructions must be stored exclusively in external .txt prompt files; do not embed agent prompt text in PowerShell scripts.
- Maximum three parameters per function.
- Every script must import DonGrobione.Logging by name and Modules\Calibre.Console.psm1 by using a path based on $PSScriptRoot.