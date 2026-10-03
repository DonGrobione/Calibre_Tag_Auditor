<#
.SYNOPSIS
    Text encoding helpers for the Calibre Tag Auditor scripts.

.DESCRIPTION
    Repair-MojibakeText repairs mojibake, i.e. UTF-8 text that was decoded as Windows-1252 or ISO-8859-1 (such as "Ã¼" instead of "ü" or "â€™" instead of "’"). Only the garbled character sequences are replaced, each by exactly one strictly decoded UTF-8 character, so correct text around them, including characters outside ISO-8859-1, stays unchanged.
    The module is pure: it neither logs nor writes files.

.PARAMETER Text
    Text to repair.

.NOTES
    Filename: Modules\Calibre.Text.psm1
    The module version is maintained in Modules\Calibre.Text.psd1.
#>

# Repairs mojibake, i.e. UTF-8 text that was decoded as Windows-1252 or ISO-8859-1 (such as "Ã¼" instead of "ü" or "â€™" instead of "’"), in up to four rounds for text that was garbled several times.
# Only the garbled character sequences are replaced, each by exactly one valid UTF-8 character, so correct text around them stays unchanged; a sequence that does not decode cleanly is kept as it is.
# Detected are the UTF-8 lead bytes 0xC2-0xC5 (Latin-1 letters such as umlauts and accents, Œ, Š, Ž) and 0xE2 (punctuation such as – — ’ “ ” … € ™), which cover Western text; the check is case-sensitive, so correct letters such as "ã" or "â" do not start a repair.
function Repair-MojibakeText {
    param([string]$Text)

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

Export-ModuleMember -Function Repair-MojibakeText
