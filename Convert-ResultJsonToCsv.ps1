<#
.SYNOPSIS
    Converts all JSON files in the Ergebnis directory to CSV format.

.DESCRIPTION
    Reads each JSON file in the 'Ergebnis' folder and saves it in the same directory
    as a CSV file with the same base name. Uses semicolon as the delimiter.

.PARAMETER ResultDirectory
    Optional path to the directory containing JSON files to convert.
    Defaults to the 'Ergebnis' subdirectory of the script directory.

.PARAMETER OutputDirectory
    Optional path to the directory where CSV files will be saved.
    Defaults to the same as ResultDirectory.

.PARAMETER Delimiter
    The delimiter character to use in the CSV output.
    Defaults to semicolon (";").

.PARAMETER Encoding
    The text encoding to use for CSV output.
    Defaults to UTF8.

.PARAMETER Force
    If specified, overwrites existing CSV files without warning.

.EXAMPLE
    .\Convert-ResultJsonToCsv.ps1
    Converts all JSON files in the default Ergebnis directory to CSV.

.EXAMPLE
    .\Convert-ResultJsonToCsv.ps1 -ResultDirectory "C:\data\json" -OutputDirectory "C:\data\csv"
    Converts JSON files from a custom directory and saves CSV files to a different directory.

.EXAMPLE
    .\Convert-ResultJsonToCsv.ps1 -Delimiter ","
    Converts JSON files to CSV using comma as the delimiter.

.NOTES
    PowerShell Version: 5.1+
    Version: 1.0

    The script will skip any files that cannot be parsed as JSON.
    Each JSON file is converted to a CSV file with the same base name.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$ResultDirectory,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [char]$Delimiter = ";",

    [Parameter(Mandatory = $false)]
    [ValidateSet('UTF8', 'ASCII', 'Unicode', 'UTF7', 'UTF32', 'BigEndianUnicode')]
    [string]$Encoding = 'UTF8',

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Set error action preference
$ErrorActionPreference = "Stop"

try {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    if ([string]::IsNullOrWhiteSpace($ResultDirectory)) {
        $ResultDir = Join-Path -Path $ScriptDir -ChildPath "Ergebnis"
    } else {
        $ResultDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultDirectory)
    }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDir = $ResultDir
    } else {
        $OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    }

    if (-not (Test-Path -Path $ResultDir -PathType Container)) {
        Write-Error "Error: Result directory '$ResultDir' does not exist or is not accessible."
        return
    }

    if (-not (Test-Path -Path $OutputDir -PathType Container)) {
        try {
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Host "Created output directory: $OutputDir" -ForegroundColor Green
        } catch {
            Write-Error "Error: Failed to create output directory '$OutputDir': $_"
            return
        }
    }

    $JsonFiles = Get-ChildItem -Path $ResultDir -Filter "*.json" -File | Sort-Object Name

    if ($JsonFiles.Count -eq 0) {
        Write-Warning "No JSON files found in directory '$ResultDir'."
        return
    }

    Write-Host "Found $($JsonFiles.Count) JSON file(s) to convert." -ForegroundColor Cyan
    Write-Host "Result directory: $ResultDir" -ForegroundColor Cyan
    Write-Host "Output directory: $OutputDir" -ForegroundColor Cyan
    Write-Host "CSV delimiter: '$Delimiter'" -ForegroundColor Cyan
    Write-Host "Encoding: $Encoding" -ForegroundColor Cyan

    $SuccessCount = 0
    $ErrorCount = 0

    foreach ($JsonFile in $JsonFiles) {
        $FileName = $JsonFile.Name
        $CsvPath = Join-Path -Path $OutputDir -ChildPath ([System.IO.Path]::ChangeExtension($JsonFile.Name, ".csv"))

        if (-not $Force -and (Test-Path -Path $CsvPath)) {
            Write-Warning "Skipping '$FileName' - CSV file already exists. Use -Force to overwrite."
            $ErrorCount++
            continue
        }

        Write-Host "Converting: $FileName" -ForegroundColor Cyan

        try {
            $Content = Get-Content -Path $JsonFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $JsonData = $null

            try {
                $JsonData = $Content | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $Raw = $Content.Trim()
                $Start = $Raw.IndexOf('[')
                $End = $Raw.LastIndexOf(']')

                if ($Start -ge 0 -and $End -gt $Start) {
                    $JsonText = $Raw.Substring($Start, $End - $Start + 1)
                    $JsonData = $JsonText | ConvertFrom-Json -ErrorAction Stop
                } else {
                    throw $_
                }
            }

            if ($null -eq $JsonData) {
                Write-Error "Error: File '$FileName' contains no valid JSON data."
                $ErrorCount++
                continue
            }

            $Items = @($JsonData)

            if ($Items.Count -eq 0) {
                Write-Warning "Warning: File '$FileName' contains empty JSON array."
                $ErrorCount++
                continue
            }

            $Columns = [System.Collections.ArrayList]@()
            foreach ($Item in $Items) {
                if ($Item -is [System.Management.Automation.PSObject]) {
                    foreach ($Prop in $Item.PSObject.Properties.Name) {
                        if (-not $Columns.Contains($Prop)) {
                            $Columns.Add($Prop) | Out-Null
                        }
                    }
                }
            }

            if ($Columns.Count -eq 0) {
                Write-Error "Error: No columns found in '$FileName'."
                $ErrorCount++
                continue
            }

            $Rows = @()
            foreach ($Item in $Items) {
                $Obj = [ordered]@{}
                foreach ($Col in $Columns) {
                    $Value = $null
                    if ($Item.PSObject.Properties.Match($Col).Count -gt 0) {
                        $Value = $Item.$Col
                    }
                    $Obj[$Col] = $Value
                }
                $Rows += New-Object PSObject -Property $Obj
            }

            try {
                $Rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding $Encoding -Delimiter $Delimiter -Force -ErrorAction Stop
                Write-Host "  -> Saved as: $([System.IO.Path]::GetFileName($CsvPath))" -ForegroundColor Green
                $SuccessCount++
            } catch {
                Write-Error "Error writing CSV file '$CsvPath': $_"
                $ErrorCount++
            }

        } catch {
            Write-Error "Error processing file '$FileName': $_"
            $ErrorCount++
        }
    }

    Write-Host "Conversion complete. Success: $SuccessCount, Errors: $ErrorCount" -ForegroundColor Cyan

    if ($ErrorCount -gt 0) {
        return
    }

    Write-Host "All files converted successfully." -ForegroundColor Cyan
} catch {
    Write-Error "Fatal error: $_"
    throw
}
