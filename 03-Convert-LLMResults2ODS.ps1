<#
.SYNOPSIS
    Convert LLM JSON result files directly into a formatted ODS review sheet.

.DESCRIPTION
    Reads all JSON files from the input folder, unwraps the JSON result payloads written by the LLM step, repairs mojibake from malformed input text, preserves German umlauts and special characters, and merges the extracted book records.
    The merged records are written to a temporary pipe-delimited UTF-8 CSV file in $env:TEMP, converted to ODS with a headless LibreOffice instance, and then formatted: automatic line breaks in all cells and the column widths listed below.
    Column A: Title,          width 9 cm
    Column B: Author,         width 6 cm
    Column C: ProposedAction, width 4 cm
    Column D: Tag,            width 4 cm
    Column E: Reason,         width 18 cm

    For rows where ProposedAction = NO_CHANGES, Tag and Reason are empty cells in the review sheet.
    The final ODS file is written to the output folder using the naming pattern 03-ODS_Convert_<timestamp>.ods, where <timestamp> is taken from the first input JSON file. All temporary files are created under $env:TEMP and removed after use.
    Script output (info, warnings, and errors) is written both to terminal and to the central log via Modules\Write-Log.psm1. A finally block removes the logging aliases before the script exits so they cannot leak into the calling shell.

.PARAMETER InputFolder
    Folder with JSON files to convert. Defaults to .\02-LLM-Result.

.PARAMETER OdsOutputFolder
    Folder where the converted ODS file is written. Defaults to .\03-ODS.

.NOTES
    Version: 1.2
#>

[CmdletBinding()]
param(
    [string]$InputFolder = ".\02-LLM-Result",
    [string]$OdsOutputFolder = ".\03-ODS"
)

$WriteLogModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Write-Log.psm1"
if (-not (Test-Path -Path $WriteLogModulePath)) {
    throw "Required module not found: '.\\Modules\\Write-Log.psm1'"
}

Import-Module -Name $WriteLogModulePath -Force

Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

#region JSON parsing and record extraction

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

        if ($c -eq '\') {
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

function Get-ParsedJsonObjectFromFile {
    param([string]$FilePath)

    $rawBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) {
        $raw = $raw.Substring(1)
    }

    $jsonText = Get-JsonText -RawText $raw
    if (-not $jsonText) {
        throw "No JSON structure found in file: $(ConvertTo-DisplayPath -Path $FilePath -BasePath $PSScriptRoot)"
    }

    $jsonText = Repair-JsonText -Text $jsonText
    return ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
}

# Read all JSON result files and return the flattened list of book result records.
function Get-BookRecordsFromJsonFiles {
    param([System.IO.FileInfo[]]$Files)

    $allObjects = @()
    foreach ($file in $Files) {
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
            continue
        }

        if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
            foreach ($item in $parsed) { $allObjects += $item }
        } else {
            $allObjects += $parsed
        }
    }

    return $allObjects
}

# Normalize raw JSON objects into the five business columns required by the ODS review sheet.
function ConvertTo-CsvRows {
    param([object[]]$Objects)

    $csvRows = @()
    foreach ($item in $Objects) {
        $cleanItem = Convert-JsonValues -Item $item

        $title = if ($cleanItem.PSObject.Properties.Match('Title')) { $cleanItem.Title } elseif ($cleanItem.PSObject.Properties.Match('Titel')) { $cleanItem.Titel } else { $null }
        $author = if ($cleanItem.PSObject.Properties.Match('Author')) { $cleanItem.Author } elseif ($cleanItem.PSObject.Properties.Match('Autor')) { $cleanItem.Autor } else { $null }
        $proposedAction = if ($cleanItem.PSObject.Properties.Match('ProposedAction')) { $cleanItem.ProposedAction } elseif ($cleanItem.PSObject.Properties.Match('Action')) { $cleanItem.Action } elseif ($cleanItem.PSObject.Properties.Match('Aktion')) { $cleanItem.Aktion } else { $null }
        $tag = if ($cleanItem.PSObject.Properties.Match('Tag')) { $cleanItem.Tag } else { $null }
        $reason = if ($cleanItem.PSObject.Properties.Match('Reason')) { $cleanItem.Reason } elseif ($cleanItem.PSObject.Properties.Match('Begründung')) { $cleanItem.Begründung } else { $null }

        if ([string]::IsNullOrWhiteSpace([string]$title) -and
            [string]::IsNullOrWhiteSpace([string]$author) -and
            [string]::IsNullOrWhiteSpace([string]$proposedAction) -and
            [string]::IsNullOrWhiteSpace([string]$reason)) {
            continue
        }

        $csvRows += [pscustomobject]@{
            Title          = $title
            Author         = $author
            ProposedAction = $proposedAction
            Tag            = $tag
            Reason         = $reason
        }
    }

    return $csvRows
}

