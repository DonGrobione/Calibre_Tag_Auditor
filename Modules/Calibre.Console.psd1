@{
    RootModule        = 'Calibre.Console.psm1'
    ModuleVersion     = '1.1.1'
    GUID              = 'de4a6edf-1282-442f-bec4-5ba0e45c5c83'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'Console and log output helpers for the Calibre Tag Auditor scripts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Write-ScriptLog', 'ConvertTo-DisplayPath')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Logging', 'Console', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.1.1: Documentation only: the calling script needs DonGrobione.Logging 2.2.0 or later. 1.1.0: Added the module manifest; version metadata moved from the comment-based help block into this manifest. ConvertTo-DisplayPath now returns an empty string for an empty or $null path instead of failing parameter validation. See CHANGELOG.md.'
        }
    }
}
