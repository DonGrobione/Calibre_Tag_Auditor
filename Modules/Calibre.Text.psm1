<#
.SYNOPSIS
    Text and JSON helpers for the Calibre Tag Auditor scripts.

.DESCRIPTION
    Repair-MojibakeText repairs mojibake, i.e. UTF-8 text that was decoded as Windows-1252 or ISO-8859-1 (such as "Ã¼" instead of "ü" or "â€™" instead of "’"). Only the garbled character sequences are replaced, each by exactly one strictly decoded UTF-8 character, so correct text around them, including characters outside ISO-8859-1, stays unchanged.
    Get-JsonText extracts the first complete JSON array or object from a raw text such as an LLM answer. Restore-JsonEscapedCharacter turns the escapes that Windows PowerShell 5.1 writes for &, ', <, and > back into the characters. Test-CalibreUuid checks that a value is a canonical Calibre UUID, which is safe as a file name.
    The module is pure: it neither logs nor writes files.

.PARAMETER Text
    Repair-MojibakeText: text to repair.

.PARAMETER RawText
    Get-JsonText: text that contains JSON.

.PARAMETER Json
    Restore-JsonEscapedCharacter: JSON text written by ConvertTo-Json.

.PARAMETER Uuid
    Test-CalibreUuid: value to check.

.NOTES
    Filename: Modules\Calibre.Text.psm1
    The module version is maintained in Modules\Calibre.Text.psd1.
#>

# Repairs mojibake, i.e. UTF-8 text that was decoded as Windows-1252 or ISO-8859-1 (such as "Ã¼" instead of "ü" or "â€™" instead of "’"), in up to four rounds for text that was garbled several times.
# Only the garbled character sequences are replaced, each by exactly one valid UTF-8 character, so correct text around them stays unchanged; a sequence that does not decode cleanly is kept as it is.
# Detected are the UTF-8 lead bytes 0xC2-0xC5 (Latin-1 letters such as umlauts and accents, Œ, Š, Ž) and 0xE2 (punctuation such as – — ’ “ ” … € ™), which cover Western text; the check is case-sensitive, so correct letters such as "ã" or "â" do not start a repair.
function Repair-MojibakeText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    # Map the characters that Windows-1252 shows for the bytes 0x80-0x9F back to their byte values.
    $windows1252 = [System.Text.Encoding]::GetEncoding(1252)
    $byteByCharacter = @{}
    foreach ($byteValue in 0x80..0x9F) {
        $character = $windows1252.GetString([byte[]]@($byteValue))
        if ($character.Length -eq 1 -and [int][char]$character -gt 0xFF) {
            $byteByCharacter[[int][char]$character] = [byte]$byteValue
        }
    }

    $continuation = '[\u0080-\u00BF\u0152\u0153\u0160\u0161\u0178\u017D\u017E\u0192\u02C6\u02DC\u2013\u2014\u2018-\u201A\u201C-\u201E\u2020-\u2022\u2026\u2030\u2039\u203A\u20AC\u2122]'
    $pattern = '[\u00C2-\u00C5]{0}|\u00E2{0}{0}' -f $continuation
    $strictUtf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false, $true

    $repairSequence = {
        param($match)

        $bytes = New-Object -TypeName 'byte[]' -ArgumentList $match.Value.Length
        for ($index = 0; $index -lt $match.Value.Length; $index++) {
            $code = [int]$match.Value[$index]
            if ($code -le 0xFF) {
                $bytes[$index] = [byte]$code
            }
            elseif ($byteByCharacter.ContainsKey($code)) {
                $bytes[$index] = $byteByCharacter[$code]
            }
            else {
                return $match.Value
            }
        }

        try {
            $decoded = $strictUtf8.GetString($bytes)
        }
        catch {
            return $match.Value
        }

        if ($decoded.Length -ne 1) {
            return $match.Value
        }

        return $decoded
    }

    $current = $Text
    for ($round = 0; $round -lt 4; $round++) {
        if ($current -cnotmatch $pattern) {
            break
        }

        $repaired = [System.Text.RegularExpressions.Regex]::Replace($current, $pattern, $repairSequence)
        if ($repaired -ceq $current) {
            break
        }

        $current = $repaired
    }

    return $current
}

# Returns the first complete JSON array or object of a raw text (e.g. an LLM answer with prose or code fences around the JSON), found by bracket depth outside of strings; when the brackets never close, the text up to the last closing bracket; $null when the text holds no bracket.
function Get-JsonText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RawText
    )

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return $null
    }

    $firstArray = $RawText.IndexOf('[')
    $firstObject = $RawText.IndexOf('{')
    if ($firstArray -eq -1 -and $firstObject -eq -1) {
        return $null
    }

    if ($firstArray -ge 0 -and ($firstArray -le $firstObject -or $firstObject -eq -1)) {
        $start = $firstArray
    }
    else {
        $start = $firstObject
    }

    $depth = 0
    $inString = $false
    $escape = $false

    for ($i = $start; $i -lt $RawText.Length; $i++) {
        $character = $RawText[$i]

        if ($escape) {
            $escape = $false
            continue
        }

        if ($character -eq '\') {
            $escape = $true
            continue
        }

        if ($character -eq '"') {
            $inString = -not $inString
            continue
        }

        if (-not $inString) {
            if ($character -eq '[' -or $character -eq '{') {
                $depth++
            }
            elseif ($character -eq ']' -or $character -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    return $RawText.Substring($start, $i - $start + 1)
                }
            }
        }
    }

    $lastClose = [Math]::Max($RawText.LastIndexOf(']'), $RawText.LastIndexOf('}'))
    if ($lastClose -gt $start) {
        return $RawText.Substring($start, $lastClose - $start + 1)
    }

    return $null
}

# Turns the escapes that Windows PowerShell 5.1 ConvertTo-Json writes for &, ', <, and > back into the characters. Only these four escapes are changed, and only when their backslash is not itself escaped, so control character escapes and literal backslash-u text stay unchanged.
function Restore-JsonEscapedCharacter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Json
    )

    return [System.Text.RegularExpressions.Regex]::Replace($Json, '(?<!\\)((?:\\\\)*)\\u00(26|27|3[cCeE])', {
            param($match)
            return $match.Groups[1].Value + [char][Convert]::ToInt32($match.Groups[2].Value, 16)
        })
}

# Returns $true when the value is a Calibre UUID in the canonical form 8-4-4-4-12 hex digits, so it can safely be used as a file name.
function Test-CalibreUuid {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Uuid
    )

    # \z instead of $, because $ also matches before a trailing line break.
    return ($Uuid -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z')
}

Export-ModuleMember -Function Repair-MojibakeText, Get-JsonText, Restore-JsonEscapedCharacter, Test-CalibreUuid
