<#
.SYNOPSIS
    Pester tests for Modules\Calibre.TagDefinitions.psd1.

.DESCRIPTION
    Verifies the module manifest, Read-TagDefinitionFile, Get-TagDefinitionBaseline, Save-TagDefinitionBaseline, Compare-TagDefinition, and Format-TagDefinitionChange, including the error IDs raised with $PSCmdlet.ThrowTerminatingError(). The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.
    All files are created in the Pester TestDrive; Calibre is not needed.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Tests\Calibre.TagDefinitions.Tests.ps1
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$manifestPath = Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.TagDefinitions.psd1'

Get-Module -Name Calibre.TagDefinitions | Remove-Module -Force
Import-Module -Name $manifestPath -Force

# Writes the given text as UTF-8 without BOM to a file in the TestDrive and returns its path.
function Write-TestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $path = Join-Path -Path $TestDrive -ChildPath $Name
    [System.IO.File]::WriteAllText($path, $Text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    return $path
}

# Builds a tag definition object.
function Get-TestDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$NoteText
    )

    return [PSCustomObject]@{ Tag = $Tag; NoteText = $NoteText }
}

Describe 'Calibre.TagDefinitions manifest' {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    It 'is a valid manifest with a semantic version' {
        $manifest.Version.ToString() | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'names DonGrobione as the author' {
        $manifest.Author | Should Be 'DonGrobione'
    }

    It 'targets Windows PowerShell 5.1' {
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
    }

    It 'exports exactly the public functions' {
        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should Be 'Compare-TagDefinition,Format-TagDefinitionChange,Get-TagDefinitionBaseline,Read-TagDefinitionFile,Save-TagDefinitionBaseline'
    }

    It 'keeps the helper functions private' {
        Get-Command -Name Get-TagDefinitionErrorRecord -ErrorAction SilentlyContinue | Should Be $null
        Get-Command -Name ConvertTo-TagDefinitionMap -ErrorAction SilentlyContinue | Should Be $null
    }
}

Describe 'Read-TagDefinitionFile' {
    It 'returns the Tag and NoteText of every entry and keeps umlauts' {
        $noteText = "Fiktionale Erz$([char]0xE4)hlungen"
        $path = Write-TestFile -Name 'tags.json' -Text ('[ { "Tag": "Fantasy", "NoteText": "' + $noteText + '" }, { "Tag": "LitRPG", "NoteText": null } ]')
        $definitions = @(Read-TagDefinitionFile -Path $path)
        $definitions.Count | Should Be 2
        $definitions[0].NoteText | Should BeExactly $noteText
        $definitions[1].NoteText | Should BeExactly ''
    }

    It 'skips entries without a tag name' {
        $path = Write-TestFile -Name 'tags-empty-name.json' -Text '[ { "Tag": "", "NoteText": "x" }, { "NoteText": "y" }, { "Tag": "A", "NoteText": "z" } ]'
        @(Read-TagDefinitionFile -Path $path).Count | Should Be 1
    }

    It 'raises TagDefinitionFileNotFound for a missing file' {
        $caught = $null
        try { Read-TagDefinitionFile -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') } catch { $caught = $_ }
        $caught.FullyQualifiedErrorId | Should Be 'TagDefinitionFileNotFound,Read-TagDefinitionFile'
    }

    It 'raises TagDefinitionFileUnreadable for invalid JSON' {
        $path = Write-TestFile -Name 'tags-invalid.json' -Text '{ not json'
        $caught = $null
        try { Read-TagDefinitionFile -Path $path } catch { $caught = $_ }
        $caught.FullyQualifiedErrorId | Should Be 'TagDefinitionFileUnreadable,Read-TagDefinitionFile'
    }
}

Describe 'Save-TagDefinitionBaseline and Get-TagDefinitionBaseline' {
    It 'writes the definitions with AuditedAt as UTF-8 without BOM and reads them back' {
        $path = Join-Path -Path $TestDrive -ChildPath 'baseline.json'
        $noteText = "Begr$([char]0xFC)ndung"
        Save-TagDefinitionBaseline -Path $path -Definitions @((Get-TestDefinition -Tag 'A' -NoteText $noteText), (Get-TestDefinition -Tag 'B' -NoteText 'b'))

        [System.IO.File]::ReadAllBytes($path)[0] | Should Not Be 0xEF
        $baseline = Get-TagDefinitionBaseline -Path $path
        $baseline.AuditedAt | Should Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        @($baseline.Definitions).Count | Should Be 2
        $baseline.Definitions[0].NoteText | Should BeExactly $noteText
    }

    It 'keeps a single definition as an array' {
        $path = Join-Path -Path $TestDrive -ChildPath 'baseline-single.json'
        Save-TagDefinitionBaseline -Path $path -Definitions @(Get-TestDefinition -Tag 'A' -NoteText 'a')
        @((Get-TagDefinitionBaseline -Path $path).Definitions).Count | Should Be 1
    }

    It 'writes nothing with -WhatIf' {
        $path = Join-Path -Path $TestDrive -ChildPath 'baseline-whatif.json'
        Save-TagDefinitionBaseline -Path $path -Definitions @(Get-TestDefinition -Tag 'A' -NoteText 'a') -WhatIf
        Test-Path -LiteralPath $path | Should Be $false
    }

    It 'returns $null for a missing, corrupt, or incomplete baseline file' {
        Get-TagDefinitionBaseline -Path (Join-Path -Path $TestDrive -ChildPath 'no-baseline.json') | Should Be $null
        Get-TagDefinitionBaseline -Path (Write-TestFile -Name 'baseline-corrupt.json' -Text '{ not json') | Should Be $null
        Get-TagDefinitionBaseline -Path (Write-TestFile -Name 'baseline-incomplete.json' -Text '{ "AuditedAt": "x" }') | Should Be $null
    }
}

Describe 'Compare-TagDefinition' {
    $reference = @(
        (Get-TestDefinition -Tag 'Fantasy' -NoteText 'Magic worlds.'),
        (Get-TestDefinition -Tag 'LitRPG' -NoteText 'Game mechanics.'),
        (Get-TestDefinition -Tag 'Romance' -NoteText 'Love story.')
    )

    It 'reports no changes for identical definitions' {
        $change = Compare-TagDefinition -Reference $reference -Difference $reference
        $change.HasChanges | Should Be $false
        @($change.Added).Count + @($change.Removed).Count + @($change.Changed).Count | Should Be 0
    }

    It 'reports added, removed, and changed tags, each sorted' {
        $difference = @(
            (Get-TestDefinition -Tag 'Fantasy' -NoteText 'Worlds with systematic magic.'),
            (Get-TestDefinition -Tag 'LitRPG' -NoteText 'Game mechanics.'),
            (Get-TestDefinition -Tag 'Zombies' -NoteText 'Undead.'),
            (Get-TestDefinition -Tag 'Cozy' -NoteText 'Low stakes.')
        )
        $change = Compare-TagDefinition -Reference $reference -Difference $difference
        $change.HasChanges | Should Be $true
        @($change.Added) -join ',' | Should Be 'Cozy,Zombies'
        @($change.Removed) -join ',' | Should Be 'Romance'
        @($change.Changed) -join ',' | Should Be 'Fantasy'
    }

    It 'ignores whitespace-only edits of the note text' {
        $difference = @(
            (Get-TestDefinition -Tag 'Fantasy' -NoteText "  Magic`r`n  worlds.  "),
            (Get-TestDefinition -Tag 'LitRPG' -NoteText 'Game  mechanics.'),
            (Get-TestDefinition -Tag 'Romance' -NoteText 'Love story.')
        )
        (Compare-TagDefinition -Reference $reference -Difference $difference).HasChanges | Should Be $false
    }

    It 'matches tag names without regard to case, like Calibre' {
        $difference = @(
            (Get-TestDefinition -Tag 'fantasy' -NoteText 'Magic worlds.'),
            (Get-TestDefinition -Tag 'LITRPG' -NoteText 'Game mechanics.'),
            (Get-TestDefinition -Tag 'Romance' -NoteText 'Love story.')
        )
        (Compare-TagDefinition -Reference $reference -Difference $difference).HasChanges | Should Be $false
    }

    It 'reports a change of the note text case' {
        $difference = @(
            (Get-TestDefinition -Tag 'Fantasy' -NoteText 'magic worlds.'),
            (Get-TestDefinition -Tag 'LitRPG' -NoteText 'Game mechanics.'),
            (Get-TestDefinition -Tag 'Romance' -NoteText 'Love story.')
        )
        @((Compare-TagDefinition -Reference $reference -Difference $difference).Changed) -join ',' | Should Be 'Fantasy'
    }

    It 'reports every tag as added against an empty baseline' {
        $change = Compare-TagDefinition -Reference @() -Difference $reference
        @($change.Added).Count | Should Be 3
    }
}

Describe 'Format-TagDefinitionChange' {
    It 'returns nothing when nothing changed' {
        $change = [PSCustomObject]@{ Added = @(); Removed = @(); Changed = @(); HasChanges = $false }
        @(Format-TagDefinitionChange -Change $change -AuditedAt '2026-10-03 10:00:00').Count | Should Be 0
    }

    It 'lists the changes with the audit date and recommends the full re-check' {
        $change = [PSCustomObject]@{ Added = @('Cozy'); Removed = @(); Changed = @('Fantasy', 'LitRPG'); HasChanges = $true }
        $lines = @(Format-TagDefinitionChange -Change $change -AuditedAt '2026-10-03 10:00:00')
        $lines[0] | Should BeExactly 'Tag definitions changed since the last full audit (2026-10-03 10:00:00): added: Cozy; changed: Fantasy, LitRPG.'
        $lines[1] | Should Match '-ChangedWithinDays 0'
        $lines[1] | Should Match '-FullContent'
        ($lines -join ' ') | Should Not Match 'Tag browser'
        $lines[-1] | Should Match 'repeats until'
    }

    It 'adds the Calibre hint only when tags were removed' {
        $change = [PSCustomObject]@{ Added = @(); Removed = @('Romance'); Changed = @(); HasChanges = $true }
        $lines = @(Format-TagDefinitionChange -Change $change -AuditedAt '')
        $lines[0] | Should BeExactly 'Tag definitions changed since the last full audit: removed: Romance.'
        ($lines -join ' ') | Should Match 'Tag browser'
    }
}
