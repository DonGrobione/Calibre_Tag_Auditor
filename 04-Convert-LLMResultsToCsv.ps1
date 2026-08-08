<#
.SYNOPSIS
    Convert JSON result files into a single CSV output.

.DESCRIPTION
    Reads all JSON files from the input folder, removes Markdown formatting from
    string values, merges the extracted JSON objects, and exports the result
    to a single CSV file.

.PARAMETER InputFolder
    Folder with JSON files to convert.

.PARAMETER OutputCsv
    Path to the output CSV file. Defaults to the 03-CSV folder.
    The exported CSV uses the pipe delimiter '|'.
    The file is written as UTF-8 with BOM so German Umlauts and special characters are preserved.

.NOTES
    Version: 1.5
#>

param(
    [string]$InputFolder = ".\02-LLM-Result",
    [string]$OutputCsv = ".\03-CSV\03-LLM-Result.csv"
)

function Remove-Markdown {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $clean = $Text
    $clean = $clean -replace '(?ms)```.*?```', ''
    $clean = $clean -replace '(?ms)~~~.*?~~~', ''
    $clean = $clean -replace '!(\[[^\]]*\])\([^\)]*\)', '$1'
    $clean = $clean -replace '(^|\r?\n)\s{0,3}#{1,6}\s*', '$1'
    $clean = $clean -replace '(^|\r?\n)\s*([-+*]|\d+\.)\s+', '$1'
    $clean = $clean -replace '(^|\r?\n)\s{0,3}>\s*', '$1'
    $clean = $clean -replace '(\*\*|__)(.*?)\1', '$2'
    $clean = $clean -replace '(\*|_)(.*?)\1', '$2'
    $clean = $clean -replace '`([^`]*)`', '$1'
    $clean = $clean -replace '\s{2,}', ' '
    return $clean.Trim()
}

function Fix-Mojibake {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text -notmatch 'Ã|Â') { return $Text }

    $current = $Text
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $bytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($current)
            $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            break
        }

        if ($decoded -eq $current -or $decoded -match '�') {
            break
        }

        $current = $decoded
    }

    return $current
}

function Repair-JsonText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $current = $Text
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $bytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($current)
            $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            break
        }

        try {
            ConvertFrom-Json -InputObject $decoded -ErrorAction Stop | Out-Null
            return $decoded
        } catch {
            if ($decoded -eq $current) {
                break
            }
            $current = $decoded
        }
    }

    return $Text
}

function Convert-JsonValues {
    param([object]$Item)
    if ($null -eq $Item) { return $null }

    if ($Item -is [string]) {
        $fixedValue = Fix-Mojibake -Text $Item
        return Remove-Markdown -Text $fixedValue
    }

    if ($Item -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Item.Keys) {
            $fixedKey = Fix-Mojibake -Text $key
            $result[$fixedKey] = Convert-JsonValues -Item $Item[$key]
        }
        return $result
    }

    if ($Item -is [System.Collections.IEnumerable] -and -not ($Item -is [string])) {
        $list = @()
        foreach ($element in $Item) {
            $list += Convert-JsonValues -Item $element
        }
        return ,$list
    }

    return $Item
}

function Get-JsonText {
    param([string]$RawText)

    $firstArray = $RawText.IndexOf('[')
    $firstObj = $RawText.IndexOf('{')
    if ($firstArray -eq -1 -and $firstObj -eq -1) { return $null }

    if ($firstArray -ge 0 -and ($firstArray -le $firstObj -or $firstObj -eq -1)) {
        $start = $firstArray
    } else {
        $start = $firstObj
    }

    $depth = 0
    $inString = $false
    $escape = $false

    for ($i = $start; $i -lt $RawText.Length; $i++) {
        $c = $RawText[$i]
        if ($escape) {
            $escape = $false
            continue
        }

        if ($c -eq '\\') {
            $escape = $true
            continue
        }

        if ($c -eq '"') {
            $inString = -not $inString
            continue
        }

        if (-not $inString) {
            if ($c -eq '[' -or $c -eq '{') {
                $depth++
            } elseif ($c -eq ']' -or $c -eq '}') {
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

function Convert-ToCsvRow {
    param(
        [psobject]$Object,
        [string[]]$Columns
    )

    $row = @{}
    foreach ($col in $Columns) {
        $value = if ($Object.PSObject.Properties.Match($col)) { $Object.$col } else { $null }
        if ($null -ne $value -and -not ($value -is [string]) -and ($value -is [System.Collections.IEnumerable])) {
            $value = ConvertTo-Json $value -Compress
        }
        $row[$col] = $value
    }
    return [pscustomobject]$row
}

$ErrorActionPreference = 'Stop'

try {
    $inputFolderFull = Resolve-Path -Path $InputFolder -ErrorAction Stop
} catch {
    Write-Error "Input folder not found: $InputFolder"
    throw
}

$files = Get-ChildItem -Path $inputFolderFull -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $files) {
    Write-Error "No JSON files found in folder: $inputFolderFull"
    throw "No JSON input files found."
}

$firstFile = $files[0]
$firstTimestamp = if ($firstFile.Name -match '_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.json$') { $matches[1] } else { $null }
if ($firstTimestamp -and $OutputCsv -eq ".\03-CSV\03-LLM-Result.csv") {
    $OutputCsv = ".\03-CSV\03-LLM-Result_$firstTimestamp.csv"
}

$allObjects = @()
foreach ($file in $files) {
    Write-Host "Processing: $($file.Name)"
    try {
        $rawBytes = [System.IO.File]::ReadAllBytes($file.FullName)
    } catch {
        Write-Warning "Failed to read $($file.Name): $($_.Exception.Message)"
        continue
    }

    $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }

    $jsonText = Get-JsonText -RawText $raw
    if (-not $jsonText) {
        Write-Warning "No JSON structure found in file: $($file.Name)"
        continue
    }

    $jsonText = Repair-JsonText -Text $jsonText

    try {
        $parsed = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
    } catch {
        Write-Warning "Failed to parse $($file.Name): $($_.Exception.Message)"
        continue
    }

    if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
        foreach ($item in $parsed) { $allObjects += $item }
    } else {
        $allObjects += $parsed
    }
}

if (-not $allObjects) {
    Write-Error "No valid JSON objects were found."
    throw "No valid JSON objects were found."
}

$cleanObjects = @()
foreach ($item in $allObjects) {
    $cleanObjects += Convert-JsonValues -Item $item
}

$allKeys = $cleanObjects | ForEach-Object { $_.PSObject.Properties.Name } | Sort-Object -Unique
$csvRows = $cleanObjects | ForEach-Object { Convert-ToCsvRow -Object $_ -Columns $allKeys }

$csvDir = Split-Path -Path $OutputCsv -Parent
if (-not (Test-Path -Path $csvDir -PathType Container)) {
    New-Item -Path $csvDir -ItemType Directory | Out-Null
}

$csvPath = Join-Path -Path $csvDir -ChildPath (Split-Path -Path $OutputCsv -Leaf)

$csvContent = $csvRows | ConvertTo-Csv -NoTypeInformation -Delimiter '|'
$csvContent | Out-File -FilePath $csvPath -Encoding UTF8 -Force
Write-Host "CSV file created: $csvPath"