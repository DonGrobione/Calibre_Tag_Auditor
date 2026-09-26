<#
.SYNOPSIS
    Pester tests for Modules\Calibre.Environment.psd1.

.DESCRIPTION
    Verifies the module manifest, Get-CalibreConfiguration, Get-CalibreEnvironment, and Get-CalibreExecutable, including the error IDs raised with $PSCmdlet.ThrowTerminatingError(). The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.
    All files and folders are created in the Pester TestDrive; no real Calibre installation is required.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Tests\Calibre.Environment.Tests.ps1
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$manifestPath = Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Environment.psd1'

Get-Module -Name Calibre.Environment | Remove-Module -Force
Import-Module -Name $manifestPath -Force

Describe 'Calibre.Environment manifest' {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    It 'is a valid manifest with a semantic version' {
        $manifest.Version.ToString() | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'names DonGrobione as the author' {
        $manifest.Author | Should Be 'DonGrobione'
    }

    It 'targets Windows PowerShell 5.1' {
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
    }

    It 'exports exactly the public functions' {
        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should Be 'Get-CalibreConfiguration,Get-CalibreEnvironment,Get-CalibreExecutable'
    }

    It 'keeps the error record helper private' {
        Get-Command -Name Get-CalibreErrorRecord -ErrorAction SilentlyContinue | Should Be $null
    }

    It 'contains no wildcard exports' {
        $content = Get-Content -LiteralPath $manifestPath -Raw
        $content -match "ToExport\s*=\s*'\*'" | Should Be $false
    }

    It 'defines tags and release notes' {
        @($manifest.PrivateData.PSData.Tags).Count -gt 0 | Should Be $true
        [string]::IsNullOrWhiteSpace($manifest.PrivateData.PSData.ReleaseNotes) | Should Be $false
    }
}

Describe 'Get-CalibreConfiguration' {
    $configPath = Join-Path -Path $TestDrive -ChildPath 'config.json'

    Context 'valid configuration' {
        It 'returns the configured values' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A", "D:\\B"], "LibraryName": "Calibre Library", "BooksPerFile": 10, "ChangedWithinDays": 1 }'
            $configuration = Get-CalibreConfiguration -ConfigurationPath $configPath
            $configuration.CalibrePaths -join '|' | Should Be 'C:\A|D:\B'
            $configuration.LibraryName | Should Be 'Calibre Library'
            $configuration.BooksPerFile | Should Be 10
            $configuration.ChangedWithinDays | Should Be 1
        }

        It 'defaults DebugBookExport to false' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "LibraryName": "Lib", "BooksPerFile": 0, "ChangedWithinDays": 0 }'
            (Get-CalibreConfiguration -ConfigurationPath $configPath).DebugBookExport | Should Be $false
        }

        It 'reads DebugBookExport when it is true' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "LibraryName": "Lib", "BooksPerFile": 0, "ChangedWithinDays": 0, "DebugBookExport": true }'
            (Get-CalibreConfiguration -ConfigurationPath $configPath).DebugBookExport | Should Be $true
        }

        It 'accepts numbers given as strings' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "LibraryName": "Lib", "BooksPerFile": "5", "ChangedWithinDays": "2" }'
            $configuration = Get-CalibreConfiguration -ConfigurationPath $configPath
            $configuration.BooksPerFile | Should Be 5
            $configuration.ChangedWithinDays | Should Be 2
        }
    }

    Context 'invalid configuration' {
        It 'raises CalibreConfigurationNotFound for a missing file' {
            $missingPath = Join-Path -Path $TestDrive -ChildPath 'missing.json'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $missingPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationNotFound,Get-CalibreConfiguration'
            $caught.Exception.Message | Should Be "Required configuration file not found: '$missingPath'"
        }

        It 'raises CalibreConfigurationUnreadable for invalid JSON' {
            Set-Content -LiteralPath $configPath -Value '{ not json'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationUnreadable,Get-CalibreConfiguration'
            $caught.Exception.Message | Should Match '^Unable to read Calibre configuration'
        }

        It 'raises CalibreConfigurationIncomplete when LibraryName is missing' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "BooksPerFile": 1, "ChangedWithinDays": 1 }'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationIncomplete,Get-CalibreConfiguration'
        }

        It 'raises CalibreConfigurationIncomplete when CalibrePaths is missing' {
            Set-Content -LiteralPath $configPath -Value '{ "LibraryName": "Lib", "BooksPerFile": 1, "ChangedWithinDays": 1 }'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationIncomplete,Get-CalibreConfiguration'
        }

        It 'raises CalibreConfigurationIncomplete when CalibrePaths contains only empty values' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["", " "], "LibraryName": "Lib", "BooksPerFile": 1, "ChangedWithinDays": 1 }'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationIncomplete,Get-CalibreConfiguration'
        }

        It 'removes empty values from CalibrePaths' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["", "C:\\A"], "LibraryName": "Lib", "BooksPerFile": 1, "ChangedWithinDays": 1 }'
            (Get-CalibreConfiguration -ConfigurationPath $configPath).CalibrePaths -join '|' | Should Be 'C:\A'
        }

        It 'raises CalibreConfigurationInvalidValue for a negative BooksPerFile' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "LibraryName": "Lib", "BooksPerFile": -1, "ChangedWithinDays": 1 }'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationInvalidValue,Get-CalibreConfiguration'
        }

        It 'raises CalibreConfigurationInvalidValue for a non-numeric ChangedWithinDays' {
            Set-Content -LiteralPath $configPath -Value '{ "CalibrePaths": ["C:\\A"], "LibraryName": "Lib", "BooksPerFile": 1, "ChangedWithinDays": "often" }'
            $caught = $null
            try { Get-CalibreConfiguration -ConfigurationPath $configPath } catch { $caught = $_ }
            $caught.FullyQualifiedErrorId | Should Be 'CalibreConfigurationInvalidValue,Get-CalibreConfiguration'
        }

        It 'rejects an empty path' {
            { Get-CalibreConfiguration -ConfigurationPath '' } | Should Throw
        }
    }
}

