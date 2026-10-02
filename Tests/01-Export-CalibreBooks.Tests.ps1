<#
.SYNOPSIS
    Pester tests for the book file functions in 01-Export-CalibreBooks.ps1.

.DESCRIPTION
    Covers the ChangedWithinDays script parameter, Get-BookFile, Get-PrimaryBookFile, ConvertTo-FormatDisplayText, Get-BookExportFileName, Write-JsonFile, and the book cache functions Test-CalibreUuid, Get-BookCachePath, Get-CachedBookExport, Write-BookCacheFile, and Remove-StaleBookCacheFile. The Incremental file writing tests check in the source that the export files are written inside the book loop. The Book cache workflow tests check in the source that calibredb exports the UUID, that the cache lives in 01-Cache, and that the cache cleanup runs before the date filter. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. The parameter metadata is read with Get-Command, which does not run the script. The book directories are created under $TestDrive; Calibre is not started.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\01-Export-CalibreBooks.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '01-Export-CalibreBooks.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @('Get-BookFile', 'Get-PrimaryBookFile', 'ConvertTo-FormatDisplayText', 'Get-BookExportFileName', 'ConvertTo-JsonUtf8', 'Write-JsonFile', 'Test-CalibreUuid', 'Get-BookCachePath', 'Get-CachedBookExport', 'Write-BookCacheFile', 'Remove-StaleBookCacheFile')
foreach ($functionName in $functionNames) {
    $definition = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

$supportedExtensions = @('.epub', '.azw3', '.mobi', '.pdf')

# Creates a book directory with the given file names under $TestDrive and returns it as a DirectoryInfo.
function Add-TestBookDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$FileNames
    )

    $directory = New-Item -Path (Join-Path -Path $TestDrive -ChildPath $Name) -ItemType Directory -Force
    foreach ($fileName in $FileNames) {
        $null = New-Item -Path (Join-Path -Path $directory.FullName -ChildPath $fileName) -ItemType File -Force
    }

    return $directory
}

Describe '01-Export-CalibreBooks.ps1 source' {
    It 'parses without errors' {
        @($parseErrors).Count | Should Be 0
    }

    It 'has an optional integer parameter ChangedWithinDays limited to 0..36500' {
        $parameter = (Get-Command -Name $scriptPath).Parameters['ChangedWithinDays']
        $parameter.ParameterType | Should Be ([int])
        $range = @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })[0]
        $range.MinRange | Should Be 0
        $range.MaxRange | Should Be 36500
        @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should Be 0
    }
}

Describe 'Get-BookFile' {
    It 'returns all files of the book directory' {
        $directory = Add-TestBookDirectory -Name 'Book (1)' -FileNames @('book.epub', 'cover.jpg', 'metadata.opf')
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1 }) -BookDirectories @{ '1' = $directory })
        $files.Count | Should Be 3
    }

    It 'returns no files when the book has no directory' {
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 2 }) -BookDirectories @{})
        $files.Count | Should Be 0
    }

    It 'returns no files when the book has no id' {
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = $null }) -BookDirectories @{})
        $files.Count | Should Be 0
    }
}

Describe 'Get-PrimaryBookFile' {
    It 'prefers the format listed first' {
        $directory = Add-TestBookDirectory -Name 'Book (3)' -FileNames @('book.pdf', 'book.mobi', 'book.EPUB')
        $result = Get-PrimaryBookFile -Files @($directory.GetFiles()) -SupportedExtensions $supportedExtensions
        $result.Name | Should Be 'book.EPUB'
    }

    It 'falls back to a later format' {
        $directory = Add-TestBookDirectory -Name 'Book (4)' -FileNames @('book.pdf', 'cover.jpg')
        $result = Get-PrimaryBookFile -Files @($directory.GetFiles()) -SupportedExtensions $supportedExtensions
        $result.Name | Should Be 'book.pdf'
    }

    It 'returns $null when no file has a supported format' {
        $directory = Add-TestBookDirectory -Name 'Book (5)' -FileNames @('book.cbz', 'cover.jpg')
        Get-PrimaryBookFile -Files @($directory.GetFiles()) -SupportedExtensions $supportedExtensions | Should Be $null
    }

    It 'returns $null for an empty file list' {
        Get-PrimaryBookFile -Files @() -SupportedExtensions $supportedExtensions | Should Be $null
    }

    It 'returns $null for $null instead of failing parameter binding' {
        Get-PrimaryBookFile -Files $null -SupportedExtensions $supportedExtensions | Should Be $null
    }

    It 'accepts the unwrapped result of Get-BookFile for a book without directory' {
        $bookFiles = Get-BookFile -Book ([PSCustomObject]@{ id = 6 }) -BookDirectories @{}
        Get-PrimaryBookFile -Files $bookFiles -SupportedExtensions $supportedExtensions | Should Be $null
    }
}

