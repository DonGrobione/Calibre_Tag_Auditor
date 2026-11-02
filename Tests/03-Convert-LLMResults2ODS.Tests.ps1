<#
.SYNOPSIS
    Pester tests for the JSON, CSV, and LibreOffice functions in 03-Convert-LLMResults2ODS.ps1.

.DESCRIPTION
    Covers Test-JsonText, Repair-JsonText, Convert-JsonValue (with the strict mojibake repair of the Calibre.Text module, which keeps characters outside ISO-8859-1), Get-BookRecordFromJsonFile (with NOT_AUDITED records from missing_books via ConvertTo-NotAuditedRecord), ConvertTo-CsvRow, Invoke-LibreOfficeConversion, and Set-ConfigItemValue. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. Start-Process is mocked; LibreOffice is not started.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\03-Convert-LLMResults2ODS.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '03-Convert-LLMResults2ODS.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @('Test-JsonText', 'Repair-JsonText', 'Convert-JsonValue', 'Get-JsonText', 'Get-ParsedJsonObjectFromFile', 'ConvertTo-NotAuditedRecord', 'Get-BookRecordFromJsonFile', 'ConvertTo-CsvRow', 'Invoke-LibreOfficeConversion', 'Set-ConfigItemValue')
foreach ($functionName in $functionNames) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Repair-MojibakeText comes from the Calibre.Text module, as in the script.
Import-Module -Name (Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Text.psd1') -Force

# Stands in for the Calibre.Console logging helper so the tests write no log file.
function Write-ScriptLog {
    param($Message, $Level, $ErrorRecord)
    $null = $Message, $Level, $ErrorRecord
}

# Stands in for the Calibre.Console display path helper and returns the path unchanged.
function ConvertTo-DisplayPath {
    param($Path, $BasePath)
    $null = $BasePath
    $Path
}

# UTF-8 text "Müller" decoded as Latin-1, as produced by a wrong decoding step.
$mojibakeText = 'M' + [char]0x00C3 + [char]0x00BC + 'ller'
$umlautText = 'M' + [char]0x00FC + 'ller'

Describe '03-Convert-LLMResults2ODS.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }
}

Describe 'Test-JsonText' {
    It 'returns $true for valid JSON' {
        Test-JsonText -Text '{ "a": 1 }' | Should Be $true
    }

    It 'returns $false for invalid JSON' {
        Test-JsonText -Text '{ a: ' | Should Be $false
    }
}

Describe 'Repair-JsonText' {
    It 'returns valid JSON unchanged' {
        Repair-JsonText -Text '{ "Title": "A" }' | Should Be '{ "Title": "A" }'
    }

    It 'returns invalid JSON without mojibake unchanged' {
        Repair-JsonText -Text '{ broken' | Should Be '{ broken'
    }

    It 'returns an empty string unchanged' {
        Repair-JsonText -Text '' | Should Be ''
    }

    It 'returns valid JSON with mojibake unchanged, because Convert-JsonValue repairs the values later' {
        $validJson = '{ "Author": "' + $mojibakeText + '" }'
        Repair-JsonText -Text $validJson | Should Be $validJson
    }

    It 'returns the original text when the decoded text is still invalid JSON' {
        $invalidJson = '{ "Author": ' + $mojibakeText
        Repair-JsonText -Text $invalidJson | Should Be $invalidJson
    }
}

Describe 'Convert-JsonValue' {
    It 'repairs mojibake in strings' {
        Convert-JsonValue -Item $mojibakeText | Should Be $umlautText
    }

    It 'repairs keys and values of dictionaries' {
        $result = Convert-JsonValue -Item @{ $mojibakeText = $mojibakeText }
        $result[$umlautText] | Should Be $umlautText
    }

    It 'repairs every element of a list and keeps it a list' {
        $result = Convert-JsonValue -Item @($mojibakeText, 'Plain')
        $result.Count | Should Be 2
        $result[0] | Should Be $umlautText
        $result[1] | Should Be 'Plain'
    }

    It 'keeps correct a-tilde, a-circumflex, typographic, and Japanese characters unchanged' {
        # Before version 1.6, a correct a-tilde started a whole-text ISO-8859-1 round trip that destroyed these characters.
        $text = "S$([char]0xE3)o Paulo, p$([char]0xE2)t$([char]0xE9) $([char]0x2013) it$([char]0x2019)s $([char]0x3088)$([char]0x3046) M$([char]0xFC)ller"
        Convert-JsonValue -Item $text | Should BeExactly $text
    }

    It 'repairs a garbled umlaut next to characters outside ISO-8859-1' {
        Convert-JsonValue -Item "$mojibakeText $([char]0x2013) $([char]0x3088)" | Should BeExactly "$umlautText $([char]0x2013) $([char]0x3088)"
    }

    It 'returns $null for $null' {
        Convert-JsonValue -Item $null | Should Be $null
    }

    It 'returns numbers unchanged' {
        Convert-JsonValue -Item 42 | Should Be 42
    }
}

