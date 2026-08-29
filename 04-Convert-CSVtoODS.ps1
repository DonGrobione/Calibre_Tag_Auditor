<#
.SYNOPSIS
    Convert CSV files from 03-CSV to ODS files in 04-ODS and apply formatting.

.DESCRIPTION
    Detects the installed LibreOffice installation, converts every CSV file found in
    03-CSV to ODS using the pipe delimiter, renames each result to the 04-ODS_Convert_*.
    ods pattern with the same timestamp as the source CSV, and applies the requested
    formatting to the generated spreadsheet: automatic line breaks in all cells and
    column widths of A/B = 9 cm, C = 6 cm, D = 18 cm.

.PARAMETER CsvInputFolder
    Folder containing the source CSV files. Defaults to .\03-CSV.

.PARAMETER OdsOutputFolder
    Folder where converted ODS files are written. Defaults to .\04-ODS.

.NOTES
    Version: 1.2
#>

[CmdletBinding()]
param(
    [string]$CsvInputFolder = ".\03-CSV",
    [string]$OdsOutputFolder = ".\04-ODS"
)

# Toggle: delete the source CSV file after it was successfully converted to ODS.
$DeleteCsvAfterConversion = $false

$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '$WriteLogModulePath'"
}

Import-Module -Name $WriteLogModulePath -Force

$ScriptLogName = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { 'UnknownScript' } else { Split-Path -Path $PSCommandPath -Leaf }
$ScriptLogPrefix = "[$ScriptLogName]"

function Write-HostAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator
    )

    $joinSeparator = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    $message = (($Object | ForEach-Object { [string]$_ }) -join $joinSeparator)
    Write-Log -Message "$ScriptLogPrefix $message" -Info
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Write-WarningAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -Warn
    Microsoft.PowerShell.Utility\Write-Warning $text
}

function Write-ErrorAndLog {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$ScriptLogPrefix $text" -IsError
    Microsoft.PowerShell.Utility\Write-Error $text
}

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

function Get-LibreOfficePath {
    $candidatePaths = @(
        "$env:ProgramFiles\LibreOffice\program\soffice.exe",
        "${env:ProgramFiles(x86)}\LibreOffice\program\soffice.exe",
        "$env:LOCALAPPDATA\Programs\LibreOffice\program\soffice.exe",
        "$env:ProgramW6432\LibreOffice\program\soffice.exe"
    )

    foreach ($candidate in $candidatePaths) {
        if ($candidate -and (Test-Path -Path $candidate -PathType Leaf)) {
            return (Resolve-Path -Path $candidate).Path
        }
    }

    $registryPaths = @(
        'HKLM:\SOFTWARE\LibreOffice',
        'HKLM:\SOFTWARE\WOW6432Node\LibreOffice',
        'HKCU:\SOFTWARE\LibreOffice'
    )

    foreach ($regPath in $registryPaths) {
        if (-not (Test-Path -Path $regPath)) { continue }

        $installPath = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstallPath -First 1
        if ($installPath) {
            $candidate = Join-Path -Path $installPath -ChildPath 'program\soffice.exe'
            if (Test-Path -Path $candidate -PathType Leaf) {
                return (Resolve-Path -Path $candidate).Path
            }
        }
    }

    return $null
}

