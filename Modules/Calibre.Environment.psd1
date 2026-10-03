@{
    RootModule        = 'Calibre.Environment.psm1'
    ModuleVersion     = '1.3.1'
    GUID              = 'b8995db9-934f-4568-b5bc-cc21c23e71e3'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'Loads and validates the Calibre Tag Auditor configuration and resolves the Calibre installation, library, database, and executable paths.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Get-CalibreConfiguration', 'Get-CalibreEnvironment', 'Get-CalibreExecutable')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Ebook', 'Configuration', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.3.1: Get-CalibreConfiguration reads the configuration file as UTF-8 (with or without BOM), so non-ASCII paths are no longer garbled by the ANSI code page of Windows PowerShell 5.1. 1.3.0: Added the module manifest. Errors are now raised with $PSCmdlet.ThrowTerminatingError() and carry an error ID and category; the error messages are unchanged. Get-CalibreConfiguration now rejects a configuration without usable CalibrePaths and drops empty entries. See CHANGELOG.md.'
        }
    }
}