Describe 'Book file resolution in the export loop' {
    $loopStatement = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$BookFiles'
        }, $true)

    It 'wraps Get-BookFile in @() so a book without directory yields an empty array' {
        $loopStatement.Right.Extent.Text | Should Match '^@\(\s*Get-BookFile\b'
    }

    It 'yields an empty array and no primary file for a book without directory' {
        $bookFiles = @(Get-BookFile -Book ([PSCustomObject]@{ id = 7 }) -BookDirectories @{})
        $bookFiles.Count | Should Be 0
        Get-PrimaryBookFile -Files $bookFiles -SupportedExtensions $supportedExtensions | Should Be $null
        ConvertTo-FormatDisplayText -Extensions @($bookFiles | ForEach-Object Extension) | Should Be 'none'
    }

    It 'yields the single file for a book directory with one file' {
        $directory = Add-TestBookDirectory -Name 'Book (8)' -FileNames @('book.epub')
        $bookFiles = @(Get-BookFile -Book ([PSCustomObject]@{ id = 8 }) -BookDirectories @{ '8' = $directory })
        $bookFiles.Count | Should Be 1
        (Get-PrimaryBookFile -Files $bookFiles -SupportedExtensions $supportedExtensions).Name | Should Be 'book.epub'
    }
}

Describe 'ConvertTo-FormatDisplayText' {
    It 'lists the formats upper-case without dots in input order' {
        ConvertTo-FormatDisplayText -Extensions $supportedExtensions | Should Be 'EPUB, AZW3, MOBI, PDF'
    }

    It 'removes duplicates and empty entries' {
        ConvertTo-FormatDisplayText -Extensions @('.cbz', '.CBZ', '', '.jpg') | Should Be 'CBZ, JPG'
    }

    It 'returns "none" for an empty list' {
        ConvertTo-FormatDisplayText -Extensions @() | Should Be 'none'
    }
}

Describe 'Get-BookExportFileName' {
    It 'pads the file number to two digits' {
        Get-BookExportFileName -FileNumber 1 -FileCount 1 -ExportDate '2026-10-02_10-00-00' | Should Be '01-Export-CalibreBooks_01_2026-10-02_10-00-00.json'
    }

    It 'pads the file number to the digit count of the file count' {
        Get-BookExportFileName -FileNumber 7 -FileCount 466 -ExportDate '2026-10-02_10-00-00' | Should Be '01-Export-CalibreBooks_007_2026-10-02_10-00-00.json'
    }

    It 'rejects a file number of 0' {
        { Get-BookExportFileName -FileNumber 0 -FileCount 1 -ExportDate '2026-10-02_10-00-00' } | Should Throw
    }
}

Describe 'Write-JsonFile' {
    It 'writes a batch as a JSON array in UTF-8 without BOM and keeps non-ASCII characters' {
        $path = Join-Path -Path $TestDrive -ChildPath 'batch.json'
        $batch = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $batch.Add([PSCustomObject]@{ Title = 'Begründung' })
        $batch.Add([PSCustomObject]@{ Title = 'Second' })
        Write-JsonFile -Path $path -InputObject $batch.ToArray() -Depth 10

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should Not Be 0xEF
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should Match 'Begründung'
        $parsed = ConvertFrom-Json -InputObject $text
        $parsed.Count | Should Be 2
        $parsed[1].Title | Should Be 'Second'
    }
}

