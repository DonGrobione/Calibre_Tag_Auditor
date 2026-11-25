<#
.SYNOPSIS
    Convert LLM JSON result files directly into a formatted ODS review sheet.

.DESCRIPTION
    Reads all LLM result files (LLM-Result_*.json) from the input folder, unwraps the JSON result objects written by the LLM step (the book records in their records property, with the English field names Title, Author, ProposedAction, Tag, and Reason), repairs mojibake from malformed input text, preserves German umlauts and special characters, and merges the extracted book records.
    The merged records are written to a temporary pipe-delimited UTF-8 CSV file in $env:TEMP, converted to ODS with a headless LibreOffice instance, and then formatted: automatic line breaks in all cells and the column widths listed below.
    Column A: Title,          width 9 cm
    Column B: Author,         width 6 cm
    Column C: ProposedAction, width 4 cm
    Column D: Tag,            width 4 cm
    Column E: Reason,         width 18 cm

    For rows where ProposedAction = NO_CHANGES, Tag and Reason are empty cells in the review sheet.
    Books that the LLM step could not audit (listed in missing_books of a result file, e.g. blocked by Gemini for prohibited content) get one row with ProposedAction = NOT_AUDITED, an empty Tag, and the reason in the Reason column, so their tags can be checked manually. The number of these rows is logged.
    The final ODS file is written to the output folder using the naming pattern 03-ODS_Convert_<timestamp>.ods, where <timestamp> is taken from the first input JSON file. All temporary files are created under $env:TEMP and removed after use.
    Script output (info, warnings, and errors) is written both to terminal and to the log file of DonGrobione.Logging (>= 2.2.0) via Write-ScriptLog from Modules\Calibre.Console.psm1. When no log session is running, the script starts its own session and stops it again in a finally block; when called by Invoke-CalibreToolsPipeline.ps1 it uses the pipeline's session.

.PARAMETER InputFolder
    Folder with the LLM result files (LLM-Result_*.json) to convert; other files in it are ignored. Defaults to .\02-LLM-Result.

.PARAMETER OdsOutputFolder
    Folder where the converted ODS file is written. Defaults to .\03-ODS.

.NOTES
    Version: 1.9
#>

[CmdletBinding()]
param(
    [string]$InputFolder = ".\02-LLM-Result",
    [string]$OdsOutputFolder = ".\03-ODS"
)

