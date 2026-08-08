<#
.SYNOPSIS
    Provides logging functionality for Calibre Tools scripts.

.DESCRIPTION
    This module exports the Write-Log function which writes timestamped log messages
    to the console and optionally to a log file. Supports different log levels:
    INFO, WARNING, ERROR, DEBUG, VERBOSE.

.NOTES
    PowerShell Version: 5.1+
    Version: 1.0
    Author: Calibre Tools Project
#>

# Log levels enumeration
$script:LogLevels = @{
    DEBUG   = 0
    VERBOSE = 1
    INFO    = 2
    WARNING = 3
    ERROR   = 4
}

# Default log level - only messages at or above this level will be logged
$script:DefaultLogLevel = $script:LogLevels.INFO

# Optional log file path
$script:LogFilePath = $null

# Lock object for thread-safe file writing
$script:FileLock = New-Object System.Object

<#
.SYNOPSIS
    Writes a log message with specified level.

.DESCRIPTION
    Writes a timestamped log message to the console. If a log file path is configured,
    also writes to the file. Messages below the current log level are ignored.

.PARAMETER Message
    The log message to write.

.PARAMETER Level
    The log level: DEBUG, VERBOSE, INFO, WARNING, ERROR. Default is INFO.

.PARAMETER LogFile
    Optional path to a log file. If provided, writes to both console and file.

.PARAMETER NoNewline
    If specified, does not add a newline after the message.

.EXAMPLE
    Write-Log -Message "Processing started" -Level INFO

.EXAMPLE
    Write-Log -Message "Debug information" -Level DEBUG

.EXAMPLE
    Write-Log -Message "Error occurred" -Level ERROR -LogFile "C:\logs\script.log"
#>
function Write-Log {
    [CmdletBinding(DefaultParameterSetName = 'Console')]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet('DEBUG', 'VERBOSE', 'INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $false, ParameterSetName = 'File')]
        [string]$LogFile,

        [Parameter(Mandatory = $false)]
        [switch]$NoNewline
    )

    process {
        # Determine effective log level
        $currentLevel = $script:DefaultLogLevel
        $messageLevel = $script:LogLevels[$Level]

        # Check if message should be logged
        if ($messageLevel -ge $currentLevel) {
            # Format timestamp
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

            # Format the log line
            $logLine = "[$timestamp] [$Level] $Message"

            # Write to console with appropriate color
            $foregroundColor = $null
            switch ($Level) {
                'DEBUG'   { $foregroundColor = 'DarkGray' }
                'VERBOSE' { $foregroundColor = 'Gray' }
                'INFO'    { $foregroundColor = 'White' }
                'WARNING' { $foregroundColor = 'Yellow' }
                'ERROR'   { $foregroundColor = 'Red' }
            }

            if ($foregroundColor) {
                Write-Host $logLine -ForegroundColor $foregroundColor -NoNewline:$NoNewline
            } else {
                Write-Host $logLine -NoNewline:$NoNewline
            }

            # Write to file if specified or if module-level log file is configured
            $targetFile = $LogFile
            if ([string]::IsNullOrEmpty($targetFile)) {
                $targetFile = $script:LogFilePath
            }

            if (-not [string]::IsNullOrEmpty($targetFile)) {
                try {
                    # Ensure directory exists
                    $logDir = Split-Path -Path $targetFile -Parent
                    if (-not [string]::IsNullOrEmpty($logDir) -and -not (Test-Path -Path $logDir)) {
                        New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }

                    # Thread-safe file write
                    [System.Threading.Monitor]::Enter($script:FileLock)
                    try {
                        $logLine | Out-File -Path $targetFile -Append -Encoding UTF8 -NoNewline:$NoNewline
                    } finally {
                        [System.Threading.Monitor]::Exit($script:FileLock)
                    }
                } catch {
                    # Don't let logging failures break the main script
                    Write-Warning "Failed to write to log file '$targetFile': $_"
                }
            }

            if (-not $NoNewline) {
                # Add newline to console if not suppressed
                if ($foregroundColor) {
                    Write-Host "" -ForegroundColor $foregroundColor
                } else {
                    Write-Host ""
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Sets the default log level for the Write-Log function.

.DESCRIPTION
    Configures which log messages will be displayed/written based on their level.

.PARAMETER Level
    The minimum log level to display: DEBUG, VERBOSE, INFO, WARNING, ERROR.

.EXAMPLE
    Set-LogLevel -Level DEBUG

.EXAMPLE
    Set-LogLevel -Level WARNING
#>
function Set-LogLevel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('DEBUG', 'VERBOSE', 'INFO', 'WARNING', 'ERROR')]
        [string]$Level
    )

    $script:DefaultLogLevel = $script:LogLevels[$Level]
    Write-Log -Message "Log level set to $Level" -Level INFO
}

<#
.SYNOPSIS
    Sets the default log file path for the Write-Log function.

.DESCRIPTION
    Configures a default log file where all log messages will be written.

.PARAMETER Path
    The path to the log file.

.EXAMPLE
    Set-LogFile -Path "C:\logs\myscript.log"
#>
function Set-LogFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    $script:LogFilePath = $Path
    Write-Log -Message "Log file set to $Path" -Level INFO
}

# Export the public functions
Export-ModuleMember -Function Write-Log, Set-LogLevel, Set-LogFile
