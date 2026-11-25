@{
    RootModule        = 'Calibre.Text.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = '8e7c4fec-49aa-4b2b-b451-522ea1ab3c69'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'Text and JSON helpers (mojibake repair, JSON extraction and unescaping, UUID check) for the Calibre Tag Auditor scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Repair-MojibakeText', 'Get-JsonText', 'Restore-JsonEscapedCharacter', 'Test-CalibreUuid')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Encoding', 'UTF8', 'Mojibake', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.1.0: Get-JsonText moved here from 02-Process-CalibreDataWithLLM.ps1 and 03-Convert-LLMResults2ODS.ps1, Test-CalibreUuid from 01-Export-CalibreBooks.ps1; new Restore-JsonEscapedCharacter, shared by the JSON writers of 01-Export-CalibreBooks.ps1 and 02-Process-CalibreDataWithLLM.ps1. Repair-MojibakeText is an advanced function. 1.0.0: New module. Repair-MojibakeText moved here from 02-Process-CalibreDataWithLLM.ps1, so 03-Convert-LLMResults2ODS.ps1 uses the same strict per-sequence repair. See CHANGELOG.md.'
        }
    }
}