function Get-OfficePythonPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibreOfficeExe
    )

    $binDir = Split-Path -Parent -Path $LibreOfficeExe
    $candidatePaths = @(
        (Join-Path -Path $binDir -ChildPath 'python.exe'),
        (Join-Path -Path $binDir -ChildPath 'python.bat'),
        (Join-Path -Path $binDir -ChildPath 'python3.exe'),
        (Join-Path -Path $binDir -ChildPath 'python3.bat')
    )

    foreach ($candidate in $candidatePaths) {
        if ($candidate -and (Test-Path -Path $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Get-FileTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ($FileName -match '_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.csv$') {
        return $matches[1]
    }

    if ($FileName -match '_(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})\.csv$') {
        return $matches[1].Replace('T', '_')
    }

    return $null
}

function Invoke-LibreOfficeCsvToOds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibreOfficeExe,
        [Parameter(Mandatory = $true)]
        [string]$CsvFilePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder
    )

    $arguments = @(
        '--headless',
        '--convert-to', 'ods',
        '--infilter=CSV:124,34,76',
        '--outdir', $OutputFolder,
        $CsvFilePath
    )

    $expectedOdsPath = Join-Path -Path $OutputFolder -ChildPath (([System.IO.Path]::GetFileNameWithoutExtension($CsvFilePath)) + '.ods')
    if (Test-Path -Path $expectedOdsPath -PathType Leaf) {
        Remove-Item -Path $expectedOdsPath -Force
    }

    & $LibreOfficeExe @arguments
    $exitCode = $LASTEXITCODE

    $deadline = (Get-Date).AddSeconds(15)
    $createdFile = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -Path $expectedOdsPath -PathType Leaf) {
            $createdFile = (Resolve-Path -Path $expectedOdsPath).Path
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $createdFile) {
        throw "LibreOffice conversion failed for '$CsvFilePath' with exit code $exitCode."
    }

    if ((Get-Item -Path $createdFile).Length -le 0) {
        throw "LibreOffice produced an empty ODS file for '$CsvFilePath' with exit code $exitCode."
    }

    return $createdFile
}

function Format-OdsDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OdsFilePath
    )

    $sourcePath = (Resolve-Path -Path $OdsFilePath).Path
    if ([string]::IsNullOrWhiteSpace($env:TEMP) -or -not (Test-Path -Path $env:TEMP -PathType Container)) {
        throw "The TEMP environment variable must point to an existing directory."
    }

    $temporaryFileName = "FormatOds_{0}.ods.tmp" -f [System.Guid]::NewGuid().ToString('N')
    $tempZipPath = Join-Path -Path $env:TEMP -ChildPath $temporaryFileName
    $tempScript = Join-Path -Path $env:TEMP -ChildPath ("FormatOds_{0}.py" -f [System.Guid]::NewGuid().ToString('N'))

    try {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $python) {
            $python = Get-Command py -ErrorAction SilentlyContinue
        }
        if (-not $python) {
            throw "Python is required to patch the generated ODS file."
        }

        $pythonScript = @"
import zipfile
import xml.etree.ElementTree as ET
import shutil
from pathlib import Path

source = Path(r'$sourcePath')
temporary = Path(r'$tempZipPath')

style_ns = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0'
fo_ns = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0'

with zipfile.ZipFile(source, 'r') as zin:
    xml_parts = {
        'content.xml': ET.fromstring(zin.read('content.xml')),
        'styles.xml': ET.fromstring(zin.read('styles.xml')),
    }

for root in xml_parts.values():
    for cell_props in root.iter():
        if cell_props.tag == f'{{{style_ns}}}table-cell-properties':
            cell_props.set(f'{{{fo_ns}}}wrap-option', 'wrap')

    for style in root.iter():
        if style.tag != f'{{{style_ns}}}style':
            continue
        if style.get(f'{{{style_ns}}}family') != 'table-cell':
            continue
        if style.find(f'{{{style_ns}}}table-cell-properties') is None:
            cell_props = ET.SubElement(style, f'{{{style_ns}}}table-cell-properties')
            cell_props.set(f'{{{fo_ns}}}wrap-option', 'wrap')

width_map = {'co1': '9cm', 'co2': '9cm', 'co3': '6cm', 'co4': '18cm'}

for elem in xml_parts['content.xml'].iter():
    if elem.tag != f'{{{style_ns}}}style':
        continue

    style_name = elem.get(f'{{{style_ns}}}name')
    style_family = elem.get(f'{{{style_ns}}}family')
    if style_name not in width_map or style_family != 'table-column':
        continue

    col_props = elem.find(f'{{{style_ns}}}table-column-properties')
    if col_props is None:
        col_props = ET.SubElement(elem, f'{{{style_ns}}}table-column-properties')
    col_props.set(f'{{{style_ns}}}column-width', width_map[style_name])

content_root = xml_parts['content.xml']

serialized_parts = {
    name: ET.tostring(root, encoding='utf-8', xml_declaration=True)
    for name, root in xml_parts.items()
}

