# CLAUDE.md

This file guides Claude Code when working in this repository. It holds the project rules and the repository memory.

## Project Overview
Windows PowerShell 5.1 scripts that export (recently changed) books and tag definitions from a Calibre Portable library, validate the tags with Google Gemini, and convert the results into a formatted ODS review sheet via headless LibreOffice. See README.md for user-facing configuration and usage.

## Commands
```powershell
# Full pipeline (has real side effects: Calibre export, paid Gemini API calls, LibreOffice). Ask before running.
.\Invoke-CalibreToolsPipeline.ps1

# Single steps, in pipeline order
.\01-Export-CalibreBooks.ps1
.\01-Export-CalibreTags.ps1
.\02-Process-CalibreDataWithLLM.ps1
.\03-Convert-LLMResults2ODS.ps1

# Parse check with Windows PowerShell 5.1 (run for every changed file)
powershell.exe -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '<file>'), [ref]$null, [ref]$e); $e"

# Static analysis
Invoke-ScriptAnalyzer -Path <file>

# Pester tests (v4 syntax; Pester 5.9.1 is also installed and must not be used for these files)
powershell.exe -NoProfile -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Tests\<Name>.Tests.ps1"
```

## Architecture
- **Invoke-CalibreToolsPipeline.ps1**: orchestrator. Starts the shared log session, runs the four step scripts in order with `&`, aborts on failure, prints a run and token summary. On failure it prints the error to the terminal only, waits for Enter, and exits with code 1.
- **01-Export-CalibreBooks.ps1**: runs `calibredb.exe` to export book metadata to `01-Export/01-Export-CalibreBooks_<nn>_<timestamp>.json`, split into files of `BooksPerFile` books. Uses `ebook-convert.exe` to add the first 20,000 words of the primary EPUB/AZW3/MOBI/PDF as `BookContent`.
- **01-Export-CalibreTags.ps1**: writes a temporary Python script to `$env:TEMP` and runs it with `calibre-debug.exe` to join `.calnotes/notes.db` with `metadata.db` and export the tag definitions to `01-Export/02-Export-CalibreTags_*.json`.
- **02-Process-CalibreDataWithLLM.ps1**: sends each book export file with the tag definitions to the Gemini Interactions API (`gemini-3.8-flash`, prompt from `02-CalibreDataLLM-Prompt.txt` as `system_instruction`, `store = false`), validates the unique-book counts, repairs mojibake, retries on 429/503/504 and on invalid responses, and writes `02-LLM-Result/LLM-Result_*.json`. Secret: `Secrets/Gemini_API.json.key` (JSON, property `APIKey`).
- **03-Convert-LLMResults2ODS.ps1**: merges the LLM results into a temporary pipe-delimited CSV in `$env:TEMP`, converts it with headless LibreOffice, and formats the ODS (line breaks, column widths) into `03-ODS/03-ODS_Convert_<timestamp>.ods`.
- **Modules/Calibre.Environment.psd1/.psm1**: loads and validates `01-CalibreExport.config.json` and resolves the Calibre installation, library, database and executable paths. Raises errors with `$PSCmdlet.ThrowTerminatingError()` and error IDs, so callers must call it inside try/catch. No logging.
- **Modules/Calibre.Console.psd1/.psm1**: `Write-ScriptLog` (terminal + log output wrapper) and `ConvertTo-DisplayPath` (project-relative display paths).
- Scripts import the modules through their `.psd1` manifests.
- **Tests/**: Pester tests, one file per module or script (`Tests/<Name>.Tests.ps1`). The Console tests replace DonGrobione.Logging with an in-memory stub module. Step scripts run their workflow when executed, so their tests parse the script with the PowerShell AST, dot-source only the function definitions under test, and stub `Write-ScriptLog`/`ConvertTo-DisplayPath`. Use `Assert-MockCalled -Scope It`, because Pester 3.4 otherwise counts calls across the whole Describe block.
- **CHANGELOG.md**: release notes per module version and for script changes.
- **Dependencies**: PowerShell module DonGrobione.Logging >= 1.2.0 (external, default module path, update with `Update-DonGrobioneLogging`), Calibre Portable (`calibredb.exe`, `calibre-debug.exe`, `ebook-convert.exe`), Google Gemini API, LibreOffice (`soffice.exe`).

## Rules

### 1. Documentation
- Keep README.md current: project structure, purpose of every user-facing file and directory, prerequisites, configuration, and usage.
- Write code, comments, comment-based help, output, log messages, and documentation in English.
- Do not insert line breaks in the middle of a sentence in README.md, comment-based help, or regular comments. Start new lines only between complete sentences or list items.
- Give every commit a clear message describing what changed and why.
- After code changes, verify that examples, file structure, and guidelines match the codebase.

### 2. Comment-Based Help And Comments
- Each .ps1/.psm1 file must contain exactly one comment-based help block as the first content in the file. Only an optional #requires statement may precede it.
- Comment-based help blocks inside functions or elsewhere in the file are strictly forbidden. (This intentionally leaves PSScriptAnalyzer's PSProvideCommentHelp findings for module functions open.)
- All other comments must be regular single-line # comments.
- Every function must have a concise regular comment immediately before its definition, describing its responsibility and observable behavior.

### 3. PowerShell Standards (Windows PowerShell 5.1)
- All .ps1 and .psm1 files must parse and run in Windows PowerShell 5.1. Do not use PowerShell 6+ syntax, operators, automatic variables, or cmdlets (no `?.`, `??`, ternaries, `&&`, `||`).
- Use approved verbs for function names (verify with Get-Verb) and descriptive PascalCase/camelCase names without abbreviations (except loop counters).
- Keep functions single-responsibility, action-oriented, with early returns to reduce nesting.
- Validate inputs and paths at boundaries. Use Join-Path for constructed paths, Test-Path with -PathType before dependent operations, and -ErrorAction Stop for operations handled by try/catch.
- Avoid aliases, Invoke-Expression, wildcard exports, global state, and unnecessary side effects.
- Enable Set-StrictMode -Version Latest only after verifying that the complete script and all imported modules support it in PowerShell 5.1.
- Maximum three parameters per function.

### 4. Logging And Error Handling
- Logging uses only the external module DonGrobione.Logging (>= 1.2.0), installed in the default PowerShell module path and imported with `Import-Module DonGrobione.Logging -MinimumVersion 1.2.0 -ErrorAction Stop`. Never use -Force for this import because it resets a running log session. The project does not install, bundle, or update the module.
- Log files are written only by DonGrobione.Logging to `<Documents>\Logs\Calibre_Tag_Auditor\<HOSTNAME>_yyyy-MM-dd_HHmmss.log` (one file per run, 5 files per host kept by Start-Log). Nothing writes log files into the project folder.
- Invoke-CalibreToolsPipeline.ps1 calls `Start-Log -LogDirectory 'Calibre_Tag_Auditor'` once and Stop-Log in its finally block. Every other script uses `$ownsLogSession = -not (Test-LogSession)`, starts a session only when it owns it, and stops it in finally only when it owns it.
- Every script imports DonGrobione.Logging by name and Modules\Calibre.Console.psm1 by a path based on $PSScriptRoot.
- Scripts write terminal and log output through Write-ScriptLog, which forwards @PSBoundParameters unchanged to DonGrobione.Logging\Write-Log and also writes to the information stream. Levels are DEBUG, INFO, WARN, ERROR, and FATAL. Console-only output uses `Write-Information -InformationAction Continue` (blank lines) or `Read-Host -Prompt` (prompts); Write-Host is not used.
- Do not alias Write-Host, Write-Warning, or Write-Error. Never define a function named Write-Log and never read the logging module's private state (`$script:LogConfig`, `& (Get-Module ...) { ... }`, `.SessionState`). Use Test-LogSession and Get-LogSession; code that needs the log directory must handle a $null result from Get-LogSession.
- Modules and library scripts must not contain logging code or write log files. They return data, status objects, exception records, or error objects to the calling script. Modules\Calibre.Console.psm1 is the only exception because it provides Write-ScriptLog.
- Child scripts must catch their own errors, log them once with `Write-ScriptLog -Level ERROR -ErrorRecord $_`, and rethrow with throw so failures bubble to the orchestrator.
- The orchestrator prints errors to terminal only (`Microsoft.PowerShell.Utility\Write-Error -ErrorAction Continue`) and calls `exit 1` instead of rethrowing. It must not write duplicate log entries for errors already logged.
- Scripts return exit code 0 on success and 1 on unhandled failure. Standalone entry points and orchestrators use exit codes; sub-scripts called by an orchestrator rely on the orchestrator's exit handling.
- Project-internal paths are logged as relative paths from the repository root (ConvertTo-DisplayPath); paths under $env:TEMP are logged as absolute paths.
- Temporary files must be created under $env:TEMP and removed after use.

### 5. Security
- Never trust user input. Apply defense in depth, least privilege, and fail-securely principles.
- Never store secrets in code. Read credentials, tokens, and API keys at runtime from files under Secrets/ (git-ignored).
- Do not log secret values.

### 6. Validation
- Parse changed PowerShell files with Windows PowerShell 5.1 before completing work.
- Run PSScriptAnalyzer where available and fix diagnostics introduced by the change.
- Do not run scripts with real side effects (Calibre export, Gemini API, LibreOffice) without asking.

### 7. Versioning
- For modules with a manifest (.psd1, currently all modules): the manifest is the single source of truth for versioning. Do not duplicate version metadata inside comment-based help blocks.
- For standalone scripts and modules without a manifest: include a version number in the comment-based help block and keep it current when behavior changes.

### 8. Project-Specific Rules
- Store secrets under Secrets/.
- LLM agent prompt instructions must be stored exclusively in external .txt prompt files; do not embed agent prompt text in PowerShell scripts.

### 9. PowerShell Quality Enforcement
- Do not add an email address anywhere it is not explicitly required.
- Target Windows PowerShell 5.1 compatibility. Do not use PowerShell 7+ only features.
- Use `CmdletBinding()`, `[Parameter()]` attributes with validation, and `SupportsShouldProcess`/`ShouldProcess` for state-changing functions.
- Use structured error handling (`try/catch`, `-ErrorAction Stop`, `$PSCmdlet.ThrowTerminatingError()`). `ThrowTerminatingError` only terminates the calling statement, so call such functions inside try/catch.
- No `Write-Host` in module code (use `Write-Verbose`/`Write-Warning`), no hard-coded secrets or machine-specific paths.
- Write code that produces zero PSScriptAnalyzer warnings (standard rule set). The intentional PSProvideCommentHelp findings from rule 2 have Information severity and stay open.

### 10. Testing (Pester)
- Tests live in `Tests/` and use Pester v4-compatible syntax (Describe/Context/It with `$value | Should Be $expected`) for Windows PowerShell 5.1. Pester 4 is not installed on the development machine and Pester 5 rejects this syntax, so run the tests with Pester 3.4.0 (see Commands).
- Whenever you create a new script or function, write corresponding Pester tests in `Tests/<Name>.Tests.ps1` (one file per module script).
- Whenever you modify an existing script or function, update its tests to cover the changes.
- After any creation or modification, run the affected test files and report the results. If tests fail, fix the code or the tests before considering the task complete.
- Test files follow rule 2 like every other .ps1 file (one comment-based help block, a comment before every function).

### 11. Gallery Readiness
The project is not published to the PowerShell Gallery, but it must stay compliant with the Gallery requirements, so it can be published later without restructuring:
- Every module has a manifest (`.psd1`) with `Author = 'DonGrobione'`, explicit `FunctionsToExport` (never `'*'`), `PowerShellVersion = '5.1'`, `Tags`, `ProjectUri`, `LicenseUri`, and `ReleaseNotes`.
- Use semantic versioning (SemVer) for module versions.
- Maintain `README.md`, `LICENSE`, and `CHANGELOG.md` at the project root.
- Update the manifest version, release notes, and changelog whenever a release-relevant change is made.
- `ProjectUri` and `LicenseUri` stay empty while the GitHub repository (github.com/DonGrobione/Calibre_Tag_Auditor) is not public; do not invent placeholder URLs. Once it is public, set `ProjectUri` to the repository URL and `LicenseUri` to the GitHub blob URL of LICENSE.

### Precedence
Rules 9 to 11 take precedence over any conflicting rule above.

## Repository Memory
- **PSScriptAnalyzer:** since 2026-09-26 the whole repository has zero warnings; only the intentional PSProvideCommentHelp Information findings remain. Console blank lines use `Write-Information -MessageData '' -InformationAction Continue`.
- **PSObject property checks:** `$obj.PSObject.Properties.Match('Name')` is always truthy, even when empty. Use `$obj.PSObject.Properties['Name']`, which returns `$null` for a missing property.
- **Encoding:** all .ps1, .psm1 and .psd1 files are UTF-8 with BOM (`EF BB BF`) and CRLF line endings, because scripts contain non-ASCII literals (e.g. `'Ã|Â'`, `Begründung`). When creating or fully rewriting such a file, verify or re-apply the BOM afterwards.
- **Output locations:** `01-Export/`, `02-LLM-Result/`, `03-ODS/` (contents git-ignored, `.gitkeep` tracked). `.vscode/` and `Secrets` are git-ignored.
- **Write-Error semantics:** the former aliased Write-Error was non-terminating because module functions do not inherit the caller's `$ErrorActionPreference`. Write-ScriptLog is non-terminating too, so replacing those calls kept the control flow.
- **Logging history:** the project's own logging modules (daily log files in the project folder) were replaced by DonGrobione.Logging. The pipeline owns the log session; step scripts start their own only when `Test-LogSession` is `$false`.
