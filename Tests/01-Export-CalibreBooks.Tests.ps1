<#
.SYNOPSIS
    Pester tests for the book file functions in 01-Export-CalibreBooks.ps1.

.DESCRIPTION
    Covers the ChangedWithinDays script parameter, Get-BookFile (book file paths from the calibredb field formats), Get-PrimaryBookFile, ConvertTo-FormatDisplayText, Get-BookExportFileName, ConvertTo-JsonUtf8 (control characters stay escaped, literal backslash-u text survives), Write-JsonFile, and the book cache functions Test-CalibreUuid, Get-BookCachePath, Get-CachedBookExport, Write-BookCacheFile, and Remove-StaleBookCacheFile, and the content profile functions Get-ContentHash, Get-MetadataHash, and Get-CachedContentProfile (including web profiles and WebNotFound markers), and the functions for books without text, Get-WordCount and ConvertTo-PlainText. The Incremental file writing tests check in the source that the export files are written inside the book loop. The Book cache workflow tests check in the source that calibredb exports the UUID, that the cache lives in 01-Cache, that every book except failed extractions is cached and the cache files carry the cache version, that every read, written, and removed cache file is logged as DEBUG, and that the cache cleanup runs before the date filter. The Books without text tests check in the source that calibredb exports the description, that books below $MinimumContentWords or without a supported file get ContentStatus NoText, and that their ContentHash is the metadata hash. The Export record tests check in the source that the export record holds the Uuid, Description, ContentStatus, ContentHash, and content profile fields and that the cache record adds Uuid only once. The Export scope file tests check in the source that 01-Export-Scope.json marks only an export of all books as full library. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. The parameter metadata is read with Get-Command, which does not run the script. The book folders are created under $TestDrive; Calibre is not started.
    The Logging setup tests check in the source that the script imports DonGrobione.Logging 2.2.0 or later and turns off size-based log rotation with Start-Log -MaxFileSizeMB 0.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\01-Export-CalibreBooks.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '01-Export-CalibreBooks.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @('Get-BookFile', 'Get-PrimaryBookFile', 'ConvertTo-FormatDisplayText', 'Get-BookExportFileName', 'ConvertTo-JsonUtf8', 'Write-JsonFile', 'Test-CalibreUuid', 'Get-BookCachePath', 'Get-CachedBookExport', 'Write-BookCacheFile', 'Remove-StaleBookCacheFile', 'Get-ContentHash', 'Get-MetadataHash', 'Get-CachedContentProfile', 'Get-WordCount', 'ConvertTo-PlainText')
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
    $libraryPath = Join-Path -Path $TestDrive -ChildPath 'Library'
    $directory = Add-TestBookDirectory -Name 'Library\Author\Book (1)' -FileNames @('book.epub', 'book.pdf', 'cover.jpg')
    # calibredb returns the format paths with forward slashes.
    $epubPath = (Join-Path -Path $directory.FullName -ChildPath 'book.epub').Replace('\', '/')
    $pdfPath = (Join-Path -Path $directory.FullName -ChildPath 'book.pdf').Replace('\', '/')

    It 'returns the files listed in the formats field, but not other files of the book folder' {
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1; formats = @($epubPath, $pdfPath) }) -LibraryPath $libraryPath)
        $files.Count | Should Be 2
        ($files | ForEach-Object Name) -join ',' | Should Be 'book.epub,book.pdf'
    }

    It 'ignores the files of another folder with the same book id' {
        $null = Add-TestBookDirectory -Name 'Library\Author\Old Title (1)' -FileNames @('old.epub')
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1; formats = @($pdfPath) }) -LibraryPath $libraryPath)
        $files.Count | Should Be 1
        $files[0].Name | Should Be 'book.pdf'
    }

    It 'skips listed files that do not exist' {
        $missingPath = (Join-Path -Path $directory.FullName -ChildPath 'missing.mobi').Replace('\', '/')
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1; formats = @($missingPath, $epubPath) }) -LibraryPath $libraryPath)
        $files.Count | Should Be 1
        $files[0].Name | Should Be 'book.epub'
    }

    It 'skips files outside the library folder, also via ..' {
        $outside = Add-TestBookDirectory -Name 'Outside' -FileNames @('book.epub')
        $outsidePath = Join-Path -Path $outside.FullName -ChildPath 'book.epub'
        $traversalPath = Join-Path -Path $libraryPath -ChildPath '..\Outside\book.epub'
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1; formats = @($outsidePath, $traversalPath) }) -LibraryPath $libraryPath)
        $files.Count | Should Be 0
    }

    It 'skips a folder whose name only starts with the library folder name' {
        $sibling = Add-TestBookDirectory -Name 'Library2' -FileNames @('book.epub')
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1; formats = @((Join-Path -Path $sibling.FullName -ChildPath 'book.epub')) }) -LibraryPath $libraryPath)
        $files.Count | Should Be 0
    }

    It 'returns no files when the book has no formats' {
        @(Get-BookFile -Book ([PSCustomObject]@{ id = 2; formats = @() }) -LibraryPath $libraryPath).Count | Should Be 0
        @(Get-BookFile -Book ([PSCustomObject]@{ id = 2; formats = $null }) -LibraryPath $libraryPath).Count | Should Be 0
        @(Get-BookFile -Book ([PSCustomObject]@{ id = 2 }) -LibraryPath $libraryPath).Count | Should Be 0
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

    It 'accepts the unwrapped result of Get-BookFile for a book without formats' {
        $bookFiles = Get-BookFile -Book ([PSCustomObject]@{ id = 6 }) -LibraryPath $TestDrive
        Get-PrimaryBookFile -Files $bookFiles -SupportedExtensions $supportedExtensions | Should Be $null
    }
}