# Import the central logging module and the console/log output helpers.
Import-Module DonGrobione.Logging -MinimumVersion 2.2.0 -ErrorAction Stop
$CalibreConsoleModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Console.psd1"
if (-not (Test-Path -LiteralPath $CalibreConsoleModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Console.psd1'"
}

Import-Module -Name $CalibreConsoleModulePath -Force

# Repair-MojibakeText replaces only garbled UTF-8 sequences and keeps all other characters, also those outside ISO-8859-1.
$CalibreTextModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Text.psd1"
if (-not (Test-Path -LiteralPath $CalibreTextModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Text.psd1'"
}

Import-Module -Name $CalibreTextModulePath -Force

# Get-ExportTimestamp reads the run timestamp from the result file name.
$CalibreStorageModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Calibre.Storage.psd1"
if (-not (Test-Path -LiteralPath $CalibreStorageModulePath -PathType Leaf)) {
    throw "Required module not found: '.\Modules\Calibre.Storage.psd1'"
}

Import-Module -Name $CalibreStorageModulePath -Force

#region JSON parsing and record extraction

# Returns $true when the text parses as JSON and $false otherwise.
function Test-JsonText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Text)

    try {
        ConvertFrom-Json -InputObject $Text -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# Returns JSON text unchanged when it parses; otherwise repairs mojibake sequences and returns the repaired text when it parses, or the original text.
function Repair-JsonText {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    if (Test-JsonText -Text $Text) {
        return $Text
    }

    $decoded = Repair-MojibakeText -Text $Text
    if ($decoded -ceq $Text) {
        return $Text
    }

    if (Test-JsonText -Text $decoded) {
        return $decoded
    }

    return $Text
}

# Recursively process JSON values so strings are cleaned and nested structures are preserved.
function Convert-JsonValue {
    [CmdletBinding()]
    [OutputType([hashtable], [object[]])]
    param([object]$Item)
    if ($null -eq $Item) { return $null }

    if ($Item -is [string]) {
        return Repair-MojibakeText -Text $Item
    }

    if ($Item -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Item.Keys) {
            $fixedKey = Repair-MojibakeText -Text $key
            $result[$fixedKey] = Convert-JsonValue -Item $Item[$key]
        }
        return $result
    }

    if ($Item -is [System.Collections.IEnumerable] -and -not ($Item -is [string])) {
        $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($element in $Item) {
            $list.Add((Convert-JsonValue -Item $element))
        }
        return ,$list.ToArray()
    }

    return $Item
}

# Reads a file as UTF-8 text and parses its extracted JSON structure into an object.
function Get-ParsedJsonObjectFromFile {
    [CmdletBinding()]
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

# Converts the missing_books entries of an LLM result file into review rows with ProposedAction NOT_AUDITED and the reason why the book has no audit result; returns nothing for files without missing_books.
function ConvertTo-NotAuditedRecord {
    [CmdletBinding()]
    param([object]$ParsedResult)

    if ($null -eq $ParsedResult -or $null -eq $ParsedResult.PSObject.Properties['missing_books']) {
        return
    }

    foreach ($missingBook in @($ParsedResult.missing_books | Where-Object { $null -ne $_ })) {
        [pscustomobject][ordered]@{
            Title          = $missingBook.Title
            Author         = $missingBook.Author
            ProposedAction = 'NOT_AUDITED'
            Tag            = $null
            Reason         = "No audit result: $($missingBook.Reason). Check the tags manually."
        }
    }
}

# Read all JSON result files and return the flattened list of book result records (the records property of each result object), plus a NOT_AUDITED record for every book listed in missing_books.
function Get-BookRecordFromJsonFile {
    [CmdletBinding()]
    param([System.IO.FileInfo[]]$Files)

    $allObjects = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($file in $Files) {
        Write-ScriptLog "Processing: $($file.Name)"

        try {
            $parsed = Get-ParsedJsonObjectFromFile -FilePath $file.FullName
        }
        catch {
            Write-ScriptLog -Level WARN -Message "Failed to process $($file.Name): $($_.Exception.Message)"
            continue
        }

        foreach ($notAuditedRecord in @(ConvertTo-NotAuditedRecord -ParsedResult $parsed)) {
            $allObjects.Add($notAuditedRecord)
        }

        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['records']) {
            Write-ScriptLog -Level WARN -Message "$($file.Name) is no LLM result object (no records property) and was skipped."
            continue
        }

        foreach ($record in @($parsed.records | Where-Object { $null -ne $_ })) {
            $allObjects.Add($record)
        }
    }

    return $allObjects.ToArray()
}

# Normalize raw JSON objects into the five business columns required by the ODS review sheet.
function ConvertTo-CsvRow {
    [CmdletBinding()]
    param([object[]]$Objects)

    $csvRows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in $Objects) {
        $cleanItem = Convert-JsonValue -Item $item

        # The property indexer returns $null for a missing property; Properties.Match() returns an empty collection that still counts as $true.
        $values = @{}
        foreach ($columnName in @('Title', 'Author', 'ProposedAction', 'Tag', 'Reason')) {
            $values[$columnName] = if ($null -ne $cleanItem.PSObject.Properties[$columnName]) { $cleanItem.$columnName } else { $null }
        }

        if ([string]::IsNullOrWhiteSpace([string]$values.Title) -and
            [string]::IsNullOrWhiteSpace([string]$values.Author) -and
            [string]::IsNullOrWhiteSpace([string]$values.ProposedAction) -and
            [string]::IsNullOrWhiteSpace([string]$values.Reason)) {
            continue
        }

        $csvRows.Add([pscustomobject][ordered]@{
                Title          = $values.Title
                Author         = $values.Author
                ProposedAction = $values.ProposedAction
                Tag            = $values.Tag
                Reason         = $values.Reason
            })
    }

    return $csvRows.ToArray()
}

