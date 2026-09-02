<#
.SYNOPSIS
    Writes messages with various log levels to a central log file.

.DESCRIPTION
    Writes messages with various log levels (INFO, WARN, ERROR)
    to a central log file in the 'Logs' directory in the project root.
    Also provides Write-HostAndLog, Write-WarningAndLog, and Write-ErrorAndLog,
    drop-in replacements for Write-Host/Write-Warning/Write-Error that mirror
    every message into the log file. Calling scripts alias the native cmdlets
    to these functions (see .EXAMPLE) so no per-script logging boilerplate is needed.
    The log entry is automatically prefixed with the name of the calling script file.

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

.EXAMPLE
    Import-Module -Name "Modules\Write-Log.psm1" -Force
    Set-Alias -Name Write-Host -Value Write-HostAndLog -Scope Script
    Set-Alias -Name Write-Warning -Value Write-WarningAndLog -Scope Script
    Set-Alias -Name Write-Error -Value Write-ErrorAndLog -Scope Script

.NOTES
    The log file is automatically created in the 'Logs' directory of the project root.
    The file name is based on the computer's hostname.

    Filename: Modules\Write-Log.psm1
    Version: 1.2.0
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

# Walk the call stack to find the first frame outside this module, i.e. the calling script file.
function Get-ScriptLogPrefix {
    $modulePath = $PSCommandPath
    foreach ($frame in (Get-PSCallStack)) {
        if ($frame.ScriptName -and $frame.ScriptName -ne $modulePath) {
            return "[$(Split-Path -Path $frame.ScriptName -Leaf)]"
        }
    }
    return '[UnknownScript]'
}

function Write-HostAndLog {
    # Drop-in replacement for Write-Host that also writes an INFO log entry.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor,
        [switch]$NoNewline,
        [object]$Separator
    )

    $joinSeparator = if ($PSBoundParameters.ContainsKey('Separator')) { [string]$Separator } else { ' ' }
    $message = (($Object | ForEach-Object { [string]$_ }) -join $joinSeparator)
    Write-Log -Message "$(Get-ScriptLogPrefix) $message" -Info
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
}

function Write-WarningAndLog {
    # Drop-in replacement for Write-Warning that also writes a WARN log entry.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$(Get-ScriptLogPrefix) $text" -Warn
    Microsoft.PowerShell.Utility\Write-Warning $text
}

function Write-ErrorAndLog {
    # Drop-in replacement for Write-Error that also writes an ERROR log entry.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object { [string]$_ }) -join ' '
    Write-Log -Message "$(Get-ScriptLogPrefix) $text" -IsError
    Microsoft.PowerShell.Utility\Write-Error $text
}

Export-ModuleMember -Function Write-Log, Write-HostAndLog, Write-WarningAndLog, Write-ErrorAndLog, Get-ScriptLogPrefix