Describe 'Book file resolution in the export loop' {
    $loopStatement = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$BookFiles'
        }, $true)

    It 'wraps Get-BookFile in @() so a book without formats yields an empty array' {
        $loopStatement.Right.Extent.Text | Should Match '^@\(\s*Get-BookFile\b'
    }

    It 'requests UTF-8 from ebook-convert and reads the text file as UTF-8' {
        $scriptAst.Extent.Text | Should Match "'--txt-output-encoding=utf-8'"
        $scriptAst.Extent.Text | Should Match 'ReadAllText\(\$TempTextFile, \[System\.Text\.Encoding\]::UTF8\)'
    }

    It 'asks calibredb for the formats field' {
        $scriptAst.Extent.Text | Should Match '--fields=\S*\bformats\b'
    }

    It 'no longer scans the library folder for book directories' {
        $scriptAst.Extent.Text | Should Not Match 'BookDirectories'
        $scriptAst.Extent.Text | Should Not Match 'Get-ChildItem -LiteralPath \$LibraryPath'
    }

    It 'yields an empty array and no primary file for a book without formats' {
        $bookFiles = @(Get-BookFile -Book ([PSCustomObject]@{ id = 7 }) -LibraryPath $TestDrive)
        $bookFiles.Count | Should Be 0
        Get-PrimaryBookFile -Files $bookFiles -SupportedExtensions $supportedExtensions | Should Be $null
        ConvertTo-FormatDisplayText -Extensions @($bookFiles | ForEach-Object Extension) | Should Be 'none'
    }

    It 'yields the single file for a book with one format' {
        $directory = Add-TestBookDirectory -Name 'Library\Author\Book (8)' -FileNames @('book.epub')
        $book = [PSCustomObject]@{ id = 8; formats = @((Join-Path -Path $directory.FullName -ChildPath 'book.epub').Replace('\', '/')) }
        $bookFiles = @(Get-BookFile -Book $book -LibraryPath (Join-Path -Path $TestDrive -ChildPath 'Library'))
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

Describe 'ConvertTo-JsonUtf8' {
    It 'writes &, apostrophe, <, and > as characters and keeps non-ASCII characters' {
        $text = "it's <b> & Begr$([char]0xFC)ndung $([char]0x2013) $([char]0x3088)"
        $json = ConvertTo-JsonUtf8 -InputObject ([pscustomobject]@{ Text = $text })
        $json | Should Not Match '\\u00'
        (ConvertFrom-Json -InputObject $json).Text | Should BeExactly $text
    }

    It 'keeps control characters escaped, so the JSON stays valid' {
        $text = 'a' + [char]0x01 + 'b' + [char]0x0B + 'c'
        $json = ConvertTo-JsonUtf8 -InputObject ([pscustomobject]@{ Text = $text })
        $json | Should Match '\\u0001'
        (ConvertFrom-Json -InputObject $json).Text | Should BeExactly $text
    }

    It 'keeps literal backslash-u text in the content unchanged' {
        # Built from parts, so no editor turns the escape sequences into characters.
        $text = 'regex \' + 'u0041 and \\' + 'u0026 and \' + 'u005c'
        $json = ConvertTo-JsonUtf8 -InputObject ([pscustomobject]@{ Text = $text })
        (ConvertFrom-Json -InputObject $json).Text | Should BeExactly $text
    }

    It 'keeps a surrogate pair (emoji)' {
        $text = 'x' + [char]0xD83D + [char]0xDE00
        (ConvertFrom-Json -InputObject (ConvertTo-JsonUtf8 -InputObject ([pscustomobject]@{ Text = $text }))).Text | Should BeExactly $text
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
    $record = [PSCustomObject]@{ CacheVersion = 1; Uuid = '0f8fad5b-d9cb-469f-a165-70867728950e'; LastModified = '2026-10-01T10:00:00+00:00'; Title = 'Book'; BookContent = 'Begründung' }

    # Writes a cache file with the given JSON text to the test cache directory and returns its path.
    function Add-TestCacheFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$Json
        )

        $filePath = Join-Path -Path $cacheDirectory -ChildPath $Name
        Set-Content -LiteralPath $filePath -Value $Json
        return $filePath
    }

    It 'writes the cache file in UTF-8 without BOM' {
        Write-BookCacheFile -Path $path -Record $record
        [System.IO.File]::ReadAllBytes($path)[0] | Should Not Be 0xEF
    }

    It 'returns the cached record with non-ASCII content when last_modified and the cache version match' {
        $cached = Get-CachedBookExport -Path $path -LastModified '2026-10-01T10:00:00+00:00' -CacheVersion 1
        $cached.BookContent | Should Be 'Begründung'
        $cached.Title | Should Be 'Book'
    }

    It 'returns $null when last_modified differs' {
        Get-CachedBookExport -Path $path -LastModified '2026-10-02T10:00:00+00:00' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null when the cache version differs' {
        Get-CachedBookExport -Path $path -LastModified '2026-10-01T10:00:00+00:00' -CacheVersion 2 | Should Be $null
    }

    It 'returns $null for a cache file without cache version, as written before version 4.2' {
        $oldPath = Add-TestCacheFile -Name 'old-format.json' -Json '{ "LastModified": "x", "BookContent": "Text" }'
        Get-CachedBookExport -Path $oldPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null when the cache file does not exist' {
        Get-CachedBookExport -Path (Join-Path -Path $cacheDirectory -ChildPath 'missing.json') -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null for a corrupt cache file' {
        $corruptPath = Add-TestCacheFile -Name 'corrupt.json' -Json '{ not json'
        Get-CachedBookExport -Path $corruptPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null for a cache file without BookContent' {
        $partialPath = Add-TestCacheFile -Name 'partial.json' -Json '{ "CacheVersion": 1, "LastModified": "x" }'
        Get-CachedBookExport -Path $partialPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null for a cache file whose BookContent is null, so the content is extracted again' {
        $nullPath = Add-TestCacheFile -Name 'null-content.json' -Json '{ "CacheVersion": 1, "LastModified": "x", "BookContent": null }'
        Get-CachedBookExport -Path $nullPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null for a cache file whose BookContent is empty, so the content is extracted again' {
        $emptyPath = Add-TestCacheFile -Name 'empty-content.json' -Json '{ "CacheVersion": 1, "LastModified": "x", "BookContent": "" }'
        Get-CachedBookExport -Path $emptyPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'returns a cached book without text (ContentStatus NoText) although BookContent is null' {
        $noTextPath = Add-TestCacheFile -Name 'no-text.json' -Json '{ "CacheVersion": 1, "LastModified": "x", "ContentStatus": "NoText", "BookContent": null }'
        (Get-CachedBookExport -Path $noTextPath -LastModified 'x' -CacheVersion 1).ContentStatus | Should Be 'NoText'
    }

    It 'returns $null for a cached book without text when last_modified differs' {
        $noTextPath = Add-TestCacheFile -Name 'no-text-old.json' -Json '{ "CacheVersion": 1, "LastModified": "x", "ContentStatus": "NoText", "BookContent": null }'
        Get-CachedBookExport -Path $noTextPath -LastModified 'y' -CacheVersion 1 | Should Be $null
    }

    It 'returns $null for a null BookContent with another ContentStatus' {
        $failedPath = Add-TestCacheFile -Name 'failed.json' -Json '{ "CacheVersion": 1, "LastModified": "x", "ContentStatus": "Failed", "BookContent": null }'
        Get-CachedBookExport -Path $failedPath -LastModified 'x' -CacheVersion 1 | Should Be $null
    }

    It 'rejects a cache version of 0' {
        { Get-CachedBookExport -Path $path -LastModified 'x' -CacheVersion 0 } | Should Throw
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

    It 'logs every read, written, and removed cache file as DEBUG with its display path' {
        $debugCacheLogs = @($commands | Where-Object {
                $_.GetCommandName() -eq 'Write-ScriptLog' -and $_.Extent.Text -match '-Level DEBUG' -and $_.Extent.Text -match 'ConvertTo-DisplayPath -Path \$CachePath'
            } | ForEach-Object { $_.Extent.Text })
        @($debugCacheLogs | Where-Object { $_ -match 'Read cache file' }).Count | Should Be 1
        @($debugCacheLogs | Where-Object { $_ -match 'Wrote cache file' }).Count | Should Be 1
        @($debugCacheLogs | Where-Object { $_ -match 'Removed outdated cache file' }).Count | Should Be 1
    }

    It 'logs a written cache file only after Write-BookCacheFile succeeded' {
        $writeCall = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-BookCacheFile' })[0]
        $tryBody = $writeCall.Parent.Parent
        $tryBody.Extent.Text | Should Match '(?s)Write-BookCacheFile.*Wrote cache file'
        $tryBody.Parent -is [System.Management.Automation.Language.TryStatementAst] | Should Be $true
    }

    It 'writes a cache file for every book except failed extractions' {
        $cacheWrite = @($commands | Where-Object { $_.GetCommandName() -eq 'Write-BookCacheFile' })
        $cacheWrite.Count | Should Be 1
        $condition = $cacheWrite[0].Parent
        while ($null -ne $condition -and $condition -isnot [System.Management.Automation.Language.IfStatementAst]) {
            $condition = $condition.Parent
        }
        $condition.Clauses[0].Item1.Extent.Text | Should Match '\$ContentStatus -ne ''Failed'''
    }

    It 'deletes an outdated cache file only for failed extractions' {
        $scriptAst.Extent.Text | Should Match '\$null -eq \$CachedBook -and \$null -ne \$CachePath -and \$ContentStatus -eq ''Failed'''
    }

    It 'rewrites a cache file whose ContentHash changed' {
        $scriptAst.Extent.Text | Should Match '\[string\]\$CachedBook\.ContentHash -cne \[string\]\$ContentHash'
    }

    It 'writes the cache version into every cache file and checks it when reading' {
        $scriptAst.Extent.Text | Should Match '\$BookCacheVersion = \d+'
        $scriptAst.Extent.Text | Should Match 'CacheVersion\s*=\s*\$BookCacheVersion'
        $scriptAst.Extent.Text | Should Match 'Get-CachedBookExport [^\r\n]*-CacheVersion \$BookCacheVersion'
    }

    It 'runs the cache cleanup once, before the date filter and the empty export check' {
        $cleanupCalls.Count | Should Be 1
        $cleanupCalls[0].Extent.StartOffset -lt $dateFilter.Extent.StartOffset | Should Be $true
        $cleanupCalls[0].Extent.StartOffset -lt $emptyCheck.Extent.StartOffset | Should Be $true
    }
}

Describe 'Get-ContentHash' {
    It 'returns the lower-case SHA256 hex string of the text' {
        Get-ContentHash -Text 'abc' | Should BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It 'hashes the UTF-8 bytes of non-ASCII text' {
        $text = "Begr$([char]0xFC)ndung"
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $expected = (($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join '')
        $sha256.Dispose()
        Get-ContentHash -Text $text | Should BeExactly $expected
    }

    It 'returns $null for null or empty text' {
        Get-ContentHash -Text $null | Should Be $null
        Get-ContentHash -Text '' | Should Be $null
    }
}

Describe 'Get-CachedContentProfile' {
    $cacheDirectory = Join-Path -Path $TestDrive -ChildPath 'cache-profile'
    $null = New-Item -Path $cacheDirectory -ItemType Directory -Force

    # Writes a cache file with the given JSON text to the test cache directory and returns its path.
    function Add-TestProfileFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,
            [Parameter(Mandatory = $true)]
            [string]$Json
        )

        $filePath = Join-Path -Path $cacheDirectory -ChildPath $Name
        [System.IO.File]::WriteAllText($filePath, $Json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
        return $filePath
    }

    $profilePath = Add-TestProfileFile -Name 'profile.json' -Json '{ "CacheVersion": 1, "LastModified": "old", "ContentHash": "abc123", "ContentProfileVersion": 1, "ContentProfile": "Begründung profile", "BookContent": "Text" }'

    It 'returns the profile for the same content hash, independent of last_modified' {
        $result = Get-CachedContentProfile -Path $profilePath -ContentHash 'abc123'
        $result.ContentProfile | Should BeExactly "Begr$([char]0xFC)ndung profile"
        $result.ContentProfileVersion | Should Be 1
    }

    It 'returns $null when the content hash differs' {
        Get-CachedContentProfile -Path $profilePath -ContentHash 'other' | Should Be $null
        Get-CachedContentProfile -Path $profilePath -ContentHash 'ABC123' | Should Be $null
    }

    It 'returns $null for an empty content hash' {
        Get-CachedContentProfile -Path $profilePath -ContentHash '' | Should Be $null
        Get-CachedContentProfile -Path $profilePath -ContentHash $null | Should Be $null
    }

    It 'returns $null when the cache file has no profile or an empty profile' {
        $noProfile = Add-TestProfileFile -Name 'no-profile.json' -Json '{ "ContentHash": "abc123", "BookContent": "Text" }'
        $emptyProfile = Add-TestProfileFile -Name 'empty-profile.json' -Json '{ "ContentHash": "abc123", "ContentProfileVersion": 1, "ContentProfile": " " }'
        Get-CachedContentProfile -Path $noProfile -ContentHash 'abc123' | Should Be $null
        Get-CachedContentProfile -Path $emptyProfile -ContentHash 'abc123' | Should Be $null
    }

    It 'reports a profile without source as Text' {
        (Get-CachedContentProfile -Path $profilePath -ContentHash 'abc123').ContentProfileSource | Should Be 'Text'
    }

    It 'returns a web profile with its source and cited sources' {
        $webPath = Add-TestProfileFile -Name 'web-profile.json' -Json '{ "ContentHash": "meta1", "ContentProfileVersion": 1, "ContentProfile": "Manga profile", "ContentProfileSource": "Web", "ContentProfileSources": [ { "Title": "example.com", "Url": "https://example.com/a" } ] }'
        $result = Get-CachedContentProfile -Path $webPath -ContentHash 'meta1'
        $result.ContentProfileSource | Should Be 'Web'
        @($result.ContentProfileSources).Count | Should Be 1
        $result.ContentProfileSources[0].Url | Should Be 'https://example.com/a'
    }

    It 'returns a WebNotFound marker with an empty profile' {
        $notFoundPath = Add-TestProfileFile -Name 'not-found.json' -Json '{ "ContentHash": "meta2", "ContentProfileVersion": 1, "ContentProfile": "", "ContentProfileSource": "WebNotFound", "ContentProfileSources": null }'
        $result = Get-CachedContentProfile -Path $notFoundPath -ContentHash 'meta2'
        $result.ContentProfileSource | Should Be 'WebNotFound'
        $result.ContentProfile | Should Be ''
        $result.ContentProfileSources | Should Be $null
    }

    It 'returns $null for a missing or corrupt cache file' {
        $corrupt = Add-TestProfileFile -Name 'corrupt-profile.json' -Json '{ not json'
        Get-CachedContentProfile -Path (Join-Path -Path $cacheDirectory -ChildPath 'missing.json') -ContentHash 'abc123' | Should Be $null
        Get-CachedContentProfile -Path $corrupt -ContentHash 'abc123' | Should Be $null
    }
}

Describe 'Get-MetadataHash' {
    $record = [pscustomobject]@{ Title = 'Vol. 1'; Author = 'A'; Series = 'S'; SeriesIndex = 1.0; IDs = 'isbn:123'; Description = 'Desc'; BookContent = $null }

    It 'returns a SHA256 hex string that differs from the hash of the plain title' {
        $hash = Get-MetadataHash -Record $record
        $hash | Should Match '^[0-9a-f]{64}$'
        $hash | Should Not Be (Get-ContentHash -Text 'Vol. 1')
    }

    It 'returns the same hash for the same metadata' {
        $copy = [pscustomobject]@{ Title = 'Vol. 1'; Author = 'A'; Series = 'S'; SeriesIndex = 1.0; IDs = 'isbn:123'; Description = 'Desc'; Tags = 'Other tags' }
        Get-MetadataHash -Record $copy | Should Be (Get-MetadataHash -Record $record)
    }

    It 'changes when the identifiers or the description change' {
        $otherIds = [pscustomobject]@{ Title = 'Vol. 1'; Author = 'A'; Series = 'S'; SeriesIndex = 1.0; IDs = 'isbn:456'; Description = 'Desc' }
        $otherDescription = [pscustomobject]@{ Title = 'Vol. 1'; Author = 'A'; Series = 'S'; SeriesIndex = 1.0; IDs = 'isbn:123'; Description = 'New' }
        Get-MetadataHash -Record $otherIds | Should Not Be (Get-MetadataHash -Record $record)
        Get-MetadataHash -Record $otherDescription | Should Not Be (Get-MetadataHash -Record $record)
    }

    It 'handles missing and null fields' {
        Get-MetadataHash -Record ([pscustomobject]@{ Title = 'Only title'; Series = $null }) | Should Match '^[0-9a-f]{64}$'
    }
}

Describe 'Get-WordCount' {
    It 'counts whitespace-separated words across lines' {
        Get-WordCount -Text "one two`n`nthree  four" | Should Be 4
    }

    It 'returns 0 for null, empty, and whitespace text' {
        Get-WordCount -Text $null | Should Be 0
        Get-WordCount -Text '' | Should Be 0
        Get-WordCount -Text "  `n " | Should Be 0
    }
}

Describe 'ConvertTo-PlainText' {
    It 'removes tags, keeps paragraphs as lines, and decodes entities' {
        ConvertTo-PlainText -Html '<div><p>First &amp; <b>bold</b>.</p><p>Second&nbsp;line</p></div>' | Should BeExactly "First & bold .`nSecond line"
    }

    It 'turns line break tags into line breaks' {
        ConvertTo-PlainText -Html 'A<br>B<br/>C' | Should BeExactly "A`nB`nC"
    }

    It 'keeps non-ASCII characters' {
        ConvertTo-PlainText -Html "<p>Begr$([char]0xFC)ndung</p>" | Should BeExactly "Begr$([char]0xFC)ndung"
    }

    It 'returns $null for null, empty, and tag-only input' {
        ConvertTo-PlainText -Html $null | Should Be $null
        ConvertTo-PlainText -Html '' | Should Be $null
        ConvertTo-PlainText -Html '<p> </p>' | Should Be $null
    }
}

Describe 'Books without text' {
    It 'asks calibredb for the description field comments' {
        $scriptAst.Extent.Text | Should Match '--fields=\S*\bcomments\b'
    }

    It 'defines the minimum word count and handles shorter texts as books without text' {
        $scriptAst.Extent.Text | Should Match '\$MinimumContentWords = \d+'
        $scriptAst.Extent.Text | Should Match '\$WordCount -lt \$MinimumContentWords'
    }

    It 'handles a book without supported book file as a book without text' {
        $scriptAst.Extent.Text | Should Match 'handled as a book without text\." -f `\s+\$Book\.title[^\r\n]*\r?\n\s+\$ContentStatus = ''NoText'''
    }

    It 'uses the metadata hash as ContentHash of a book without text' {
        $scriptAst.Extent.Text | Should Match '\$ContentHash = Get-MetadataHash -Record \$BookRecord'
    }
}

Describe 'Export record' {
    $bookRecord = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$BookRecord'
        }, $true)
    $cacheRecord = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$CacheRecord'
        }, $true)

    It 'holds the Uuid, the description, the content status, the content hash, and the content profile fields' {
        foreach ($fieldName in @('Uuid', 'Description', 'ContentStatus', 'ContentHash', 'ContentProfile', 'ContentProfileVersion', 'ContentProfileSource', 'ContentProfileSources', 'BookContent')) {
            $bookRecord.Right.Extent.Text | Should Match ("(?m)^\s*{0}\s*=" -f $fieldName)
        }
    }

    It 'adds Uuid to the cache record only through the export record' {
        $cacheRecord.Right.Extent.Text | Should Not Match 'Uuid'
    }

    It 'looks up the content profile by content hash' {
        $scriptAst.Extent.Text | Should Match 'Get-CachedContentProfile -Path \$CachePath -ContentHash \$ContentHash'
    }

    It 'rewrites a reused cache file that has no ContentHash yet' {
        $scriptAst.Extent.Text | Should Match '\$CachedBook\.PSObject\.Properties\[''ContentHash''\]'
    }
}

Describe 'Export scope file' {
    $scope = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$Scope'
        }, $true)
    $bookLoop = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$Books'
        }, $true)

    It 'writes 01-Export-Scope.json, whose name does not match the book export files' {
        $scriptAst.Extent.Text | Should Match '-ChildPath "01-Export-Scope\.json"'
        '01-Export-Scope.json' -like '01-Export-CalibreBooks_*.json' | Should Be $false
    }

    It 'marks only an export of all books without debug export as full library' {
        $scope.Right.Extent.Text | Should Match 'FullLibrary\s*=\s*\(-not \$DebugBookExport -and \$ChangedWithinDays -eq 0\)'
    }

    It 'writes the scope file after all books were exported' {
        $scope.Extent.StartOffset -gt $bookLoop.Extent.EndOffset | Should Be $true
    }

    It 'removes the scope file of an older export before the new export' {
        $scriptAst.Extent.Text | Should Match 'Remove-Item -LiteralPath \$ScopePath -Force'
    }
}

Describe 'Incremental file writing' {
    $bookLoop = $scriptAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$Books'
        }, $true)
    # Write-BookCacheFile calls Write-JsonFile too, so only calls outside function definitions are counted; the scope file write (-Path $ScopePath) is not an export file.
    $writeCalls = @($scriptAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-JsonFile' -and $node.Extent.Text -notmatch '-Path \$ScopePath'
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