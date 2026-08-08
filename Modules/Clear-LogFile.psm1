<#
.SYNOPSIS
    Cleans the log file by removing old entries.

.DESCRIPTION
    Cleans the log file by removing entries older than
    a configurable number of days (default: 30 days).

.PARAMETER Days
    Number of days to keep entries.
    Default: 30 days.

.EXAMPLE
    Clear-LogFile -Days 14

    Cleans the log file and removes all entries older than 14 days.

.EXAMPLE
    Clear-LogFile

    Cleans the log file and removes all entries older than 30 days.

.NOTES
    The log file is determined based on the computer's hostname.

    Filename: Modules\Clear-LogFile.psm1
    Version: 1.0.0
#>

# Folder for Logs
$logsDir = "Logs"

function Clear-LogFile {
    # Clears the log file by removing entries older than a specified number of days.
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [int]$Days = 30
    )

    $hostname = $env:COMPUTERNAME
    $logPath = [System.IO.Path]::Combine($logsDir, "$hostname.log")

    if (-not (Test-Path $logPath)) {
        Write-Error "Logfile not found: $logPath"
        return
    }

    $cutoff = (Get-Date).AddDays(-$Days)
    $lines = Get-Content $logPath

    $filtered = $lines | Where-Object {
        #Date is assumed to be at the beginning of the line in the format yyyy-MM-dd HH:mm:ss
        if ($_.Length -ge 19) {
            $dateStr = $_.Substring(0, 19)
            try {
                $date = [datetime]::ParseExact($dateStr, 'yyyy-MM-dd HH:mm:ss', $null)
                $date -ge $cutoff
            } catch {
                $true # Keep lines that do not match the date format (e.g., multi-line log entries)
            }
        } else {
            $true # Keep short lines (likely multi-line log entries)
        }
    }

    Set-Content -Path $logPath -Value $filtered
    Write-Output "Logfile cleaned: Entries older than $Days days have been removed."
}

Export-ModuleMember -Function Clear-LogFile