#endregion

#region LibreOffice conversion and ODS formatting

# Locate the installed soffice.exe via well-known install paths, falling back to the registry.
function Get-LibreOfficePath {
    [CmdletBinding()]
    param()

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
function Invoke-LibreOfficeConversion {
    [CmdletBinding()]
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

# Sets or updates the named config:config-item children of an ODS settings.xml element; Item maps each item name to its type and value (e.g. ZoomValue = @('int', '100')). Missing items are created with their type, existing items get the new type and value. Document and namespace come from the parent element.
function Set-OdsConfigItem {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Parent,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Item
    )

    $document = $Parent.OwnerDocument
    $configNamespace = 'urn:oasis:names:tc:opendocument:xmlns:config:1.0'
    $namespaceManager = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $document.NameTable
    $namespaceManager.AddNamespace('config', $configNamespace)

    foreach ($name in $Item.Keys) {
        $type = [string]$Item[$name][0]
        $value = [string]$Item[$name][1]
        if (-not $PSCmdlet.ShouldProcess("settings.xml config item '$name'", "Set value '$value'")) {
            continue
        }

        $node = $Parent.SelectSingleNode("config:config-item[@config:name='$name']", $namespaceManager)
        if ($null -eq $node) {
            $node = $document.CreateElement('config', 'config-item', $configNamespace)
            [void]$node.SetAttribute('name', $configNamespace, [string]$name)
            [void]$Parent.AppendChild($node)
        }

        [void]$node.SetAttribute('type', $configNamespace, $type)
        $node.InnerText = $value
    }
}

# Patch the generated ODS file with PowerShell/.NET only: enable cell wrap, set column widths, freeze the header row, and add an AutoFilter.
function Format-OdsDocument {
    [CmdletBinding()]
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

                    Set-OdsConfigItem -Parent $viewEntry -Item ([ordered]@{
                            ViewId      = @('string', 'view1')
                            ActiveTable = @('string', $sheetNameForFreeze)
                        })

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

                    # Freeze the header row (vertical split after row 1) and reset cursor, scroll position, and zoom.
                    Set-OdsConfigItem -Parent $tableEntry -Item ([ordered]@{
                            CursorPositionX         = @('int', '0')
                            CursorPositionY         = @('int', '0')
                            HorizontalSplitMode     = @('short', '0')
                            VerticalSplitMode       = @('short', '2')
                            HorizontalSplitPosition = @('int', '0')
                            VerticalSplitPosition   = @('int', '1')
                            ActiveSplitRange        = @('short', '0')
                            PositionLeft            = @('int', '0')
                            PositionRight           = @('int', '0')
                            PositionTop             = @('int', '0')
                            PositionBottom          = @('int', '1')
                            ZoomType                = @('short', '0')
                            ZoomValue               = @('int', '100')
                            PageViewZoomValue       = @('int', '60')
                            ShowGrid                = @('boolean', 'true')
                        })
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

# Start an own log session only when the script is not running inside the pipeline's session. -MaxFileSizeMB 0 turns off size-based rotation, so each run stays in one log file.
$ownsLogSession = -not (Test-LogSession)
if ($ownsLogSession) {
    Start-Log -LogDirectory 'Calibre_Tag_Auditor' -MaxFileSizeMB 0
}

try {
    if (-not [System.IO.Path]::IsPathRooted($InputFolder)) {
        $InputFolder = Join-Path -Path $PSScriptRoot -ChildPath $InputFolder
    }

    if (-not [System.IO.Path]::IsPathRooted($OdsOutputFolder)) {
        $OdsOutputFolder = Join-Path -Path $PSScriptRoot -ChildPath $OdsOutputFolder
    }

    $inputFolderFull = Resolve-Path -Path $InputFolder -ErrorAction Stop

    # Only the LLM result files are read; other files in the folder, such as the pipeline's run state file Pipeline-RunState.json, are not results.
    $files = Get-ChildItem -Path $inputFolderFull -Filter 'LLM-Result_*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $files) {
        Write-ScriptLog -Level ERROR -Message "No LLM result files (LLM-Result_*.json) found in folder: $(ConvertTo-DisplayPath -Path $inputFolderFull -BasePath $PSScriptRoot)"
        throw "No JSON input files found."
    }

    $firstFile = $files[0]
    $timestamp = Get-ExportTimestamp -FileName $firstFile.Name
    if (-not $timestamp) {
        throw "Could not determine a timestamp from input file name: $($firstFile.Name)"
    }

    $allObjects = Get-BookRecordFromJsonFile -Files $files
    if (-not $allObjects) {
        Write-ScriptLog -Level ERROR -Message "No valid JSON objects were found."
        throw "No valid JSON objects were found."
    }

    $csvRows = ConvertTo-CsvRow -Objects $allObjects
    if (-not $csvRows) {
        Write-ScriptLog -Level ERROR -Message "No valid book records with Title/Author/Action/Tag/Reason were found."
        throw "No valid book records were found."
    }

    $notAuditedRowCount = @($csvRows | Where-Object { $_.ProposedAction -eq 'NOT_AUDITED' }).Count
    if ($notAuditedRowCount -gt 0) {
        Write-ScriptLog -Level WARN -Message "Books without audit result: $notAuditedRowCount (rows with ProposedAction NOT_AUDITED)"
    }

    if (-not (Test-Path -Path $OdsOutputFolder -PathType Container)) {
        New-Item -Path $OdsOutputFolder -ItemType Directory -Force | Out-Null
    }

    $libreOfficeExe = Get-LibreOfficePath
    if (-not $libreOfficeExe) {
        throw "LibreOffice installation not found. Please install LibreOffice or add it to the default installation paths."
    }

    Write-ScriptLog "Detected LibreOffice: $(ConvertTo-DisplayPath -Path $libreOfficeExe -BasePath $PSScriptRoot)"

    # Write the merged records as a temporary pipe-delimited UTF-8 CSV under $env:TEMP for LibreOffice to consume.
    $tempCsvPath = Join-Path -Path $env:TEMP -ChildPath ("03-LLM-Result_{0}_{1}.csv" -f $timestamp, [System.Guid]::NewGuid().ToString('N'))
    try {
        $csvContent = @($csvRows | ConvertTo-Csv -NoTypeInformation -Delimiter '|')
        # UTF-8 without BOM: the LibreOffice import filter sets the character set explicitly (76 = UTF-8), and a BOM could end up in the first header cell.
        [System.IO.File]::WriteAllLines($tempCsvPath, [string[]]$csvContent, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))

        Write-ScriptLog "Converting merged records to ODS..."
        $generatedFilePath = Invoke-LibreOfficeConversion -LibreOfficeExe $libreOfficeExe -CsvFilePath $tempCsvPath -OutputFolder $env:TEMP
        $generatedFile = Get-Item -Path $generatedFilePath -ErrorAction Stop

        $targetFileName = "03-ODS_Convert_$timestamp.ods"
        $targetFilePath = Join-Path -Path $OdsOutputFolder -ChildPath $targetFileName

        if (Test-Path -Path $targetFilePath -PathType Leaf) {
            Remove-Item -Path $targetFilePath -Force
        }

        Move-Item -Path $generatedFile.FullName -Destination $targetFilePath -Force

        Format-OdsDocument -OdsFilePath $targetFilePath
        Write-ScriptLog "Created and formatted ODS: $(ConvertTo-DisplayPath -Path $targetFilePath -BasePath $PSScriptRoot)"
    }
    finally {
        if (Test-Path -Path $tempCsvPath -PathType Leaf) {
            Remove-Item -Path $tempCsvPath -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    Write-ScriptLog -Level ERROR -Message "LLM result to ODS conversion failed: $($_.Exception.Message)" -ErrorRecord $_
    throw
}
finally {
    if ($ownsLogSession) {
        Stop-Log
    }
}