#endregion

#region LibreOffice conversion and ODS formatting

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

# Patch the generated ODS file with PowerShell/.NET only: enable cell wrap, set column widths, freeze the header row, and add an AutoFilter.
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
                throw "Required ODS entry '$entryName' not found in '$(ConvertTo-DisplayPath -Path $OdsFilePath -BasePath $PSScriptRoot)'."
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

#endregion

$ErrorActionPreference = 'Stop'

try {
    if (-not [System.IO.Path]::IsPathRooted($InputFolder)) {
        $InputFolder = Join-Path -Path $PSScriptRoot -ChildPath $InputFolder
    }

    if (-not [System.IO.Path]::IsPathRooted($OdsOutputFolder)) {
        $OdsOutputFolder = Join-Path -Path $PSScriptRoot -ChildPath $OdsOutputFolder
    }

    $inputFolderFull = Resolve-Path -Path $InputFolder -ErrorAction Stop

    $files = Get-ChildItem -Path $inputFolderFull -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $files) {
        Write-Error "No JSON files found in folder: $(ConvertTo-DisplayPath -Path $inputFolderFull -BasePath $PSScriptRoot)"
        throw "No JSON input files found."
    }

    $firstFile = $files[0]
    $timestamp = if ($firstFile.Name -match '_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.json$') { $matches[1] } else { $null }
    if (-not $timestamp) {
        throw "Could not determine a timestamp from input file name: $($firstFile.Name)"
    }

    $allObjects = Get-BookRecordsFromJsonFiles -Files $files
    if (-not $allObjects) {
        Write-Error "No valid JSON objects were found."
        throw "No valid JSON objects were found."
    }

    $csvRows = ConvertTo-CsvRows -Objects $allObjects
    if (-not $csvRows) {
        Write-Error "No valid book records with Title/Author/Action/Tag/Reason were found."
        throw "No valid book records were found."
    }

    if (-not (Test-Path -Path $OdsOutputFolder -PathType Container)) {
        New-Item -Path $OdsOutputFolder -ItemType Directory -Force | Out-Null
    }

    $libreOfficeExe = Get-LibreOfficePath
    if (-not $libreOfficeExe) {
        throw "LibreOffice installation not found. Please install LibreOffice or add it to the default installation paths."
    }

    Write-Host "Detected LibreOffice: $(ConvertTo-DisplayPath -Path $libreOfficeExe -BasePath $PSScriptRoot)"

    # Write the merged records as a temporary pipe-delimited UTF-8 CSV under $env:TEMP for LibreOffice to consume.
    $tempCsvPath = Join-Path -Path $env:TEMP -ChildPath ("03-LLM-Result_{0}_{1}.csv" -f $timestamp, [System.Guid]::NewGuid().ToString('N'))
    try {
        $csvContent = $csvRows | ConvertTo-Csv -NoTypeInformation -Delimiter '|'
        $csvContent | Out-File -FilePath $tempCsvPath -Encoding UTF8 -Force

        Write-Host "Converting merged records to ODS..."
        $generatedFilePath = Invoke-LibreOfficeCsvToOds -LibreOfficeExe $libreOfficeExe -CsvFilePath $tempCsvPath -OutputFolder $env:TEMP
        $generatedFile = Get-Item -Path $generatedFilePath -ErrorAction Stop

        $targetFileName = "03-ODS_Convert_$timestamp.ods"
        $targetFilePath = Join-Path -Path $OdsOutputFolder -ChildPath $targetFileName

        if (Test-Path -Path $targetFilePath -PathType Leaf) {
            Remove-Item -Path $targetFilePath -Force
        }

        Move-Item -Path $generatedFile.FullName -Destination $targetFilePath -Force

        Format-OdsDocument -OdsFilePath $targetFilePath
        Write-Host "Created and formatted ODS: $(ConvertTo-DisplayPath -Path $targetFilePath -BasePath $PSScriptRoot)"
    }
    finally {
        if (Test-Path -Path $tempCsvPath -PathType Leaf) {
            Remove-Item -Path $tempCsvPath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-Error "LLM result to ODS conversion failed: $($_.Exception.Message)"
    throw
}
finally {
    # Remove the logging aliases so they cannot leak into the caller's scope.
    Remove-Item -Path Alias:Write-Host, Alias:Write-Warning, Alias:Write-Error -ErrorAction SilentlyContinue
}