Describe 'Get-BookRecordFromJsonFile' {
    $wrappedFile = Join-Path -Path $TestDrive -ChildPath 'wrapped.json'
    $arrayFile = Join-Path -Path $TestDrive -ChildPath 'array.json'
    $brokenFile = Join-Path -Path $TestDrive -ChildPath 'broken.json'
    Set-Content -LiteralPath $wrappedFile -Encoding UTF8 -Value '{ "metadata": {}, "records": [ { "Title": "A" }, { "Title": "B" } ] }'
    Set-Content -LiteralPath $arrayFile -Encoding UTF8 -Value 'Response: [ { "Title": "C" } ] trailing text'
    Set-Content -LiteralPath $brokenFile -Encoding UTF8 -Value 'no json here'

    It 'returns the records of wrapped results and bare arrays' {
        $records = Get-BookRecordFromJsonFile -Files @((Get-Item -LiteralPath $wrappedFile), (Get-Item -LiteralPath $arrayFile))
        (@($records) | ForEach-Object { $_.Title }) -join ',' | Should Be 'A,B,C'
    }

    It 'skips unreadable files with a warning' {
        Mock Write-ScriptLog { }
        $records = Get-BookRecordFromJsonFile -Files @((Get-Item -LiteralPath $brokenFile), (Get-Item -LiteralPath $arrayFile))
        @($records).Count | Should Be 1
        Assert-MockCalled Write-ScriptLog -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'adds a NOT_AUDITED record for every book in missing_books' {
        $missingFile = Join-Path -Path $TestDrive -ChildPath 'missing.json'
        Set-Content -LiteralPath $missingFile -Encoding UTF8 -Value '{ "status": "warning", "records": [ { "Title": "A", "Author": "X", "ProposedAction": "NO_CHANGES" } ], "missing_books": [ { "Title": "Blocked", "Author": "Y", "Reason": "blocked for prohibited content" } ] }'
        $records = @(Get-BookRecordFromJsonFile -Files @(Get-Item -LiteralPath $missingFile))
        $records.Count | Should Be 2
        $notAudited = @($records | Where-Object { $_.ProposedAction -eq 'NOT_AUDITED' })
        $notAudited.Count | Should Be 1
        $notAudited[0].Title | Should Be 'Blocked'
        $notAudited[0].Author | Should Be 'Y'
        $notAudited[0].Tag | Should Be $null
        $notAudited[0].Reason | Should Be 'No audit result: blocked for prohibited content. Check the tags manually.'
    }

    It 'adds NOT_AUDITED records for an error result without records' {
        $errorFile = Join-Path -Path $TestDrive -ChildPath 'error.json'
        Set-Content -LiteralPath $errorFile -Encoding UTF8 -Value '{ "status": "error", "records": [], "missing_books": [ { "Title": "Only", "Author": "Z", "Reason": "API request failed" } ] }'
        $records = @(Get-BookRecordFromJsonFile -Files @(Get-Item -LiteralPath $errorFile))
        $records.Count | Should Be 1
        $records[0].ProposedAction | Should Be 'NOT_AUDITED'
    }

    It 'adds no NOT_AUDITED record for files without missing_books' {
        $records = @(Get-BookRecordFromJsonFile -Files @(Get-Item -LiteralPath $wrappedFile))
        @($records | Where-Object { $_.ProposedAction -eq 'NOT_AUDITED' }).Count | Should Be 0
    }

    It 'keeps the NOT_AUDITED row with its reason in the CSV rows' {
        $missingFile = Join-Path -Path $TestDrive -ChildPath 'missing.json'
        $rows = @(ConvertTo-CsvRow -Objects @(Get-BookRecordFromJsonFile -Files @(Get-Item -LiteralPath $missingFile)))
        $row = @($rows | Where-Object { $_.ProposedAction -eq 'NOT_AUDITED' })[0]
        $row.Title | Should Be 'Blocked'
        $row.Reason | Should Match 'blocked for prohibited content'
    }
}

Describe 'ConvertTo-CsvRow' {
    It 'maps the English property names to the five columns' {
        $row = ConvertTo-CsvRow -Objects @([pscustomobject]@{ Title = 'T'; Author = 'A'; ProposedAction = 'ADD'; Tag = 'Fantasy'; Reason = 'R' })
        $row.Title | Should Be 'T'
        $row.Author | Should Be 'A'
        $row.ProposedAction | Should Be 'ADD'
        $row.Tag | Should Be 'Fantasy'
        $row.Reason | Should Be 'R'
    }

    It 'maps the German property names' {
        $reasonName = 'Begr' + [char]0x00FC + 'ndung'
        $item = [pscustomobject]@{ Titel = 'T'; Autor = 'A'; Aktion = 'REMOVE' }
        $item | Add-Member -NotePropertyName $reasonName -NotePropertyValue 'Grund'
        $row = ConvertTo-CsvRow -Objects @($item)
        $row.Title | Should Be 'T'
        $row.Author | Should Be 'A'
        $row.ProposedAction | Should Be 'REMOVE'
        $row.Reason | Should Be 'Grund'
    }

    It 'falls back to the Action property when ProposedAction is missing' {
        $row = ConvertTo-CsvRow -Objects @([pscustomobject]@{ Title = 'T'; Action = 'NO_CHANGES' })
        $row.ProposedAction | Should Be 'NO_CHANGES'
    }

    It 'skips records without title, author, action, and reason' {
        @(ConvertTo-CsvRow -Objects @([pscustomobject]@{ Tag = 'Only tag' })).Count | Should Be 0
    }
}

Describe 'Invoke-LibreOfficeConversion' {
    $outputFolder = Join-Path -Path $TestDrive -ChildPath 'out'
    New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    $csvPath = Join-Path -Path $TestDrive -ChildPath 'review.csv'
    Set-Content -LiteralPath $csvPath -Value 'Title|Author'
    $expectedOdsPath = Join-Path -Path $outputFolder -ChildPath 'review.ods'
    $fakeProcess = [pscustomobject]@{ ExitCode = 0; Id = 0 }
    $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
    Mock Get-CimInstance { }
    Mock Stop-Process { }

    It 'returns the path of the created ODS file' {
        Mock Start-Process { Set-Content -LiteralPath $expectedOdsPath -Value 'ods'; $fakeProcess }
        Invoke-LibreOfficeConversion -LibreOfficeExe 'soffice.exe' -CsvFilePath $csvPath -OutputFolder $outputFolder | Should Be $expectedOdsPath
        Assert-MockCalled Start-Process -Scope It -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'soffice.exe' -and ($ArgumentList -contains '--headless') }
    }

    It 'throws when LibreOffice creates an empty file' {
        Mock Start-Process { [System.IO.File]::WriteAllBytes($expectedOdsPath, [byte[]]@()); $fakeProcess }
        { Invoke-LibreOfficeConversion -LibreOfficeExe 'soffice.exe' -CsvFilePath $csvPath -OutputFolder $outputFolder } | Should Throw 'LibreOffice produced an empty ODS file'
    }
}

