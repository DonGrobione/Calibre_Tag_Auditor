<#
.SYNOPSIS
    Resolves the configured Calibre installation and library environment.

.DESCRIPTION
    Loads and validates the shared Calibre configuration and resolves the installation, library, and database paths used by the export scripts. Calibre-specific export operations remain in the calling scripts.
    Failures are raised as terminating errors with $PSCmdlet.ThrowTerminatingError(); each error record carries an error ID and category. Callers must invoke these functions inside try/catch (or with $ErrorActionPreference = 'Stop') so that a failure stops the calling script.

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
    The module version is maintained in Modules\Calibre.Environment.psd1.
#>

# Builds an error record from an exception, an error ID, and an error category for ThrowTerminatingError.
function Get-CalibreErrorRecord {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Exception]$Exception,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ErrorId,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorCategory]$Category
    )

    return New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList $Exception, $ErrorId, $Category, $null
}

# Loads and validates the shared Calibre export configuration JSON file from the given path.
function Get-CalibreConfiguration {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ConfigurationPath
    )

    if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
        $exception = New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Required configuration file not found: '$ConfigurationPath'"
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreConfigurationNotFound' -Category ObjectNotFound))
    }

    try {
        # Read as UTF-8 (with or without BOM); Windows PowerShell 5.1 would otherwise read a file without BOM in the ANSI code page and garble non-ASCII paths.
        $configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $exception = New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Unable to read Calibre configuration '$ConfigurationPath': $($_.Exception.Message)", $_.Exception
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreConfigurationUnreadable' -Category ReadError))
    }

    $calibrePaths = @($configuration.CalibrePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $libraryName = [string]$configuration.LibraryName
    $booksPerFile = 0
    $changedWithinDays = 0
    $hasBooksPerFile = $null -ne $configuration.BooksPerFile -and
        [int]::TryParse([string]$configuration.BooksPerFile, [ref]$booksPerFile)
    $hasChangedWithinDays = $null -ne $configuration.ChangedWithinDays -and
        [int]::TryParse([string]$configuration.ChangedWithinDays, [ref]$changedWithinDays)

    if ($calibrePaths.Count -eq 0 -or [string]::IsNullOrWhiteSpace($libraryName)) {
        $exception = New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Calibre configuration '$ConfigurationPath' must define CalibrePaths and LibraryName."
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreConfigurationIncomplete' -Category InvalidData))
    }

    if (-not $hasBooksPerFile -or $booksPerFile -lt 0 -or
        -not $hasChangedWithinDays -or $changedWithinDays -lt 0) {
        $exception = New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Calibre configuration '$ConfigurationPath' must define BooksPerFile and ChangedWithinDays as values greater than or equal to zero."
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreConfigurationInvalidValue' -Category InvalidData))
    }

    [PSCustomObject]@{
        CalibrePaths      = $calibrePaths
        LibraryName       = $libraryName
        BooksPerFile      = $booksPerFile
        ChangedWithinDays = $changedWithinDays
        DebugBookExport   = ($configuration.DebugBookExport -eq $true)
    }
}

# Resolves the selected Calibre installation, library path, and SQLite database paths from a configuration object.
function Get-CalibreEnvironment {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Configuration
    )

    $calibrePortablePath = $null
    foreach ($path in @($Configuration.CalibrePaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Container)) {
            $calibrePortablePath = $path
            break
        }
    }

    if (-not $calibrePortablePath) {
        $exception = New-Object -TypeName System.IO.DirectoryNotFoundException -ArgumentList "Calibre Portable was not found. Checked paths:`n$(@($Configuration.CalibrePaths) -join "`n")"
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreInstallationNotFound' -Category ObjectNotFound))
    }

    $libraryPath = Join-Path -Path $calibrePortablePath -ChildPath $Configuration.LibraryName
    if (-not (Test-Path -LiteralPath $libraryPath -PathType Container)) {
        $exception = New-Object -TypeName System.IO.DirectoryNotFoundException -ArgumentList "Library path not found: '$libraryPath'"
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreLibraryNotFound' -Category ObjectNotFound))
    }

    [PSCustomObject]@{
        PortablePath   = $calibrePortablePath
        LibraryPath    = $libraryPath
        MetadataDbPath = Join-Path -Path $libraryPath -ChildPath 'metadata.db'
        NotesDbPath    = Join-Path -Path $libraryPath -ChildPath '.calnotes\notes.db'
    }
}

# Finds a named executable file (such as calibredb.exe or calibre-debug.exe) within the Calibre installation path.
function Get-CalibreExecutable {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
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
        $exception = New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "$Name was not found in '$CalibrePath'."
        $PSCmdlet.ThrowTerminatingError((Get-CalibreErrorRecord -Exception $exception -ErrorId 'CalibreExecutableNotFound' -Category ObjectNotFound))
    }

    return $executable
}

Export-ModuleMember -Function Get-CalibreConfiguration, Get-CalibreEnvironment, Get-CalibreExecutable