Describe 'Test-CalibreUuid' {
    It 'accepts a canonical UUID in any case' {
        Test-CalibreUuid -Uuid '0f8fad5b-d9cb-469f-a165-70867728950e' | Should Be $true
        Test-CalibreUuid -Uuid '0F8FAD5B-D9CB-469F-A165-70867728950E' | Should Be $true
    }

    It 'rejects empty, braced, and path-like values' {
        Test-CalibreUuid -Uuid '' | Should Be $false
        Test-CalibreUuid -Uuid $null | Should Be $false
        Test-CalibreUuid -Uuid '{0f8fad5b-d9cb-469f-a165-70867728950e}' | Should Be $false
        Test-CalibreUuid -Uuid '..\0f8fad5b-d9cb-469f-a165-70867728950e' | Should Be $false
        Test-CalibreUuid -Uuid "0f8fad5b-d9cb-469f-a165-70867728950e`n" | Should Be $false
    }
}

Describe 'Get-BookCachePath' {
    It 'returns <uuid>.json in lower case inside the cache directory' {
        $path = Get-BookCachePath -CacheDirectory 'C:\Cache' -Uuid '0F8FAD5B-D9CB-469F-A165-70867728950E'
        $path | Should Be 'C:\Cache\0f8fad5b-d9cb-469f-a165-70867728950e.json'
    }

    It 'returns $null for an invalid UUID' {
        Get-BookCachePath -CacheDirectory 'C:\Cache' -Uuid '..\..\evil' | Should Be $null
        Get-BookCachePath -CacheDirectory 'C:\Cache' -Uuid '' | Should Be $null
    }
}

Describe 'Write-BookCacheFile and Get-CachedBookExport' {
    $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'cache-read'
    $null = New-Item -Path $cacheDirectory -ItemType Directory -Force
    $path = Join-Path -Path $cacheDirectory -ChildPath '0f8fad5b-d9cb-469f-a165-70867728950e.json'
    $record = [PSCustomObject]@{ Uuid = '0f8fad5b-d9cb-469f-a165-70867728950e'; LastModified = '2026-10-01T10:00:00+00:00'; Title = 'Book'; BookContent = 'Begründung' }

    It 'writes the cache file in UTF-8 without BOM' {
        Write-BookCacheFile -Path $path -Record $record
        [System.IO.File]::ReadAllBytes($path)[0] | Should Not Be 0xEF
    }

    It 'returns the cached record with non-ASCII content when last_modified matches' {
        $cached = Get-CachedBookExport -Path $path -LastModified '2026-10-01T10:00:00+00:00'
        $cached.BookContent | Should Be 'Begründung'
        $cached.Title | Should Be 'Book'
    }

    It 'returns $null when last_modified differs' {
        Get-CachedBookExport -Path $path -LastModified '2026-10-02T10:00:00+00:00' | Should Be $null
    }

    It 'returns $null when the cache file does not exist' {
        Get-CachedBookExport -Path (Join-Path -Path $cacheDirectory -ChildPath 'missing.json') -LastModified 'x' | Should Be $null
    }

    It 'returns $null for a corrupt cache file' {
        $corruptPath = Join-Path -Path $cacheDirectory -ChildPath 'corrupt.json'
        Set-Content -LiteralPath $corruptPath -Value '{ not json'
        Get-CachedBookExport -Path $corruptPath -LastModified 'x' | Should Be $null
    }

    It 'returns $null for a cache file without BookContent' {
        $partialPath = Join-Path -Path $cacheDirectory -ChildPath 'partial.json'
        Set-Content -LiteralPath $partialPath -Value '{ "LastModified": "x" }'
        Get-CachedBookExport -Path $partialPath -LastModified 'x' | Should Be $null
    }

    It 'returns $null for a cache file whose BookContent is null, so the content is extracted again' {
        $nullPath = Join-Path -Path $cacheDirectory -ChildPath 'null-content.json'
        Set-Content -LiteralPath $nullPath -Value '{ "LastModified": "x", "BookContent": null }'
        Get-CachedBookExport -Path $nullPath -LastModified 'x' | Should Be $null
    }

    It 'writes nothing with -WhatIf' {
        $whatIfPath = Join-Path -Path $cacheDirectory -ChildPath 'whatif.json'
        Write-BookCacheFile -Path $whatIfPath -Record $record -WhatIf
        Test-Path -LiteralPath $whatIfPath | Should Be $false
    }
}

