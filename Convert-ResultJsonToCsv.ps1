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
    
    Requires: Modules\Write-Log.psm1
    
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

# Import the logging module
$ModulePath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath "Modules\Write-Log.psm1"
if (Test-Path -Path $ModulePath) {
    Import-Module -Name $ModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning "Logging module not found at '$ModulePath'. Using native Write-Host for output."
}

# Set error action preference
$ErrorActionPreference = "Stop"

# Main execution with top-level try/catch
try {
    # Determine the script directory
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # Resolve result directory
    if ([string]::IsNullOrWhiteSpace($ResultDirectory)) {
        $ResultDir = Join-Path -Path $ScriptDir -ChildPath "Ergebnis"
    } else {
        $ResultDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultDirectory)
    }

    # Resolve output directory
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDir = $ResultDir
    } else {
        $OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    }

    # Validate paths
    if (-not (Test-Path -Path $ResultDir -PathType Container)) {
        if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Error: Result directory '$ResultDir' does not exist or is not accessible." -Level ERROR
        } else {
            Write-Error "Error: Result directory '$ResultDir' does not exist or is not accessible."
        }
        return
    }

    # Ensure output directory exists
    if (-not (Test-Path -Path $OutputDir -PathType Container)) {
        try {
            New-Item -Path $OutputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Created output directory: $OutputDir" -Level INFO
            }
        } catch {
            if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Error: Failed to create output directory '$OutputDir': $_" -Level ERROR
            } else {
                Write-Error "Error: Failed to create output directory '$OutputDir': $_"
            }
            return
        }
    }

    # Get JSON files
    $JsonFiles = Get-ChildItem -Path $ResultDir -Filter "*.json" -File | Sort-Object Name

    if ($JsonFiles.Count -eq 0) {
        if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "No JSON files found in directory '$ResultDir'." -Level WARNING
        } else {
            Write-Host "No JSON files found in directory '$ResultDir'." -ForegroundColor Yellow
        }
        return
    }

    if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Found $($JsonFiles.Count) JSON file(s) to convert." -Level INFO
        Write-Log -Message "Result directory: $ResultDir" -Level DEBUG
        Write-Log -Message "Output directory: $OutputDir" -Level DEBUG
        Write-Log -Message "CSV delimiter: '$Delimiter'" -Level DEBUG
        Write-Log -Message "Encoding: $Encoding" -Level DEBUG
    } else {
        Write-Host "Found $($JsonFiles.Count) JSON file(s) to convert." -ForegroundColor Cyan
    }

    # Process each JSON file
    $SuccessCount = 0
    $ErrorCount = 0

    foreach ($JsonFile in $JsonFiles) {
        $FileName = $JsonFile.Name
        $CsvPath = Join-Path -Path $OutputDir -ChildPath ([System.IO.Path]::ChangeExtension($JsonFile.Name, ".csv"))

        # Check if CSV file already exists
        if (-not $Force -and (Test-Path -Path $CsvPath)) {
            if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Skipping '$FileName' - CSV file already exists. Use -Force to overwrite." -Level WARNING
            } else {
                Write-Host "Skipping '$FileName' - CSV file already exists. Use -Force to overwrite." -ForegroundColor Yellow
            }
            $ErrorCount++
            continue
        }

        if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Converting: $FileName" -Level INFO
        } else {
            Write-Host "Converting: $FileName" -ForegroundColor Cyan
        }

        try {
            # Read and parse JSON content
            $Content = Get-Content -Path $JsonFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            
            # Try to parse as JSON
            $JsonData = $null
            try {
                $JsonData = $Content | ConvertFrom-Json -ErrorAction Stop
            } catch {
                # Try to extract JSON from content (handle cases where JSON is embedded)
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
                if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Error: File '$FileName' contains no valid JSON data." -Level ERROR
                } else {
                    Write-Error "Error: File '$FileName' contains no valid JSON data."
                }
                $ErrorCount++
                continue
            }

            # Normalize to array
            if ($JsonData -is [System.Collections.IEnumerable] -and -not ($JsonData -is [string])) {
                $Items = @($JsonData)
            } else {
                $Items = @($JsonData)
            }

            if ($Items.Count -eq 0) {
                if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Warning: File '$FileName' contains empty JSON array." -Level WARNING
                } else {
                    Write-Warning "Warning: File '$FileName' contains empty JSON array."
                }
                $ErrorCount++
                continue
            }

            # Collect all property names from all items to create consistent columns
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
                if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Error: No columns found in '$FileName'." -Level ERROR
                } else {
                    Write-Error "Error: No columns found in '$FileName'."
                }
                $ErrorCount++
                continue
            }

            # Build rows with consistent columns
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

            # Export to CSV
            try {
                $Rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding $Encoding -Delimiter $Delimiter -Force -ErrorAction Stop
                
                if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "  -> Saved as: $([System.IO.Path]::GetFileName($CsvPath))" -Level INFO
                } else {
                    Write-Host "  -> Saved as: $([System.IO.Path]::GetFileName($CsvPath))" -ForegroundColor Green
                }
                $SuccessCount++
            } catch {
                if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Error writing CSV file '$CsvPath': $_" -Level ERROR
                } else {
                    Write-Error "Error writing CSV file '$CsvPath': $_"
                }
                $ErrorCount++
            }

        } catch {
            if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
                Write-Log -Message "Error processing file '$FileName': $_" -Level ERROR
            } else {
                Write-Error "Error processing file '$FileName': $_"
            }
            $ErrorCount++
        }
    }

    # Summary
    if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Conversion complete. Success: $SuccessCount, Errors: $ErrorCount" -Level INFO
    } else {
        Write-Host "Conversion complete. Success: $SuccessCount, Errors: $ErrorCount" -ForegroundColor Cyan
    }

    # Return exit code based on results
    if ($ErrorCount -gt 0) {
        if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -Message "Completed with errors." -Level WARNING
        }
        # Note: Not using exit in subscript per rule #4.7
        return
    }

    if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "All files converted successfully." -Level INFO
    }

} catch {
    # Top-level error handling
    if (Get-Module -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message "Fatal error: $_" -Level ERROR
    } else {
        Write-Error "Fatal error: $_"
    }
    # Re-throw to bubble up to orchestrator per rule #4.7
    throw
}
