<#
.SYNOPSIS
    Resolves the configured Calibre installation and library environment.

.DESCRIPTION
    Loads and validates the shared Calibre configuration and resolves the
    installation, library, and database paths used by the export scripts.
    Calibre-specific export operations remain in the calling scripts.
#>

function Get-CalibreConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigurationPath
    )

    if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
        throw "Required configuration file not found: '$ConfigurationPath'"
    }

    try {
        $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Unable to read Calibre configuration '$ConfigurationPath': $($_.Exception.Message)"
    }

    $calibrePaths = @($configuration.CalibrePaths)
    $libraryName = [string]$configuration.LibraryName

    if ($calibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($libraryName)) {
        throw "Calibre configuration '$ConfigurationPath' must define CalibrePaths and LibraryName."
    }

    [PSCustomObject]@{
        CalibrePaths      = $calibrePaths
        LibraryName       = $libraryName
        BooksPerFile      = $configuration.BooksPerFile
        ChangedWithinDays = $configuration.ChangedWithinDays
        DebugBookExport   = ($configuration.DebugBookExport -eq $true)
    }
}

function Get-CalibreEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Configuration
    )

    $calibrePortablePath = $null
    foreach ($path in @($Configuration.CalibrePaths)) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            $calibrePortablePath = $path
            break
        }
    }

    if (-not $calibrePortablePath) {
        throw "Calibre Portable was not found. Checked paths:`n$(@($Configuration.CalibrePaths) -join "`n")"
    }

    $libraryPath = Join-Path -Path $calibrePortablePath -ChildPath $Configuration.LibraryName
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Container)) {
        throw "Library path not found: '$libraryPath'"
    }

    [PSCustomObject]@{
        PortablePath = $calibrePortablePath
        LibraryPath  = $libraryPath
        MetadataDbPath = Join-Path -Path $libraryPath -ChildPath 'metadata.db'
        NotesDbPath    = Join-Path -Path $libraryPath -ChildPath '.calnotes\notes.db'
    }
}

function Get-CalibreExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CalibrePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $executable = Get-ChildItem -LiteralPath $CalibrePath -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $executable) {
        throw "$Name was not found in '$CalibrePath'."
    }

    return $executable
}

Export-ModuleMember -Function Get-CalibreConfiguration, Get-CalibreEnvironment, Get-CalibreExecutable