<#
.SYNOPSIS
    Pester tests for the Calibre.Text module.

.DESCRIPTION
    Covers the manifest and Repair-MojibakeText: garbled umlauts and typographic characters from Windows-1252 and ISO-8859-1 are repaired, text garbled twice is repaired, and correct text (also next to garbled text and with characters outside ISO-8859-1) stays unchanged. Covers Get-JsonText (JSON inside prose and code fences, brackets inside strings, unclosed brackets), Restore-JsonEscapedCharacter (only the &, apostrophe, <, and > escapes change), and Test-CalibreUuid.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\Calibre.Text.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1') -Force

Describe 'Calibre.Text manifest' {
    $manifest = Test-ModuleManifest -Path (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1')

    It 'exports exactly the public functions' {
        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should Be 'Get-JsonText,Repair-MojibakeText,Restore-JsonEscapedCharacter,Test-CalibreUuid'
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

Describe 'Get-JsonText' {
    It 'returns the first complete JSON object from text with prose and code fences around it' {
        Get-JsonText -RawText 'Here you go: ```json {"Results":[{"Title":"A"}]} ``` Done.' | Should BeExactly '{"Results":[{"Title":"A"}]}'
    }

    It 'returns an array that starts before the first object' {
        Get-JsonText -RawText 'x [{"a":1},{"b":2}] y' | Should BeExactly '[{"a":1},{"b":2}]'
    }

    It 'ignores brackets and escaped quotes inside strings' {
        $text = '{"Reason":"uses [brackets] and \"quotes\" {here}"} trailing }'
        Get-JsonText -RawText $text | Should BeExactly '{"Reason":"uses [brackets] and \"quotes\" {here}"}'
    }

    It 'returns the text up to the last closing bracket when the brackets never close' {
        Get-JsonText -RawText '{"a":[1,2]' | Should BeExactly '{"a":[1,2]'
    }

    It 'returns $null for text without JSON and for empty text' {
        Get-JsonText -RawText 'no json here' | Should Be $null
        Get-JsonText -RawText '' | Should Be $null
        Get-JsonText -RawText $null | Should Be $null
    }
}

Describe 'Restore-JsonEscapedCharacter' {
    It 'turns the escapes for &, apostrophe, <, and > back into the characters' {
        $json = ConvertTo-Json -InputObject ([pscustomobject]@{ Text = "it's <b> & more" }) -Compress
        $restored = Restore-JsonEscapedCharacter -Json $json
        $restored | Should BeExactly '{"Text":"it''s <b> & more"}'
        (ConvertFrom-Json -InputObject $restored).Text | Should BeExactly "it's <b> & more"
    }

    It 'keeps control character escapes' {
        $json = ConvertTo-Json -InputObject ([pscustomobject]@{ Text = 'a' + [char]0x01 + 'b' }) -Compress
        $restored = Restore-JsonEscapedCharacter -Json $json
        $restored | Should Match '\\u0001'
        (ConvertFrom-Json -InputObject $restored).Text | Should BeExactly ('a' + [char]0x01 + 'b')
    }

    It 'keeps literal backslash-u text whose backslash is escaped' {
        # Built from parts, so no editor turns the escape sequences into characters.
        $text = 'literal \' + 'u0026 stays'
        $json = ConvertTo-Json -InputObject ([pscustomobject]@{ Text = $text }) -Compress
        (ConvertFrom-Json -InputObject (Restore-JsonEscapedCharacter -Json $json)).Text | Should BeExactly $text
    }

    It 'returns empty text unchanged' {
        Restore-JsonEscapedCharacter -Json '' | Should BeExactly ''
    }
}

Describe 'Test-CalibreUuid' {
    It 'accepts a canonical UUID in any case' {
        Test-CalibreUuid -Uuid '0f8fad5b-d9cb-469f-a165-70867728950e' | Should Be $true
        Test-CalibreUuid -Uuid '0F8FAD5B-D9CB-469F-A165-70867728950E' | Should Be $true
    }

    It 'rejects empty, braced, and path-like values' {
        Test-CalibreUuid -Uuid '' | Should Be $false
        Test-CalibreUuid -Uuid $null | Should Be $false
        Test-CalibreUuid -Uuid '{0f8fad5b-d9cb-469f-a165-70867728950e}' | Should Be $false
        Test-CalibreUuid -Uuid '..\0f8fad5b-d9cb-469f-a165-70867728950e' | Should Be $false
        Test-CalibreUuid -Uuid "0f8fad5b-d9cb-469f-a165-70867728950e`n" | Should Be $false
    }
}