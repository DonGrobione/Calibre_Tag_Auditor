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
    Path to the output CSV file.

.NOTES
    Version: 1.2
#>

param(
    [string]$InputFolder = ".\02-LLM-Result",
    [string]$OutputCsv = ".\03-CSV\Ergebnis_All.csv"
)

function Remove-Markdown {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $clean = $Text
    $clean = $clean -replace '(?ms)```.*?```', ''
    $clean = $clean -replace '(?ms)~~~.*?~~~', ''
    $clean = $clean -replace '!\[([^\]]*)\]\([^\)]*\)', '$1'
    $clean = $clean -replace '(^|\r?\n)\s{0,3}#{1,6}\s*', '$1'
    $clean = $clean -replace '(^|\r?\n)\s*([-+*]|\d+\.)\s+', '$1'
    $clean = $clean -replace '(^|\r?\n)\s{0,3}>\s*', '$1'
    $clean = $clean -replace '(\*\*|__)(.*?)\1', '$2'
    $clean = $clean -replace '(\*|_)(.*?)\1', '$2'
    $clean = $clean -replace '`([^`]*)`', '$1'
    $clean = $clean -replace '\s{2,}', ' '
    return $clean.Trim()
}

function Convert-JsonValues {
    param([object]$Item)
    if ($null -eq $Item) { return $null }

    if ($Item -is [string]) {
        return Remove-Markdown -Text $Item
    }

    if ($Item -is [System.Collections.IDictionary]) {
        foreach ($key in $Item.Keys) {
            $Item[$key] = Convert-JsonValues -Item $Item[$key]
        }
        return $Item
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

$allObjects = @()
foreach ($file in $files) {
    Write-Host "Processing: $($file.Name)"
    $raw = Get-Content -Path $file.FullName -Encoding UTF8 -Raw
    $jsonText = Get-JsonText -RawText $raw
    if (-not $jsonText) {
        Write-Warning "No JSON structure found in file: $($file.Name)"
        continue
    }

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

$csvRows | Export-Csv -Path $csvPath -NoTypeInformation -Force -Encoding UTF8
Write-Host "CSV file created: $csvPath"