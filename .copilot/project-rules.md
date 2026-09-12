# Copilot Project Rules

## 1. Documentation
- Write all README content, PowerShell comments, comment-based help, and user-visible PowerShell messages in English.
- Keep `README.md` as a concise, task-oriented user guide. Use clear language and document prerequisites, the normal workflow, outputs, and user-actionable troubleshooting.
- In comment-based help blocks, regular comments, and `README.md`, there must be no line breaks in the middle of a sentence. Each sentence or logical comment line must be written completely without splitting sentences across multiple lines.
- Comment-based help blocks (`<# ... #>`) are allowed strictly and exclusively at the beginning (top) of a script or module file. Function-level comment-based help blocks are strictly forbidden.
- All comments inside script files, function bodies, and above functions must be regular single-line (`#`) or block comments.
- Every function must be commented in a clear, human-readable way explaining its purpose, parameters, and behavior.
- The project rules must be located in `.copilot/project-rules.md` and repository memory in `.copilot/repo-memory.md`. No other files or subdirectories are permitted in `.copilot/`.
- Every change to documentation and code must have clear commit messages.
- After code changes, verify that all examples, file structure, and guidelines are accurate.

## 2. Coding Standards
- The project must strictly adhere to Microsoft and PowerShell best practices.
- Ensure full compatibility with PowerShell 5.1 across all scripts and modules.
- Use descriptive, consistent names (no abbreviations except for loop counters).
- Functions should have a single responsibility, ideally no more than 3 parameters, and clear, action-oriented names using PowerShell Approved Verbs (verify with `Get-Verb`).
- Avoid side effects in functions when possible; return early to reduce nesting.
- Group related functionality, keep files and modules focused.
- Always validate inputs at boundaries.

## 3. Performance
- Optimize only after measurement and profiling.
- Focus on optimizing the critical path first.
- Use appropriate data structures, minimize memory allocations, batch operations where possible, and cache expensive operations when needed.
- Never sacrifice readability for performance.

## 4. Script Handling (PowerShell)
- Ensure compatibility with PowerShell 5.1.
- All scripts must be written in English (code, comments, help blocks, and output messages).
- Use PowerShell Approved Verbs for script and function names.
- Error handling is mandatory; use a top-level try/catch and rethrow with `throw` to bubble failures to the orchestrator.
- Avoid `exit 1` in subscripts. Reserve exit handling for orchestrator or standalone entry points where process exit codes are explicitly required.
- Every script or module must include a correct and up-to-date comment-based help block (`about_Comment_Based_Help`) placed strictly at the top of the file.
- The comment-based help block must be updated to reflect any changes to the script, including the version number, whenever the script is modified.
- Do not use `======` separators (reserved for the main script only).
- For existing scripts: validate paths with `Test-Path` and use `try-catch` for critical operations.
- Store all LLM agent prompt instructions exclusively in external `.txt` prompt files; do not embed agent prompt text or instruction blocks in PowerShell scripts.
- Every PowerShell script must import `Modules/Write-Log.psm1`.
- Every user-visible script message must be written to terminal and logfile.
- `Write-Host`, `Write-Warning`, and `Write-Error` must be wrapped or aliased so terminal output is preserved while logging the same message.
- Every logfile entry must include the emitting script name as prefix (for example `[MyScript.ps1]`).
- In orchestrated runs, avoid duplicate error log entries: child scripts log and rethrow their own errors; orchestrators must only print the error to terminal and must not write duplicate log entries.
- Every script must remove its `Write-Host`/`Write-Warning`/`Write-Error` aliases in a `finally` block before exiting, so a `-Scope Script` alias can never leak into the caller's session.
- In terminal and logfile messages, display project-internal paths as relative paths from the repository root (for example `.\04-ODS\file.ods`).
- Exception: paths under `$env:TEMP` must be logged as absolute paths.
- Temporary files must always be created under `$env:TEMP`, never in the script root or output directories, and must be removed after use.

## 5. Copilot Memory
- All Copilot memory relevant to this project must be written to `.copilot/repo-memory.md`, not to the local user-scoped Copilot memory system.
- No other files or folders are allowed inside `.copilot/` besides `.copilot/project-rules.md` and `.copilot/repo-memory.md`.
- When reading project context at the start of a task, always load `.copilot/repo-memory.md` first.

## 6. Security
- Never trust user input; always validate.
- Apply defense in depth, least privilege, and fail securely principles.
- Never store secrets in code — all passwords, usernames, credentials, API keys, tokens, and similar sensitive values must be stored in a `.psd1` file under the `.secrets/` folder and read from there at runtime.
- Keep dependencies up to date, use static analysis tools, conduct security reviews.
