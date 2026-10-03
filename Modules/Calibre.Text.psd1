@{
    RootModule        = 'Calibre.Text.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8e7c4fec-49aa-4b2b-b451-522ea1ab3c69'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'Text encoding helpers (mojibake repair) for the Calibre Tag Auditor scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Repair-MojibakeText')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Encoding', 'UTF8', 'Mojibake', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.0.0: New module. Repair-MojibakeText moved here from 02-Process-CalibreDataWithLLM.ps1, so 03-Convert-LLMResults2ODS.ps1 uses the same strict per-sequence repair. See CHANGELOG.md.'
        }
    }
}