# Creates a cache directory under $TestDrive with a known, a stale, a .gitkeep, and a non-UUID file, and returns its path.
function Add-TestCacheDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $directory = Join-Path -Path $TestDrive -ChildPath $Name
    $null = New-Item -Path $directory -ItemType Directory -Force
    foreach ($fileName in @('0f8fad5b-d9cb-469f-a165-70867728950e.json', '7c9e6679-7425-40de-944b-e07fc1f90ae7.json', '.gitkeep', 'notes.json')) {
        Set-Content -LiteralPath (Join-Path -Path $directory -ChildPath $fileName) -Value '{}'
    }

    return $directory
}

Describe 'Remove-StaleBookCacheFile' {
    $knownUuid = '0f8fad5b-d9cb-469f-a165-70867728950e'
    $staleUuid = '7c9e6679-7425-40de-944b-e07fc1f90ae7'

    It 'removes only cache files of books that are not in the library and returns them' {
        $directory = Add-TestCacheDirectory -Name 'cache-clean'
        $removed = @(Remove-StaleBookCacheFile -CacheDirectory $directory -LibraryUuids @($knownUuid.ToUpperInvariant()))
        $removed.Count | Should Be 1
        $removed[0].Name | Should Be "$staleUuid.json"
        Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath "$staleUuid.json") | Should Be $false
        Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath "$knownUuid.json") | Should Be $true
        Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath '.gitkeep') | Should Be $true
        Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath 'notes.json') | Should Be $true
    }

    It 'removes nothing with -WhatIf' {
        $directory = Add-TestCacheDirectory -Name 'cache-whatif'
        $removed = @(Remove-StaleBookCacheFile -CacheDirectory $directory -LibraryUuids @() -WhatIf)
        $removed.Count | Should Be 0
        Test-Path -LiteralPath (Join-Path -Path $directory -ChildPath "$staleUuid.json") | Should Be $true
    }

    It 'returns nothing for a missing cache directory' {
        @(Remove-StaleBookCacheFile -CacheDirectory (Join-Path -Path $TestDrive -ChildPath 'no-cache') -LibraryUuids @($knownUuid)).Count | Should Be 0
    }
}

Describe 'Book cache workflow' {
    $commands = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $cleanupCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Remove-StaleBookCacheFile' })
    $emptyCheck = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match '^-not \$Books'
        }, $true)
    $dateFilter = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$BooksWithDates'
        }, $true)

    It 'asks calibredb for the uuid field' {
        $scriptAst.Extent.Text | Should Match '--fields=\S*\buuid\b'
    }

    It 'stores the cache in the 01-Cache folder' {
        $scriptAst.Extent.Text | Should Match '-ChildPath "01-Cache"'
    }

    It 'writes a cache file only for books with content' {
        $cacheWrite = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-BookCacheFile' })
        $cacheWrite.Count | Should Be 1
        $condition = $cacheWrite[0].Parent
        while ($null -ne $condition -and $condition -isnot [System.Management.Automation.Language.IfStatementAst]) {
            $condition = $condition.Parent
        }
        $condition.Clauses[0].Item1.Extent.Text | Should Match '\$null -ne \$BookContent'
    }

    It 'runs the cache cleanup once, before the date filter and the empty export check' {
        $cleanupCalls.Count | Should Be 1
        $cleanupCalls[0].Extent.StartOffset -lt $dateFilter.Extent.StartOffset | Should Be $true
        $cleanupCalls[0].Extent.StartOffset -lt $emptyCheck.Extent.StartOffset | Should Be $true
    }
}

Describe 'Incremental file writing' {
    $bookLoop = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$Books'
        }, $true)
    # Write-BookCacheFile calls Write-JsonFile too, so only calls outside function definitions are counted.
    $writeCalls = @($scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-JsonFile'
            }, $true) | Where-Object {
            $parent = $_.Parent
            while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $parent = $parent.Parent
            }
            $null -eq $parent
        })

    It 'writes every export file inside the book loop' {
        $writeCalls.Count | Should Be 1
        $bookLoop.Extent.StartOffset -lt $writeCalls[0].Extent.StartOffset | Should Be $true
        $writeCalls[0].Extent.EndOffset -lt $bookLoop.Extent.EndOffset | Should Be $true
    }

    It 'does not collect the output of the book loop in a variable' {
        $bookLoop.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] | Should Be $false
        $bookLoop.Parent.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] | Should Be $false
    }

    It 'clears the batch after writing a file' {
        $bookLoop.Body.Extent.Text | Should Match '\$Batch\.Clear\(\)'
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