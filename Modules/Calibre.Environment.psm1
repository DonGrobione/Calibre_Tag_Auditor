<#
.SYNOPSIS
    Resolves the configured Calibre installation and library environment.

.DESCRIPTION
    Loads and validates the shared Calibre configuration and resolves the
    installation, library, and database paths used by the export scripts.
    Calibre-specific export operations remain in the calling scripts.

.PARAMETER ConfigurationPath
    Path to the shared Calibre export configuration JSON file.

.PARAMETER Configuration
    Validated Calibre configuration object returned by Get-CalibreConfiguration.

.PARAMETER CalibrePath
    Root path of the selected Calibre installation.

.PARAMETER Name
    Executable file name to locate below the Calibre installation.

.NOTES
    Filename: Modules\Calibre.Environment.psm1
    Version: 1.1.0
#>

<#
.SYNOPSIS
    Loads and validates the shared Calibre export configuration.
.PARAMETER ConfigurationPath
    Path to the configuration JSON file.
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
    $booksPerFile = 0
    $changedWithinDays = 0
    $hasBooksPerFile = $null -ne $configuration.BooksPerFile -and
        [int]::TryParse([string]$configuration.BooksPerFile, [ref]$booksPerFile)
    $hasChangedWithinDays = $null -ne $configuration.ChangedWithinDays -and
        [int]::TryParse([string]$configuration.ChangedWithinDays, [ref]$changedWithinDays)

    if ($calibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($libraryName)) {
        throw "Calibre configuration '$ConfigurationPath' must define CalibrePaths and LibraryName."
    }

    if (-not $hasBooksPerFile -or $booksPerFile -lt 0 -or
        -not $hasChangedWithinDays -or $changedWithinDays -lt 0) {
        throw "Calibre configuration '$ConfigurationPath' must define BooksPerFile and ChangedWithinDays as values greater than or equal to zero."
    }

    [PSCustomObject]@{
        CalibrePaths      = $calibrePaths
        LibraryName       = $libraryName
        BooksPerFile      = $booksPerFile
        ChangedWithinDays = $changedWithinDays
        DebugBookExport   = ($configuration.DebugBookExport -eq $true)
    }
}

<#
.SYNOPSIS
    Resolves the selected Calibre installation and library paths.
.PARAMETER Configuration
    Validated configuration object from Get-CalibreConfiguration.
#>
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

<#
.SYNOPSIS
    Finds a named executable below the Calibre installation.
.PARAMETER CalibrePath
    Root path of the selected Calibre installation.
.PARAMETER Name
    Executable file name to locate.
#>
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