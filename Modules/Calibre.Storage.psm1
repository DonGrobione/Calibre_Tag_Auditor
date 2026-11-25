<#
.SYNOPSIS
    File helpers for the result and state files of the Calibre Tag Auditor scripts.

.DESCRIPTION
    Save-AtomicTextFile writes a text file through a temporary file that then replaces the target, so an interruption never leaves a truncated file. Test-ResultFileComplete tells whether an LLM result file is complete, so a resumed run can skip its export file. Get-ExportTimestamp reads the run timestamp from the name of an export or result file.
    The module neither logs nor reads configuration; errors are returned to the calling script as exceptions.

.PARAMETER Path
    Save-AtomicTextFile, Test-ResultFileComplete: path of the file.

.PARAMETER Content
    Save-AtomicTextFile: text to write.

.PARAMETER FileName
    Get-ExportTimestamp: file name that ends with _yyyy-MM-dd_HH-mm-ss.json.

.NOTES
    Filename: Modules\Calibre.Storage.psm1
    The module version is maintained in Modules\Calibre.Storage.psd1.
#>

# Writes the text as UTF-8 without BOM to <name>.tmp first, which then replaces the target file (or is renamed to it), so an interruption leaves either the complete previous file or an orphaned .tmp file, never a truncated file.
function Save-AtomicTextFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) {
        return
    }

    $temporaryPath = [System.IO.Path]::ChangeExtension($Path, '.tmp')
    [System.IO.File]::WriteAllText($temporaryPath, $Content, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # [NullString]::Value passes a real null for the backup file; PowerShell would turn $null into an empty, invalid path.
        [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($temporaryPath, $Path)
    }
}

# Returns $true when a result file exists, is valid JSON, and has a status other than error, so a resumed run can skip its export file. Files with status error (e.g. a failed request) are processed again.
function Test-ResultFileComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $result = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $false
    }

    return ($null -ne $result -and $null -ne $result.PSObject.Properties['status'] -and -not [string]::IsNullOrWhiteSpace([string]$result.status) -and [string]$result.status -ne 'error')
}

# Returns the run timestamp (yyyy-MM-dd_HH-mm-ss) at the end of an export or result file name such as 01-Export-CalibreBooks_01_2026-11-25_10-42-34.json, or $null when the name has none.
function Get-ExportTimestamp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$FileName
    )

    if ($FileName -match '_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.json\z') {
        return $Matches[1]
    }

    return $null
}

Export-ModuleMember -Function Save-AtomicTextFile, Test-ResultFileComplete, Get-ExportTimestamp
