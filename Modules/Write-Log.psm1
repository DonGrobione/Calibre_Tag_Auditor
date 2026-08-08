<#
.SYNOPSIS
    Writes messages with various log levels to a central log file.

.DESCRIPTION
    Writes messages with various log levels (INFO, WARN, ERROR)
    to a central log file in the 'Logs' directory in the project root.

.PARAMETER Message
    The message to be logged.

.PARAMETER Info
    Writes an INFO entry.

.PARAMETER Warn
    Writes a WARN entry.

.PARAMETER IsError
    Writes an ERROR entry.

.EXAMPLE
    Write-Log "Script started"
    Write-Log -Info "Script stopped"

.EXAMPLE
    Write-Log -Warn "Warning: Configuration missing"

.EXAMPLE
    Write-Log -IsError "Error: Connection failed"

.NOTES
    The log file is automatically created in the 'Logs' directory of the project root.
    The file name is based on the computer's hostname.

    Filename: Modules\Write-Log.psm1
    Version: 1.1.4
#>

# The log file is created in the 'Logs' directory in the project root.
$logsDir = ".\Logs"

function Write-Log {
    # Writes a log entry to the log file with a timestamp and log level.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,
        [switch]$Info,
        [switch]$Warn,
        [switch]$IsError
    )

    $hostname = $env:COMPUTERNAME

    # Determine log level
    $logLevel = "INFO"
    if ($Warn) { $logLevel = "WARN" }
    if ($IsError) { $logLevel = "ERROR" }

    # Create logs directory if it doesn't exist
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    # Use simplified log file name with only hostname
    $logPath = [System.IO.Path]::Combine($logsDir, "$hostname.log")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$logLevel] $Message"

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $fileStream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $writer = New-Object System.IO.StreamWriter($fileStream)
            $writer.WriteLine($entry)
            $writer.Flush()
            $writer.Close()
            $fileStream.Close()
            break
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $maxAttempts) {
                throw
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

Export-ModuleMember -Function Write-Log