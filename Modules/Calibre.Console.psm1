<#
.SYNOPSIS
    Console and log output helpers for the Calibre Tag Auditor scripts.

.DESCRIPTION
    Write-ScriptLog forwards every message unchanged to DonGrobione.Logging\Write-Log and also writes it to the information stream so it stays visible in the terminal. Non-INFO messages are shown in the terminal with a level prefix (for example "WARN: ..."). Like Write-Log, it never terminates the calling script. ConvertTo-DisplayPath converts absolute paths into readable project-relative paths for output; paths under $env:TEMP and outside BasePath stay absolute.
    The calling script imports DonGrobione.Logging (>= 1.2.0) and starts the log session; this module neither imports the logging module nor starts a session.

.PARAMETER Message
    Write-ScriptLog: the message to write.

.PARAMETER Level
    Write-ScriptLog: log level DEBUG, INFO, WARN, ERROR, or FATAL. Default: INFO.

.PARAMETER ErrorRecord
    Write-ScriptLog: optional error record whose exception message and script stack trace are written to the log file.

.PARAMETER Path
    ConvertTo-DisplayPath: path to convert into a display path.

.PARAMETER BasePath
    ConvertTo-DisplayPath: base path that project-relative display paths are calculated from.

.EXAMPLE
    Write-ScriptLog "Export complete."

.EXAMPLE
    Write-ScriptLog -Level ERROR -Message $_.Exception.Message -ErrorRecord $_

.EXAMPLE
    ConvertTo-DisplayPath -Path $ExportDir -BasePath $PSScriptRoot

.NOTES
    Filename: Modules\Calibre.Console.psm1
    The module version is maintained in Modules\Calibre.Console.psd1.
#>

# Writes a message to the DonGrobione.Logging log file and to the information stream.
function Write-ScriptLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level = 'INFO',

        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    DonGrobione.Logging\Write-Log @PSBoundParameters

    $consoleMessage = $Message
    if ($Level -ne 'INFO') {
        $consoleMessage = "${Level}: $Message"
    }
    Write-Information -MessageData $consoleMessage -InformationAction Continue
}

# Converts an absolute path to a readable project-relative path, excluding temporary directory paths.
function ConvertTo-DisplayPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,
        [string]$BasePath = $PSScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    try {
        $normalizedBase = $BasePath
        if ([string]::IsNullOrWhiteSpace($normalizedBase)) {
            $normalizedBase = (Get-Location).Path
        }

        $resolvedPath = $Path
        if ([System.IO.Path]::IsPathRooted($resolvedPath)) {
            $resolvedPath = [System.IO.Path]::GetFullPath($resolvedPath)
        }
        else {
            return $Path
        }

        if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
            $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
            if ($resolvedPath.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                $resolvedPath.Equals($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $resolvedPath
            }
        }

        $baseFullPath = [System.IO.Path]::GetFullPath($normalizedBase).TrimEnd('\')

        if ($resolvedPath.Equals($baseFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return '.\'
        }

        if ($resolvedPath.StartsWith($baseFullPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $resolvedPath.Substring($baseFullPath.Length + 1)
            return '.\' + $relativePath
        }

        return $resolvedPath
    }
    catch {
        return $Path
    }
}

Export-ModuleMember -Function Write-ScriptLog, ConvertTo-DisplayPath
