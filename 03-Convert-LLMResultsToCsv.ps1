<#
.SYNOPSIS
    Convert JSON result files into a single CSV output.

.DESCRIPTION
    Reads all JSON files from the input folder, unwraps the JSON result payloads
    written by the LLM step, repairs mojibake from malformed input text,
    preserves German umlauts and special characters, merges the extracted
    records, and exports the result to a single CSV file. When the default
    output path is used, the output file name
    includes the timestamp from the first input file. For non-success result
    files, validation and parse metadata are added as separate rows.

.PARAMETER InputFolder
    Folder with JSON files to convert.

.PARAMETER OutputCsv
    Path to the output CSV file. Defaults to the 03-CSV folder.
    The exported CSV uses the pipe delimiter '|'.
    The file is written as UTF-8 with BOM so German umlauts and special characters are preserved.

.NOTES
    Version: 1.11
#>

param(
    [string]$InputFolder = ".\02-LLM-Result",
    [string]$OutputCsv = ".\03-CSV\03-LLM-Result.csv"
)

# Repair common mojibake text issues caused by incorrect UTF-8 or Latin-1 decoding.
function Repair-Mojibake {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text -notmatch 'Ã|Â') { return $Text }

    try {
        $latin1Bytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($Text)
        $decoded = [System.Text.Encoding]::UTF8.GetString($latin1Bytes)
        if (-not [string]::IsNullOrWhiteSpace($decoded) -and $decoded -ne $Text) {
            return $decoded
        }
    } catch {
        return $Text
    }

    return $Text
}

# Try to restore malformed or misdecoded JSON text into a parsable format.
function Repair-JsonText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    try {
        ConvertFrom-Json -InputObject $Text -ErrorAction Stop | Out-Null
        return $Text
    } catch {}

    if ($Text -notmatch 'Ã|Â') {
        return $Text
    }

    try {
        $latin1Bytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($Text)
        $decoded = [System.Text.Encoding]::UTF8.GetString($latin1Bytes)
        try {
            ConvertFrom-Json -InputObject $decoded -ErrorAction Stop | Out-Null
            return $decoded
        } catch {}
    } catch {}

    return $Text
}

# Recursively process JSON values so strings are cleaned and nested structures are preserved.
function Convert-JsonValues {
    param([object]$Item)
    if ($null -eq $Item) { return $null }

    if ($Item -is [string]) {
        return Repair-Mojibake -Text $Item
    }

    if ($Item -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Item.Keys) {
            $fixedKey = Repair-Mojibake -Text $key
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

# Extract the first valid JSON block from raw text even if extra text surrounds it.
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

# Build a CSV row from an object using all known columns.
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

function Get-ParsedJsonObjectFromFile {
    param([string]$FilePath)

    $rawBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }

    $jsonText = Get-JsonText -RawText $raw
    if (-not $jsonText) {
        throw "No JSON structure found in file: $FilePath"
    }

    $jsonText = Repair-JsonText -Text $jsonText
    return ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
}

$ErrorActionPreference = 'Stop'

try {
    # Resolve the input path and load all JSON files from the results folder.
    $inputFolderFull = Resolve-Path -Path $InputFolder -ErrorAction Stop

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

    # Read each JSON file, parse its content, and collect all objects for the combined export.
    $allObjects = @()
    foreach ($file in $files) {
        Write-Host "Processing: $($file.Name)"

        try {
            $parsed = Get-ParsedJsonObjectFromFile -FilePath $file.FullName
        }
        catch {
            Write-Warning "Failed to process $($file.Name): $($_.Exception.Message)"
            continue
        }

        if ($null -ne $parsed.records) {
            $records = $parsed.records
            if ($records -is [System.Collections.IEnumerable] -and -not ($records -is [string])) {
                foreach ($item in $records) { $allObjects += $item }
            }
            elseif ($null -ne $records) {
                $allObjects += $records
            }

            if ($parsed.status -and $parsed.status -ne 'success') {
                $allObjects += [pscustomobject]@{
                    source_file              = $parsed.source_file
                    agent_id                 = $parsed.agent_id
                    status                   = $parsed.status
                    input_unique_book_count = $parsed.input_unique_book_count
                    output_unique_book_count = $parsed.output_unique_book_count
                    unique_book_count_match = $parsed.unique_book_count_match
                    validation_error         = $parsed.validation_error
                    parse_error              = $parsed.parse_error
                    raw_response             = $parsed.raw_response
                }
            }
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

    # Clean all values and normalize them into a consistent object format.
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

    # Write the combined data as UTF-8 CSV with a pipe delimiter.
    $csvContent = $csvRows | ConvertTo-Csv -NoTypeInformation -Delimiter '|'
    $csvContent | Out-File -FilePath $csvPath -Encoding UTF8 -Force
    Write-Host "CSV file created: $csvPath"
}
catch {
    Write-Error "CSV conversion failed: $($_.Exception.Message)"
    throw
}