Describe 'Get-CalibreEnvironment' {
    $installationPath = Join-Path -Path $TestDrive -ChildPath 'Calibre Portable'
    $libraryPath = Join-Path -Path $installationPath -ChildPath 'Calibre Library'
    $missingPath = Join-Path -Path $TestDrive -ChildPath 'Missing'
    New-Item -Path $libraryPath -ItemType Directory -Force | Out-Null

    It 'selects the first existing installation path and resolves the database paths' {
        $configuration = [PSCustomObject]@{ CalibrePaths = @($missingPath, $installationPath); LibraryName = 'Calibre Library' }
        $environment = Get-CalibreEnvironment -Configuration $configuration
        $environment.PortablePath | Should Be $installationPath
        $environment.LibraryPath | Should Be $libraryPath
        $environment.MetadataDbPath | Should Be (Join-Path -Path $libraryPath -ChildPath 'metadata.db')
        $environment.NotesDbPath | Should Be (Join-Path -Path $libraryPath -ChildPath '.calnotes\notes.db')
    }

    It 'skips empty installation paths' {
        $configuration = [PSCustomObject]@{ CalibrePaths = @('', $installationPath); LibraryName = 'Calibre Library' }
        (Get-CalibreEnvironment -Configuration $configuration).PortablePath | Should Be $installationPath
    }

    It 'raises CalibreInstallationNotFound when no installation path exists' {
        $configuration = [PSCustomObject]@{ CalibrePaths = @($missingPath); LibraryName = 'Calibre Library' }
        $caught = $null
        try { Get-CalibreEnvironment -Configuration $configuration } catch { $caught = $_ }
        $caught.FullyQualifiedErrorId | Should Be 'CalibreInstallationNotFound,Get-CalibreEnvironment'
        $caught.Exception.Message | Should Match 'Calibre Portable was not found'
    }

    It 'raises CalibreLibraryNotFound when the library folder is missing' {
        $configuration = [PSCustomObject]@{ CalibrePaths = @($installationPath); LibraryName = 'Other Library' }
        $caught = $null
        try { Get-CalibreEnvironment -Configuration $configuration } catch { $caught = $_ }
        $caught.FullyQualifiedErrorId | Should Be 'CalibreLibraryNotFound,Get-CalibreEnvironment'
    }

    It 'rejects a null configuration' {
        { Get-CalibreEnvironment -Configuration $null } | Should Throw
    }
}

Describe 'Get-CalibreExecutable' {
    $installationPath = Join-Path -Path $TestDrive -ChildPath 'Calibre Portable'
    $executableFolder = Join-Path -Path $installationPath -ChildPath 'Calibre'
    New-Item -Path $executableFolder -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $executableFolder -ChildPath 'calibredb.exe') -Value ''

    It 'finds an executable in a subfolder of the installation' {
        $executable = Get-CalibreExecutable -CalibrePath $installationPath -Name 'calibredb.exe'
        $executable -is [System.IO.FileInfo] | Should Be $true
        $executable.FullName | Should Be (Join-Path -Path $executableFolder -ChildPath 'calibredb.exe')
    }

    It 'raises CalibreExecutableNotFound for a missing executable' {
        $caught = $null
        try { Get-CalibreExecutable -CalibrePath $installationPath -Name 'ebook-convert.exe' } catch { $caught = $_ }
        $caught.FullyQualifiedErrorId | Should Be 'CalibreExecutableNotFound,Get-CalibreExecutable'
        $caught.Exception.Message | Should Be "ebook-convert.exe was not found in '$installationPath'."
    }
}

Remove-Module -Name Calibre.Environment -Force -ErrorAction SilentlyContinue
