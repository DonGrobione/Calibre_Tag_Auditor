# Copilot Project Rules

## 1. Documentation
- Write all README content, developer documentation, PowerShell comments, comment-based help, and user-visible PowerShell messages in English.
- Keep `README.md` as a concise, task-oriented user guide. Use clear language and document only prerequisites, the normal workflow, outputs, and user-actionable troubleshooting.
- Do not include implementation details, logging internals, data-wrapper schemas, or duplicate explanations in `README.md`.
- Keep necessary technical implementation details in `.copilot/developer-documentation.md`.
- Update the relevant user and developer documentation when script behavior, outputs, prerequisites, or required files change.
- Every change to documentation and code must have clear commit messages.
- After code changes, verify that all examples, file structure, and guidelines are accurate.

## 2. Coding Standards
- Use descriptive, consistent names (no abbreviations except for loop counters).
- Functions should have a single responsibility, ideally no more than 3 parameters, and clear, action-oriented names.
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
- Add new scripts to the Scripts/ directory, use PowerShell Approved Verbs for filenames.
- Use PowerShell Approved Verbs for function names (verify with Get-Verb).
- Error handling is mandatory; use a top-level try/catch and rethrow with throw to bubble failures to the orchestrator.
- Avoid exit 1 in subscripts. Reserve exit handling for orchestrator or standalone entry points where process exit codes are explicitly required.
- No need to modify the main orchestrator script for new scripts.
- Every script must include a correct and up-to-date comment-based help block (about_Comment_Based_Help).
- The comment-based help block must always be updated to reflect any changes to the script, including the version number, whenever the script is modified.
- The comment-based help block must be placed at the top of the file (module-level/script-level), not inside function bodies.
- Do not use ====== separators (reserved for the main script only).
- For existing scripts: validate paths with Test-Path and use try-catch for critical operations.
- Store all LLM agent prompt instructions exclusively in external `.txt` prompt files; do not embed agent prompt text or instruction blocks in PowerShell scripts.
- Every PowerShell script must import `Modules/Write-Log.psm1`.
- Every user-visible script message must be written to terminal and logfile.
- `Write-Host`, `Write-Warning`, and `Write-Error` must be wrapped or aliased so terminal output is preserved while logging the same message.
- Every logfile entry must include the emitting script name as prefix (for example `[MyScript.ps1]`).
- In orchestrated runs, avoid duplicate error log entries: child scripts log and rethrow their own errors; orchestrators must only print the error to terminal (never call the logging alias again) and must not rely on `Exception.Data` flags to detect this, since custom Data does not reliably survive propagation through `& $scriptPath`.
- Every script must remove its Write-Host/Write-Warning/Write-Error aliases in a `finally` block before exiting, so a `-Scope Script` alias can never leak into the caller's (or an interactive/dot-sourced) session.
- In terminal and logfile messages, display project-internal paths as relative paths from the repository root (for example `.\04-ODS\file.ods`).
- Exception: paths under `$env:TEMP` must be logged as absolute paths.
- Temporary files must always be created under `$env:TEMP`, never in the script root or output directories, and must be removed after use.

## 5. Copilot Memory
- All Copilot memory relevant to this project must be written to `.copilot/repo-memory.md`, not to the local user-scoped Copilot memory system.
- This ensures memory is shared across all machines via version control.
- Session-only notes may still use session memory, but any insight worth keeping must be persisted to `.copilot/repo-memory.md`.
- When reading project context at the start of a task, always load `.copilot/repo-memory.md` first.

## 6. Security
- Never trust user input; always validate.
- Apply defense in depth, least privilege, and fail securely principles.
- Never store secrets in code — all passwords, usernames, credentials, API keys, tokens, and similar sensitive values must be stored in a `.psd1` file under the `.secrets/` folder and read from there at runtime.
- Keep dependencies up to date, use static analysis tools, conduct security reviews.
