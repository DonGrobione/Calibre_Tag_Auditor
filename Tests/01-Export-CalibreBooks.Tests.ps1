<#
.SYNOPSIS
    Pester tests for the book file functions in 01-Export-CalibreBooks.ps1.

.DESCRIPTION
    Covers Get-BookFile, Get-PrimaryBookFile, and ConvertTo-FormatDisplayText. The script runs its whole workflow when it is executed, so the tests parse it and load only the function definitions under test. The book directories are created under $TestDrive; Calibre is not started.
    The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path '.\Tests\01-Export-CalibreBooks.Tests.ps1'
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$scriptPath = Join-Path -Path $projectRoot -ChildPath '01-Export-CalibreBooks.ps1'
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
$functionNames = @('Get-BookFile', 'Get-PrimaryBookFile', 'ConvertTo-FormatDisplayText')
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
}

Describe 'Get-BookFile' {
    It 'returns all files of the book directory' {
        $directory = Add-TestBookDirectory -Name 'Book (1)' -FileNames @('book.epub', 'cover.jpg', 'metadata.opf')
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 1 }) -BookDirectories @{ '1' = $directory })
        $files.Count | Should Be 3
    }

    It 'returns an empty array when the book has no directory' {
        $files = @(Get-BookFile -Book ([PSCustomObject]@{ id = 2 }) -BookDirectories @{})
        $files.Count | Should Be 0
    }

    It 'returns an empty array when the book has no id' {
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