with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
    with zipfile.ZipFile(source, 'r') as zin:
        for entry in zin.infolist():
            data = zin.read(entry.filename)
            if entry.filename in serialized_parts:
                data = serialized_parts[entry.filename]
            zout.writestr(entry, data)

if source.exists():
    source.unlink()

if temporary.exists():
    shutil.copy2(temporary, source)
    temporary.unlink()
"@

        $pythonScript | Set-Content -Path $tempScript -Encoding UTF8

        & $python.Source $tempScript
        if ($LASTEXITCODE -ne 0) {
            throw "ODS formatting patch failed for '$OdsFilePath' with exit code $LASTEXITCODE."
        }
    }
    finally {
        if (Test-Path -Path $tempZipPath) {
            Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -Path $tempScript) {
            Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
        }
    }
}

$ErrorActionPreference = 'Stop'

try {
    if (-not [System.IO.Path]::IsPathRooted($CsvInputFolder)) {
        $CsvInputFolder = Join-Path -Path $PSScriptRoot -ChildPath $CsvInputFolder
    }

    if (-not [System.IO.Path]::IsPathRooted($OdsOutputFolder)) {
        $OdsOutputFolder = Join-Path -Path $PSScriptRoot -ChildPath $OdsOutputFolder
    }

    $CsvInputFolder = (Resolve-Path -Path $CsvInputFolder).Path

    if (-not (Test-Path -Path $CsvInputFolder -PathType Container)) {
        throw "CSV input folder not found: $CsvInputFolder"
    }

    if (-not (Test-Path -Path $OdsOutputFolder -PathType Container)) {
        New-Item -Path $OdsOutputFolder -ItemType Directory -Force | Out-Null
    }

    $libreOfficeExe = Get-LibreOfficePath
    if (-not $libreOfficeExe) {
        throw "LibreOffice installation not found. Please install LibreOffice or add it to the default installation paths."
    }

    Write-Host "Detected LibreOffice: $libreOfficeExe"

    $csvFiles = Get-ChildItem -Path $CsvInputFolder -Filter *.csv -File | Sort-Object Name
    if (-not $csvFiles) {
        throw "No CSV files found in folder: $CsvInputFolder"
    }

    foreach ($csvFile in $csvFiles) {
        $timestamp = Get-FileTimestamp -FileName $csvFile.Name
        if (-not $timestamp) {
            Write-Warning "Skipping CSV without a timestamp in the filename: $($csvFile.Name)"
            continue
        }

        Write-Host "Converting: $($csvFile.Name)"
        $generatedFilePath = Invoke-LibreOfficeCsvToOds -LibreOfficeExe $libreOfficeExe -CsvFilePath $csvFile.FullName -OutputFolder $OdsOutputFolder
        $generatedFile = Get-Item -Path $generatedFilePath -ErrorAction Stop

        if (-not $generatedFile) {
            throw "LibreOffice did not create an ODS file for '$($csvFile.Name)'."
        }

        $targetFileName = "04-ODS_Convert_$timestamp.ods"
        $targetFilePath = Join-Path -Path $OdsOutputFolder -ChildPath $targetFileName

        if (Test-Path -Path $targetFilePath -PathType Leaf) {
            Remove-Item -Path $targetFilePath -Force
        }

        if ($generatedFile.FullName -ne $targetFilePath) {
            try {
                Move-Item -Path $generatedFile.FullName -Destination $targetFilePath -Force
            }
            catch {
                Stop-Process -Name soffice* -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Move-Item -Path $generatedFile.FullName -Destination $targetFilePath -Force
            }
        }

        Format-OdsDocument -OdsFilePath $targetFilePath
        Write-Host "Created and formatted ODS: $targetFilePath"

        if ($DeleteCsvAfterConversion) {
            Remove-Item -Path $csvFile.FullName -Force
            Write-Host "Deleted source CSV: $($csvFile.FullName)"
        }
    }
}
catch {
    Write-Error "CSV to ODS conversion failed: $($_.Exception.Message)"
    if ($null -ne $_.Exception) {
        $_.Exception.Data['LoggedByScript'] = $true
    }
    throw
}
