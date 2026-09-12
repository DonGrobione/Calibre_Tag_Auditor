<#
.SYNOPSIS
    Cleans up old log files, keeping only the most recent ones.

.DESCRIPTION
    Log files are stored one per day (e.g. 2026-09-11.log) in the 'Logs' directory. This function keeps only the newest N log files (by date in the file name) and deletes the rest.

.PARAMETER KeepCount
    Number of most recent log files to keep. Default: 5.

.EXAMPLE
    Clear-LogFile -KeepCount 10

    Keeps the 10 most recent log files and deletes older ones.

.EXAMPLE
    Clear-LogFile

    Keeps the 5 most recent log files and deletes older ones.

.NOTES
    Filename: Modules\Clear-LogFile.psm1
    Version: 2.1.0
#>

# The module is stored in the Modules folder below the project root.
$logsDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Logs'

# Deletes all but the newest N log files from the Logs directory.
function Clear-LogFile {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [int]$KeepCount = 5
    )

    if (-not (Test-Path $logsDir)) {
        Write-Error "Logs directory not found: $logsDir"
        return
    }

    $logFiles = Get-ChildItem -Path $logsDir -Filter '*.log' -File |
        Sort-Object -Property Name -Descending

    if ($logFiles.Count -le $KeepCount) {
        Write-Output "No cleanup needed: $($logFiles.Count) log file(s) found, $KeepCount allowed."
        return
    }

    $filesToRemove = $logFiles | Select-Object -Skip $KeepCount
    foreach ($file in $filesToRemove) {
        Remove-Item -Path $file.FullName -Force
    }

    Write-Output "Logfile cleanup: kept the $KeepCount newest log file(s), removed $($filesToRemove.Count) older log file(s)."
}

Export-ModuleMember -Function Clear-LogFile
