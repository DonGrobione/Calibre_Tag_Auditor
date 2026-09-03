<#
.SYNOPSIS
    Convert CSV files from 03-CSV to ODS files in 04-ODS and apply formatting.

.DESCRIPTION
    Detects the installed LibreOffice installation, converts every CSV file found in 03-CSV to ODS using the pipe delimiter, renames each result to the 04-ODS_Convert_*.ods pattern with the same timestamp as the source CSV, and applies the requested formatting to the generated spreadsheet: automatic line breaks in all cells and the column widths listed below.
    Column A: Title,          width 9 cm
    Column B: Author,         width 6 cm
    Column C: ProposedAction, width 4 cm
    Column D: Tag,            width 4 cm
    Column E: Reason,         width 18 cm

    For rows where ProposedAction = NO_CHANGES, Tag and Reason are null values in the source CSV and remain empty cells in the ODS review sheet.

    Set $DeleteCsvAfterConversion (near the top of the script) to $true to delete each source CSV file after it was successfully converted and formatted as ODS.

.PARAMETER CsvInputFolder
    Folder containing the source CSV files. Defaults to .\03-CSV.

.PARAMETER OdsOutputFolder
    Folder where converted ODS files are written. Defaults to .\04-ODS.

.NOTES
    Version: 1.5
#>

[CmdletBinding()]
param(
    [string]$CsvInputFolder = ".\03-CSV",
    [string]$OdsOutputFolder = ".\04-ODS"
)

# Toggle: delete the source CSV file after it was successfully converted to ODS. Default is $true.
$DeleteCsvAfterConversion = $true

# Import central logging and enable script-scoped output wrappers.
# The wrappers keep terminal behavior but additionally create structured log entries.
$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '$WriteLogModulePath'"
}

Import-Module -Name $WriteLogModulePath -Force

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

# Locate the installed soffice.exe via well-known install paths, falling back to the registry.
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

# Extract the timestamp segment from a source CSV file name so it can be reused for the ODS output.
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

