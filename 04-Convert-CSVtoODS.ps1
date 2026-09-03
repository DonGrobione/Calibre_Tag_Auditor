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
#$DeleteCsvAfterConversion = $true
$DeleteCsvAfterConversion = $false

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
    $tableNs = 'urn:oasis:names:tc:opendocument:xmlns:table:1.0'
    $officeNs = 'urn:oasis:names:tc:opendocument:xmlns:office:1.0'
    $configNs = 'urn:oasis:names:tc:opendocument:xmlns:config:1.0'
    $widthMap = @{
        co1 = '9cm'
        co2 = '6cm'
        co3 = '4cm'
        co4 = '4cm'
        co5 = '18cm'
    }
    $sheetNameForFreeze = $null

    if ([string]::IsNullOrWhiteSpace($env:TEMP) -or -not (Test-Path -Path $env:TEMP -PathType Container)) {
        throw "The TEMP environment variable must point to an existing directory."
    }

    $tempZipPath = Join-Path -Path $env:TEMP -ChildPath ("FormatOds_{0}.ods.tmp" -f [System.Guid]::NewGuid().ToString('N'))

    $sourceStream = $null
    $sourceArchive = $null
    $targetStream = $null
    $targetArchive = $null

    $entryDataByName = @{}
    $entryOrder = @()

    try {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $sourceStream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $sourceArchive = New-Object System.IO.Compression.ZipArchive($sourceStream, [System.IO.Compression.ZipArchiveMode]::Read, $false)

        foreach ($entry in $sourceArchive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) {
                continue
            }

            $entryName = $entry.FullName
            $entryOrder += $entryName

            if ($entryName.EndsWith('/')) {
                $entryDataByName[$entryName] = [byte[]]@()
                continue
            }

            $entryStream = $entry.Open()
            try {
                $memoryStream = New-Object System.IO.MemoryStream
                try {
                    $entryStream.CopyTo($memoryStream)
                    $entryDataByName[$entryName] = $memoryStream.ToArray()
                }
                finally {
                    $memoryStream.Dispose()
                }
            }
            finally {
                $entryStream.Dispose()
            }
        }

        foreach ($entryName in @('content.xml', 'styles.xml', 'settings.xml')) {
            $entry = $sourceArchive.GetEntry($entryName)
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
            $nsManager.AddNamespace('table', $tableNs)
            $nsManager.AddNamespace('office', $officeNs)
            $nsManager.AddNamespace('config', $configNs)

            $cellPropertyNodes = $xmlDoc.SelectNodes('//style:table-cell-properties', $nsManager)
            foreach ($cellProps in $cellPropertyNodes) {
                [void]$cellProps.SetAttribute('wrap-option', $foNs, 'wrap')
            }

            $cellStyleNodes = $xmlDoc.SelectNodes("//style:style[@style:family='table-cell']", $nsManager)
            foreach ($cellStyle in $cellStyleNodes) {
                $cellProps = $cellStyle.SelectSingleNode('style:table-cell-properties', $nsManager)
                if ($null -ne $cellProps) {
                    [void]$cellProps.SetAttribute('wrap-option', $foNs, 'wrap')
                }
            }

            if ($entryName -eq 'styles.xml') {
                $defaultCellStyle = $xmlDoc.SelectSingleNode("//style:style[@style:family='table-cell' and @style:name='Default']", $nsManager)
                if ($null -ne $defaultCellStyle) {
                    $defaultCellProps = $defaultCellStyle.SelectSingleNode('style:table-cell-properties', $nsManager)
                    if ($null -eq $defaultCellProps) {
                        $defaultCellProps = $xmlDoc.CreateElement('style', 'table-cell-properties', $styleNs)
                        [void]$defaultCellStyle.AppendChild($defaultCellProps)
                    }
                    [void]$defaultCellProps.SetAttribute('wrap-option', $foNs, 'wrap')
                }
            }

            if ($entryName -eq 'content.xml') {
                # Mark the first row as header row so it stays fixed as a sheet header row.
                $tableNodes = $xmlDoc.SelectNodes('//table:table', $nsManager)
                foreach ($tableNode in $tableNodes) {
                    if ([string]::IsNullOrWhiteSpace($sheetNameForFreeze)) {
                        $detectedSheetName = $tableNode.GetAttribute('name', $tableNs)
                        if (-not [string]::IsNullOrWhiteSpace($detectedSheetName)) {
                            $sheetNameForFreeze = $detectedSheetName
                        }
                    }

                    $existingHeaderRows = $tableNode.SelectSingleNode('table:table-header-rows', $nsManager)
                    if ($null -ne $existingHeaderRows) {
                        continue
                    }

                    $firstRowNode = $tableNode.SelectSingleNode('table:table-row', $nsManager)
                    if ($null -eq $firstRowNode) {
                        continue
                    }

                    $headerRowsNode = $xmlDoc.CreateElement('table', 'table-header-rows', $tableNs)
                    [void]$tableNode.InsertBefore($headerRowsNode, $firstRowNode)
                    [void]$headerRowsNode.AppendChild($firstRowNode)
                }

                # Ensure AutoFilter is enabled for row 1 (header) across columns A-E.
                $spreadsheetNode = $xmlDoc.SelectSingleNode('//office:body/office:spreadsheet', $nsManager)
                if ($null -ne $spreadsheetNode) {
                    $existingDatabaseRanges = $spreadsheetNode.SelectSingleNode('table:database-ranges', $nsManager)
                    if ($null -ne $existingDatabaseRanges) {
                        [void]$spreadsheetNode.RemoveChild($existingDatabaseRanges)
                    }

                    $databaseRangesNode = $xmlDoc.CreateElement('table', 'database-ranges', $tableNs)
                    [void]$spreadsheetNode.AppendChild($databaseRangesNode)

                    $databaseRangeIndex = 0
                    foreach ($tableNode in $tableNodes) {
                        $sheetName = $tableNode.GetAttribute('name', $tableNs)
                        if ([string]::IsNullOrWhiteSpace($sheetName)) {
                            continue
                        }

                        $rowCount = 0
                        $rowNodes = $tableNode.SelectNodes('.//table:table-row', $nsManager)
                        foreach ($rowNode in $rowNodes) {
                            $repeatCount = 1
                            $repeatValue = $rowNode.GetAttribute('number-rows-repeated', $tableNs)
                            if (-not [string]::IsNullOrWhiteSpace($repeatValue)) {
                                [int]$parsedRepeatCount = 0
                                if ([int]::TryParse($repeatValue, [ref]$parsedRepeatCount) -and $parsedRepeatCount -gt 0) {
                                    $repeatCount = $parsedRepeatCount
                                }
                            }

                            $rowCount += $repeatCount
                        }

                        if ($rowCount -lt 1) {
                            continue
                        }

                        $escapedSheetName = $sheetName.Replace("'", "''")
                        $targetRangeAddress = "'$escapedSheetName'.A1:'$escapedSheetName'.E$rowCount"

                        $databaseRangeNode = $xmlDoc.CreateElement('table', 'database-range', $tableNs)
                        [void]$databaseRangeNode.SetAttribute('name', $tableNs, "__Anonymous_Sheet_DB__$databaseRangeIndex")
                        [void]$databaseRangeNode.SetAttribute('target-range-address', $tableNs, $targetRangeAddress)
                        [void]$databaseRangeNode.SetAttribute('display-filter-buttons', $tableNs, 'true')

                        [void]$databaseRangesNode.AppendChild($databaseRangeNode)
                        $databaseRangeIndex++
                    }
                }

                foreach ($styleName in $widthMap.Keys) {
                    $columnStyleNodes = $xmlDoc.SelectNodes("//style:style[@style:family='table-column' and @style:name='$styleName']", $nsManager)
                    foreach ($columnStyle in $columnStyleNodes) {
                        $columnProps = $columnStyle.SelectSingleNode('style:table-column-properties', $nsManager)
                        if ($null -ne $columnProps) {
                            [void]$columnProps.SetAttribute('column-width', $styleNs, [string]$widthMap[$styleName])
                        }
                    }
                }
            }

            if ($entryName -eq 'settings.xml') {
                if ([string]::IsNullOrWhiteSpace($sheetNameForFreeze)) {
                    $sheetNameForFreeze = 'Sheet1'
                }

                function Set-ConfigItemValue {
                    param(
                        [Parameter(Mandatory = $true)]
                        [System.Xml.XmlElement]$Parent,
                        [Parameter(Mandatory = $true)]
                        [System.Xml.XmlDocument]$Document,
                        [Parameter(Mandatory = $true)]
                        [System.Xml.XmlNamespaceManager]$NamespaceManager,
                        [Parameter(Mandatory = $true)]
                        [string]$ConfigNamespace,
                        [Parameter(Mandatory = $true)]
                        [string]$Name,
                        [Parameter(Mandatory = $true)]
                        [string]$Type,
                        [Parameter(Mandatory = $true)]
                        [string]$Value
                    )

                    $node = $Parent.SelectSingleNode("config:config-item[@config:name='$Name']", $NamespaceManager)
                    if ($null -eq $node) {
                        $node = $Document.CreateElement('config', 'config-item', $ConfigNamespace)
                        [void]$node.SetAttribute('name', $ConfigNamespace, $Name)
                        [void]$node.SetAttribute('type', $ConfigNamespace, $Type)
                        [void]$Parent.AppendChild($node)
                    }
                    else {
                        [void]$node.SetAttribute('type', $ConfigNamespace, $Type)
                    }

                    $node.InnerText = $Value
                }

                $viewSettingsSet = $xmlDoc.SelectSingleNode("//office:settings/config:config-item-set[@config:name='ooo:view-settings']", $nsManager)
                if ($null -ne $viewSettingsSet) {
                    $viewsNode = $viewSettingsSet.SelectSingleNode("config:config-item-map-indexed[@config:name='Views']", $nsManager)
                    if ($null -eq $viewsNode) {
                        $viewsNode = $xmlDoc.CreateElement('config', 'config-item-map-indexed', $configNs)
                        [void]$viewsNode.SetAttribute('name', $configNs, 'Views')
                        [void]$viewSettingsSet.AppendChild($viewsNode)
                    }

                    $viewEntry = $viewsNode.SelectSingleNode('config:config-item-map-entry', $nsManager)
                    if ($null -eq $viewEntry) {
                        $viewEntry = $xmlDoc.CreateElement('config', 'config-item-map-entry', $configNs)
                        [void]$viewsNode.AppendChild($viewEntry)
                    }

                    Set-ConfigItemValue -Parent $viewEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ViewId' -Type 'string' -Value 'view1'
                    Set-ConfigItemValue -Parent $viewEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ActiveTable' -Type 'string' -Value $sheetNameForFreeze

                    $tablesNode = $viewEntry.SelectSingleNode("config:config-item-map-named[@config:name='Tables']", $nsManager)
                    if ($null -eq $tablesNode) {
                        $tablesNode = $xmlDoc.CreateElement('config', 'config-item-map-named', $configNs)
                        [void]$tablesNode.SetAttribute('name', $configNs, 'Tables')
                        [void]$viewEntry.AppendChild($tablesNode)
                    }

                    $tableEntry = $tablesNode.SelectSingleNode("config:config-item-map-entry[@config:name='$sheetNameForFreeze']", $nsManager)
                    if ($null -eq $tableEntry) {
                        $tableEntry = $xmlDoc.CreateElement('config', 'config-item-map-entry', $configNs)
                        [void]$tableEntry.SetAttribute('name', $configNs, $sheetNameForFreeze)
                        [void]$tablesNode.AppendChild($tableEntry)
                    }

                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'CursorPositionX' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'CursorPositionY' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'HorizontalSplitMode' -Type 'short' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'VerticalSplitMode' -Type 'short' -Value '2'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'HorizontalSplitPosition' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'VerticalSplitPosition' -Type 'int' -Value '1'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ActiveSplitRange' -Type 'short' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'PositionLeft' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'PositionRight' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'PositionTop' -Type 'int' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'PositionBottom' -Type 'int' -Value '1'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ZoomType' -Type 'short' -Value '0'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ZoomValue' -Type 'int' -Value '100'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'PageViewZoomValue' -Type 'int' -Value '60'
                    Set-ConfigItemValue -Parent $tableEntry -Document $xmlDoc -NamespaceManager $nsManager -ConfigNamespace $configNs -Name 'ShowGrid' -Type 'boolean' -Value 'true'
                }
            }

            $xmlMemoryStream = New-Object System.IO.MemoryStream
            try {
                $xmlWriterSettings = New-Object System.Xml.XmlWriterSettings
                $xmlWriterSettings.OmitXmlDeclaration = $false
                $xmlWriterSettings.Indent = $false
                $xmlWriterSettings.NewLineHandling = [System.Xml.NewLineHandling]::None
                $xmlWriterSettings.Encoding = New-Object System.Text.UTF8Encoding($false)

                $xmlWriter = [System.Xml.XmlWriter]::Create($xmlMemoryStream, $xmlWriterSettings)
                try {
                    $xmlDoc.Save($xmlWriter)
                }
                finally {
                    $xmlWriter.Dispose()
                }

                $entryDataByName[$entryName] = $xmlMemoryStream.ToArray()
            }
            finally {
                $xmlMemoryStream.Dispose()
            }
        }

        $targetStream = [System.IO.File]::Open($tempZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $targetArchive = New-Object System.IO.Compression.ZipArchive($targetStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)

        if ($entryDataByName.ContainsKey('mimetype')) {
            $mimeEntry = $targetArchive.CreateEntry('mimetype', [System.IO.Compression.CompressionLevel]::NoCompression)
            $mimeStream = $mimeEntry.Open()
            try {
                $mimeBytes = [byte[]]$entryDataByName['mimetype']
                $mimeStream.Write($mimeBytes, 0, $mimeBytes.Length)
            }
            finally {
                $mimeStream.Dispose()
            }
        }

        foreach ($entryName in $entryOrder) {
            if ($entryName -eq 'mimetype') {
                continue
            }

            if (-not $entryDataByName.ContainsKey($entryName)) {
                continue
            }

            $bytes = [byte[]]$entryDataByName[$entryName]
            $compressionLevel = if ($entryName.EndsWith('/')) { [System.IO.Compression.CompressionLevel]::NoCompression } else { [System.IO.Compression.CompressionLevel]::Optimal }
            $targetEntry = $targetArchive.CreateEntry($entryName, $compressionLevel)

            if ($entryName.EndsWith('/')) {
                continue
            }

            $targetEntryStream = $targetEntry.Open()
            try {
                $targetEntryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $targetEntryStream.Dispose()
            }
        }

        $targetArchive.Dispose()
        $targetArchive = $null
        $targetStream.Dispose()
        $targetStream = $null
        $sourceArchive.Dispose()
        $sourceArchive = $null
        $sourceStream.Dispose()
        $sourceStream = $null

        [System.IO.File]::Copy($tempZipPath, $sourcePath, $true)
    }
    finally {
        if ($null -ne $targetArchive) {
            $targetArchive.Dispose()
        }
        if ($null -ne $targetStream) {
            $targetStream.Dispose()
        }
        if ($null -ne $sourceArchive) {
            $sourceArchive.Dispose()
        }
        if ($null -ne $sourceStream) {
            $sourceStream.Dispose()
        }
        if (Test-Path -Path $tempZipPath -PathType Leaf) {
            Remove-Item -Path $tempZipPath -Force -ErrorAction SilentlyContinue
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
