@{
    RootModule        = 'Calibre.TagDefinitions.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '68034111-26d1-4633-bfe7-71a0117ed985'
    Author            = 'DonGrobione'
    CompanyName       = 'DonGrobione'
    Copyright         = '(c) DonGrobione. Licensed under the GNU Affero General Public License v3.0.'
    Description       = 'Detects changes of the Calibre tag definitions since the last full-library audit of the Calibre Tag Auditor and keeps the baseline of the audited definitions.'
    PowerShellVersion = '5.1'
    RequiredModules   = @()
    FunctionsToExport = @('Read-TagDefinitionFile', 'Get-TagDefinitionBaseline', 'Save-TagDefinitionBaseline', 'Compare-TagDefinition', 'Format-TagDefinitionChange')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('Calibre', 'Ebook', 'Tags', 'Windows', 'PSEdition_Desktop')
            ProjectUri   = ''
            LicenseUri   = ''
            ReleaseNotes = '1.0.0: First version. Reads tag definition exports, keeps the baseline of the definitions of the last full-library audit, and reports added, removed, and changed tags. See CHANGELOG.md.'
        }
    }
}
