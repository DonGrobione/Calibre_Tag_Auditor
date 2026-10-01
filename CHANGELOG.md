# Changelog
All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the modules use [Semantic Versioning](https://semver.org/). Module versions are maintained in their manifests (`Modules/*.psd1`); standalone scripts keep their version in their comment-based help block.

## 2026-10-01

### Scripts
- `02-Process-CalibreDataWithLLM.ps1` 5.0: switched from the Mistral API to the Google Gemini Interactions API with the model `gemini-3.8-flash`.
  - The API key is read from the `APIKey` property of the JSON file `Secrets/Gemini_API.json.key` (new function `Get-GeminiApiKey`). `Secrets/Mistral_API.key` and `Secrets/Mistral_Agent_Id.txt` are no longer used.
  - Gemini needs no agent, so `Test-MistralAgent`, `Remove-MistralAgent`, `New-MistralAgent`, and `Get-MistralAgentId` were removed. The prompt is sent as `system_instruction` with every request instead of being repeated in the input.
  - `Invoke-MistralRequest` and `Get-MistralResponseText` were replaced by `Invoke-GeminiRequest` and `Get-GeminiResponseText`. The retry behavior for 429/503/504 and for invalid responses is unchanged. Responses with a status other than `completed` are logged as a warning.
  - Temperature and top-p are no longer set, as Google recommends for Gemini 3.8 Flash. The thinking level (default `medium`) is configurable in the script.
  - Token usage: completion tokens now include Gemini's thinking tokens, because they are billed as output.
  - The result files contain the field `model` instead of `agent_id`.

## 2026-09-26

### Calibre.Environment 1.3.0
- Added the module manifest `Modules/Calibre.Environment.psd1` with explicit exports. The version moved from the comment-based help block into the manifest.
- Errors are now raised with `$PSCmdlet.ThrowTerminatingError()` and carry an error ID (for example `CalibreConfigurationNotFound`, `CalibreLibraryNotFound`) and an error category. The error messages are unchanged.
- Fixed: `Get-CalibreConfiguration` accepted a configuration without `CalibrePaths`, because `@($null)` counts as one entry. Empty entries are now removed, and a configuration without a usable path is rejected.
- `Get-CalibreEnvironment` skips empty installation paths instead of failing on them.

### Calibre.Console 1.1.0
- Added the module manifest `Modules/Calibre.Console.psd1` with explicit exports. The version moved from the comment-based help block into the manifest.
- Fixed: `ConvertTo-DisplayPath` failed parameter validation for an empty or `$null` path. It now returns an empty string, as its implementation intended.

### Scripts
- All scripts import the modules through their manifests instead of the `.psm1` files.
- `01-Export-CalibreBooks.ps1` 3.4 and `01-Export-CalibreTags.ps1` 3.3: the configuration is loaded inside the error-handling block, so configuration errors are written to the log and stop the script.

- Fixed all PSScriptAnalyzer warnings in the scripts:
  - Blank console lines use `Write-Information` instead of `Write-Host`. The pipeline's error prompt uses `Read-Host -Prompt` and is no longer yellow.
  - `02-Process-CalibreDataWithLLM.ps1` 4.4: `Test-AgentExists` was renamed to `Test-MistralAgent`. `Remove-MistralAgent` and `New-MistralAgent` support `-WhatIf`/`-Confirm`.
  - `03-Convert-LLMResults2ODS.ps1` 1.4: renamed `Convert-JsonValues`, `Get-BookRecordsFromJsonFiles`, `ConvertTo-CsvRows` and `Invoke-LibreOfficeCsvToOds` to `Convert-JsonValue`, `Get-BookRecordFromJsonFile`, `ConvertTo-CsvRow` and `Invoke-LibreOfficeConversion`. The JSON check in `Repair-JsonText` moved into `Test-JsonText`, which replaces the empty catch blocks. `Set-ConfigItemValue` supports `-WhatIf`/`-Confirm`.
  - `Invoke-CalibreToolsPipeline.ps1` 1.9.
- Fixed in `03-Convert-LLMResults2ODS.ps1`: `ConvertTo-CsvRow` never used the fallback properties `Titel`, `Autor`, `Action`, `Aktion`, and `Begründung`, because an empty `PSObject.Properties.Match()` result counts as `$true`. LLM results that use these names now fill the review sheet instead of leaving the cells empty.

### Project
- Added Pester tests in `Tests/` for both modules and for the changed functions of the 02 and 03 scripts (Pester v4-compatible syntax). The script tests parse the script and load only the functions under test, so the workflow does not run.
- Added this changelog.
