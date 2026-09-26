# Changelog
All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the modules use [Semantic Versioning](https://semver.org/). Module versions are maintained in their manifests (`Modules/*.psd1`); standalone scripts keep their version in their comment-based help block.

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

### Project
- Added Pester tests in `Tests/` for both modules (Pester v4-compatible syntax).
- Added this changelog.