# Run LibreOffice headless to convert one CSV file to ODS and wait until the output file appears.
function Invoke-LibreOfficeCsvToOds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibreOfficeExe,
        [Parameter(Mandatory = $true)]
        [string]$CsvFilePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputFolder
    )

    $temporaryProfile = Join-Path -Path $env:TEMP -ChildPath ("LibreOfficeCsvConversion_{0}" -f [System.Guid]::NewGuid().ToString('N'))
    $profileUri = ([System.Uri]::new($temporaryProfile)).AbsoluteUri
    $arguments = @(
        '--headless',
        '--nologo',
        '--nodefault',
        '--norestore',
        "-env:UserInstallation=$profileUri",
        '--convert-to', 'ods',
        '--infilter=CSV:124,34,76',
        '--outdir', "`"$OutputFolder`"",
        "`"$CsvFilePath`""
    )

    $expectedOdsPath = Join-Path -Path $OutputFolder -ChildPath (([System.IO.Path]::GetFileNameWithoutExtension($CsvFilePath)) + '.ods')
    if (Test-Path -Path $expectedOdsPath -PathType Leaf) {
        Remove-Item -Path $expectedOdsPath -Force
    }

    $libreOfficeProcess = $null
    $exitCode = $null

    try {
        $libreOfficeProcess = Start-Process -FilePath $LibreOfficeExe -ArgumentList $arguments -PassThru
        $libreOfficeProcess.WaitForExit()
        $exitCode = $libreOfficeProcess.ExitCode

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
    finally {
        $processIds = @()

        if ($libreOfficeProcess) {
            $processIds += $libreOfficeProcess.Id

            $processIds += Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -in @('soffice.exe', 'soffice.bin') -and
                    $_.ParentProcessId -eq $libreOfficeProcess.Id
                } |
                Select-Object -ExpandProperty ProcessId
        }

        if ($processIds) {
            $processIds | Sort-Object -Unique | Stop-Process -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -Path $temporaryProfile -PathType Container) {
            Remove-Item -Path $temporaryProfile -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Patch the generated ODS file with PowerShell/.NET only: enable cell wrap and set the requested column widths.
function Format-OdsDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OdsFilePath
    )

    $sourcePath = (Resolve-Path -Path $OdsFilePath).Path

    $styleNs = 'urn:oasis:names:tc:opendocument:xmlns:style:1.0'
    $foNs = 'urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0'
    $widthMap = @{
        co1 = '9cm'
        co2 = '6cm'
        co3 = '4cm'
        co4 = '4cm'
        co5 = '18cm'
    }

    $zipStream = $null
    $zipArchive = $null

    try {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $zipStream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $zipArchive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Update, $false)

        foreach ($entryName in @('content.xml', 'styles.xml')) {
            $entry = $zipArchive.GetEntry($entryName)
            if ($null -eq $entry) {
                throw "Required ODS entry '$entryName' not found in '$OdsFilePath'."
            }

            $xmlText = $null
            $entryReader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
            try {
                $xmlText = $entryReader.ReadToEnd()
            }
            finally {
                $entryReader.Dispose()
            }

            $xmlDoc = New-Object System.Xml.XmlDocument
            $xmlDoc.PreserveWhitespace = $true
            $xmlDoc.LoadXml($xmlText)

            $nsManager = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
            $nsManager.AddNamespace('style', $styleNs)
            $nsManager.AddNamespace('fo', $foNs)

            $cellPropertyNodes = $xmlDoc.SelectNodes('//style:table-cell-properties', $nsManager)
            foreach ($cellProps in $cellPropertyNodes) {
                [void]$cellProps.SetAttribute('wrap-option', $foNs, 'wrap')
            }

            $cellStyleNodes = $xmlDoc.SelectNodes("//style:style[@style:family='table-cell']", $nsManager)
            foreach ($cellStyle in $cellStyleNodes) {
                $cellProps = $cellStyle.SelectSingleNode('style:table-cell-properties', $nsManager)
                if ($null -eq $cellProps) {
                    $cellProps = $xmlDoc.CreateElement('style', 'table-cell-properties', $styleNs)
                    [void]$cellStyle.AppendChild($cellProps)
                }
                [void]$cellProps.SetAttribute('wrap-option', $foNs, 'wrap')
            }

            if ($entryName -eq 'content.xml') {
                foreach ($styleName in $widthMap.Keys) {
                    $columnStyleNodes = $xmlDoc.SelectNodes("//style:style[@style:family='table-column' and @style:name='$styleName']", $nsManager)
                    foreach ($columnStyle in $columnStyleNodes) {
                        $columnProps = $columnStyle.SelectSingleNode('style:table-column-properties', $nsManager)
                        if ($null -eq $columnProps) {
                            $columnProps = $xmlDoc.CreateElement('style', 'table-column-properties', $styleNs)
                            [void]$columnStyle.AppendChild($columnProps)
                        }
                        [void]$columnProps.SetAttribute('column-width', $styleNs, [string]$widthMap[$styleName])
                    }
                }
            }

            $stringBuilder = New-Object System.Text.StringBuilder
            $stringWriter = New-Object System.IO.StringWriter($stringBuilder)
            $xmlWriterSettings = New-Object System.Xml.XmlWriterSettings
            $xmlWriterSettings.OmitXmlDeclaration = $false
            $xmlWriterSettings.Indent = $false
            $xmlWriterSettings.NewLineHandling = [System.Xml.NewLineHandling]::None

            $xmlWriter = [System.Xml.XmlWriter]::Create($stringWriter, $xmlWriterSettings)
            try {
                $xmlDoc.Save($xmlWriter)
            }
            finally {
                $xmlWriter.Dispose()
                $stringWriter.Dispose()
            }

            $updatedXml = $stringBuilder.ToString()

            $entry.Delete()
            $newEntry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryWriter = New-Object System.IO.StreamWriter($newEntry.Open(), (New-Object System.Text.UTF8Encoding($false)))
            try {
                $entryWriter.Write($updatedXml)
            }
            finally {
                $entryWriter.Dispose()
            }
        }
    }
    finally {
        if ($null -ne $zipArchive) {
            $zipArchive.Dispose()
        }
        if ($null -ne $zipStream) {
            $zipStream.Dispose()
        }
    }
}

$ErrorActionPreference = 'Stop'

# Enable strict error handling so problems are reported immediately.
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
