<#
.SYNOPSIS
    Pester tests for the Calibre.Text module.

.DESCRIPTION
    Covers Repair-MojibakeText: garbled umlauts and typographic characters from Windows-1252 and ISO-8859-1 are repaired, text garbled twice is repaired, and correct text (also next to garbled text and with characters outside ISO-8859-1) stays unchanged.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Calibre.Text.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1') -Force

Describe 'Calibre.Text manifest' {
    $manifest = Test-ModuleManifest -Path (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1')

    It 'exports only Repair-MojibakeText' {
        @($manifest.ExportedFunctions.Keys) -join ',' | Should Be 'Repair-MojibakeText'
    }

    It 'requires PowerShell 5.1 and names the author' {
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
        $manifest.Author | Should Be 'DonGrobione'
    }
}
Describe 'Repair-MojibakeText' {
    # The test strings are built from character codes, so this file does not depend on how an editor shows the garbled characters.
    $uUmlaut = [string][char]0xFC
    $garbledUUmlaut = [string][char]0xC3 + [char]0xBC
    $doubleGarbledUUmlaut = [string][char]0xC3 + [char]0x0192 + [char]0xC2 + [char]0xBC
    $rightQuote = [string][char]0x2019
    $garbledRightQuote = [string][char]0xE2 + [char]0x20AC + [char]0x2122
    $enDash = [string][char]0x2013
    $garbledEnDash = [string][char]0xE2 + [char]0x20AC + [char]0x201C
    $garbledLatin1EnDash = [string][char]0xE2 + [char]0x80 + [char]0x93
    $sharpS = [string][char]0xDF
    $leftLowQuote = [string][char]0x201E
    $leftQuote = [string][char]0x201C

    It 'repairs a garbled umlaut' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung" | Should BeExactly "Begr$($uUmlaut)ndung"
    }

    It 'repairs garbled umlauts next to correct umlauts' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung f$($uUmlaut)r" | Should BeExactly "Begr$($uUmlaut)ndung f$($uUmlaut)r"
    }

    It 'keeps typographic characters that are not garbled' {
        Repair-MojibakeText -Text "Begr$($garbledUUmlaut)ndung $enDash it$($rightQuote)s" | Should BeExactly "Begr$($uUmlaut)ndung $enDash it$($rightQuote)s"
    }

    It 'repairs garbled typographic characters from Windows-1252 and ISO-8859-1' {
        Repair-MojibakeText -Text "it$($garbledRightQuote)s" | Should BeExactly "it$($rightQuote)s"
        Repair-MojibakeText -Text "A $garbledEnDash B" | Should BeExactly "A $enDash B"
        Repair-MojibakeText -Text "A $garbledLatin1EnDash B" | Should BeExactly "A $enDash B"
    }

    It 'repairs text that was garbled twice' {
        Repair-MojibakeText -Text "Begr$($doubleGarbledUUmlaut)ndung" | Should BeExactly "Begr$($uUmlaut)ndung"
    }

    It 'leaves correct text with a-circumflex, a-tilde, and capital A-tilde unchanged' {
        $text = "liver p$([char]0xE2)t$([char]0xE9), S$([char]0xE3)o Paulo, S$([char]0xC3)O PAULO"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'leaves a word ending in sharp s before a closing German quote unchanged' {
        $text = "$($leftLowQuote)Gro$($sharpS)$($leftQuote)"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'keeps a sequence that is not valid UTF-8' {
        $text = "A$([char]0xC3) B"
        Repair-MojibakeText -Text $text | Should BeExactly $text
    }

    It 'returns empty and whitespace text unchanged' {
        Repair-MojibakeText -Text '' | Should BeExactly ''
        Repair-MojibakeText -Text '  ' | Should BeExactly '  '
    }
}

Describe 'Repair-MojibakeText keeps characters outside ISO-8859-1' {
    It 'keeps Japanese text and typographic characters next to a garbled umlaut' {
        $japanese = [string][char]0x3088 + [char]0x3046 + [char]0x3053 + [char]0x305D
        $text = "$japanese $([char]0x2013) M$([char]0xC3)$([char]0xBC)ller"
        Repair-MojibakeText -Text $text | Should BeExactly "$japanese $([char]0x2013) M$([char]0xFC)ller"
    }
}