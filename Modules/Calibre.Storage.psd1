@{
    RootModule        = 'Calibre.Storage.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '574f47e2-f510-4199-a8f7-2480db4a3c2d'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'File helpers (atomic writes, result file checks, run timestamps) for the Calibre Tag Auditor scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Save-AtomicTextFile', 'Test-ResultFileComplete', 'Get-ExportTimestamp')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Files', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.0.0: New module. Save-AtomicTextFile replaces Save-ResultFile (02-Process-CalibreDataWithLLM.ps1) and Save-PipelineRunState (Invoke-CalibreToolsPipeline.ps1); Test-ResultFileComplete moved here from 02-Process-CalibreDataWithLLM.ps1; Get-ExportTimestamp replaces the timestamp regex of 03-Convert-LLMResults2ODS.ps1 and Invoke-CalibreToolsPipeline.ps1. See CHANGELOG.md.'
        }
    }
}