Describe 'Set-ConfigItemValue' {
    $configNamespace = 'urn:oasis:names:tc:opendocument:xmlns:config:1.0'
    $document = New-Object -TypeName System.Xml.XmlDocument
    $document.LoadXml("<config:config-item-map-entry xmlns:config=`"$configNamespace`"><config:config-item config:name=`"ZoomValue`" config:type=`"int`">80</config:config-item></config:config-item-map-entry>")
    $namespaceManager = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $document.NameTable
    $namespaceManager.AddNamespace('config', $configNamespace)
    $parent = $document.DocumentElement

    It 'updates an existing config item' {
        Set-ConfigItemValue -Parent $parent -Document $document -NamespaceManager $namespaceManager -ConfigNamespace $configNamespace -Name 'ZoomValue' -Type 'int' -Value '100'
        $parent.SelectSingleNode("config:config-item[@config:name='ZoomValue']", $namespaceManager).InnerText | Should Be '100'
    }

    It 'adds a missing config item with name and type' {
        Set-ConfigItemValue -Parent $parent -Document $document -NamespaceManager $namespaceManager -ConfigNamespace $configNamespace -Name 'ShowGrid' -Type 'boolean' -Value 'true'
        $node = $parent.SelectSingleNode("config:config-item[@config:name='ShowGrid']", $namespaceManager)
        $node.InnerText | Should Be 'true'
        $node.GetAttribute('type', $configNamespace) | Should Be 'boolean'
    }

    It 'changes nothing with -WhatIf' {
        Set-ConfigItemValue -Parent $parent -Document $document -NamespaceManager $namespaceManager -ConfigNamespace $configNamespace -Name 'ZoomValue' -Type 'int' -Value '50' -WhatIf
        $parent.SelectSingleNode("config:config-item[@config:name='ZoomValue']", $namespaceManager).InnerText | Should Be '100'
    }
}

Describe 'Logging setup' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $startLogCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Start-Log' })
    $loggingImports = @($commands | Where-Object { $_.GetCommandName() -eq 'Import-Module' -and $_.Extent.Text -match '\bDonGrobione\.Logging\b' })

    It 'starts a log session' {
        $startLogCalls.Count | Should BeGreaterThan 0
    }

    It 'turns off size-based rotation in every Start-Log call' {
        foreach ($call in $startLogCalls) {
            $call.Extent.Text | Should Match '-MaxFileSizeMB\s+0\b'
        }
    }

    It 'requires DonGrobione.Logging 2.2.0 or later, which supports -MaxFileSizeMB' {
        $loggingImports.Count | Should Be 1
        $loggingImports[0].Extent.Text | Should Match '-MinimumVersion\s+2\.2\.0\b'
    }

    It 'imports DonGrobione.Logging without -Force, which would reset a running log session' {
        $loggingImports[0].Extent.Text | Should Not Match '-Force\b'
    }
}