<#
.SYNOPSIS
    Detects changes of the Calibre tag definitions since the last full-library audit.

.DESCRIPTION
    Reads tag definition exports, keeps a baseline of the definitions that the whole library was last audited against, and compares the current definitions with that baseline. The calling scripts log the result; the module itself does not log.
    Tags are matched by name without regard to case, like Calibre does. Note texts are compared after collapsing whitespace, so pure whitespace edits are not reported as changes.
    Failures are raised as terminating errors with $PSCmdlet.ThrowTerminatingError(); each error record carries an error ID and category. Callers must invoke these functions inside try/catch (or with $ErrorActionPreference = 'Stop') so that a failure stops the calling script.

.PARAMETER Path
    Path of a tag definition export file or of the baseline file.

.PARAMETER Definitions
    Tag definitions as objects with the properties Tag and NoteText.

.PARAMETER Reference
    Tag definitions of the baseline.

.PARAMETER Difference
    Current tag definitions.

.PARAMETER Change
    Comparison result returned by Compare-TagDefinition.

.PARAMETER AuditedAt
    Date of the last full-library audit, shown in the warning text.

.NOTES
    Filename: Modules\Calibre.TagDefinitions.psm1
    The module version is maintained in Modules\Calibre.TagDefinitions.psd1.
#>

# Builds an error record from an exception, an error ID, and an error category for ThrowTerminatingError.
function Get-TagDefinitionErrorRecord {
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

# Converts parsed JSON items into Tag/NoteText objects and skips items without a tag name.
function ConvertTo-TagDefinitionObject {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Items
    )

    foreach ($item in @($Items)) {
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['Tag'] -or [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
            continue
        }

        $noteText = ''
        if ($null -ne $item.PSObject.Properties['NoteText'] -and $null -ne $item.NoteText) {
            $noteText = [string]$item.NoteText
        }

        [PSCustomObject]@{
            Tag      = [string]$item.Tag
            NoteText = $noteText
        }
    }
}

# Reads a tag definition export file (a JSON array of objects with Tag and NoteText) and returns the definitions; raises TagDefinitionFileNotFound or TagDefinitionFileUnreadable.
function Read-TagDefinitionFile {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $exception = New-Object -TypeName System.IO.FileNotFoundException -ArgumentList "Tag definition file not found: '$Path'"
        $PSCmdlet.ThrowTerminatingError((Get-TagDefinitionErrorRecord -Exception $exception -ErrorId 'TagDefinitionFileNotFound' -Category ObjectNotFound))
    }

    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
    }
    catch {
        $exception = New-Object -TypeName System.IO.InvalidDataException -ArgumentList "Unable to read tag definition file '$Path': $($_.Exception.Message)", $_.Exception
        $PSCmdlet.ThrowTerminatingError((Get-TagDefinitionErrorRecord -Exception $exception -ErrorId 'TagDefinitionFileUnreadable' -Category ReadError))
    }

    ConvertTo-TagDefinitionObject -Items @($parsed)
}

# Returns the baseline (AuditedAt and Definitions) from the given file, or $null when the file is missing, unreadable, or has no Definitions.
function Get-TagDefinitionBaseline {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)) -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['Definitions']) {
        return $null
    }

    $auditedAt = $null
    if ($null -ne $parsed.PSObject.Properties['AuditedAt']) {
        $auditedAt = [string]$parsed.AuditedAt
    }

    return [PSCustomObject]@{
        AuditedAt   = $auditedAt
        Definitions = @(ConvertTo-TagDefinitionObject -Items @($parsed.Definitions))
    }
}

# Writes the given definitions as the new baseline, with the current time as AuditedAt, to the given file as UTF-8 JSON without BOM; raises TagDefinitionBaselineNotWritten.
function Save-TagDefinitionBaseline {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Definitions
    )

    $baseline = [PSCustomObject]@{
        AuditedAt   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Definitions = @(ConvertTo-TagDefinitionObject -Items $Definitions)
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Save tag definition baseline')) {
        return
    }

    try {
        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
        [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $baseline -Depth 5), $utf8NoBom)
    }
    catch {
        $exception = New-Object -TypeName System.IO.IOException -ArgumentList "Unable to write tag definition baseline '$Path': $($_.Exception.Message)", $_.Exception
        $PSCmdlet.ThrowTerminatingError((Get-TagDefinitionErrorRecord -Exception $exception -ErrorId 'TagDefinitionBaselineNotWritten' -Category WriteError))
    }
}

# Returns a dictionary of tag name to normalized note text (whitespace collapsed and trimmed); tag names are compared without regard to case.
function ConvertTo-TagDefinitionMap {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Definitions
    )

    $map = New-Object -TypeName 'System.Collections.Generic.Dictionary[string, string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in (ConvertTo-TagDefinitionObject -Items $Definitions)) {
        $map[$definition.Tag.Trim()] = [regex]::Replace($definition.NoteText, '\s+', ' ').Trim()
    }

    return , $map
}

# Compares the current tag definitions with the baseline and returns the added, removed, and changed tag names (each sorted) and whether anything changed.
function Compare-TagDefinition {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Reference,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Difference
    )

    $referenceMap = ConvertTo-TagDefinitionMap -Definitions $Reference
    $differenceMap = ConvertTo-TagDefinitionMap -Definitions $Difference

    $added = @($differenceMap.Keys | Where-Object { -not $referenceMap.ContainsKey($_) } | Sort-Object)
    $removed = @($referenceMap.Keys | Where-Object { -not $differenceMap.ContainsKey($_) } | Sort-Object)
    $changed = @($differenceMap.Keys | Where-Object { $referenceMap.ContainsKey($_) -and $referenceMap[$_] -cne $differenceMap[$_] } | Sort-Object)

    return [PSCustomObject]@{
        Added      = $added
        Removed    = $removed
        Changed    = $changed
        HasChanges = ($added.Count + $removed.Count + $changed.Count) -gt 0
    }
}

# Returns the warning lines for a comparison result: the changed tags, the command to re-check all books, a hint for removed tags, and when the warning stops; returns nothing when nothing changed.
function Format-TagDefinitionChange {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSCustomObject]$Change,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AuditedAt
    )

    if (-not $Change.HasChanges) {
        return
    }

    $parts = @()
    if (@($Change.Added).Count -gt 0) { $parts += 'added: ' + (@($Change.Added) -join ', ') }
    if (@($Change.Changed).Count -gt 0) { $parts += 'changed: ' + (@($Change.Changed) -join ', ') }
    if (@($Change.Removed).Count -gt 0) { $parts += 'removed: ' + (@($Change.Removed) -join ', ') }

    $since = 'the last full audit'
    if (-not [string]::IsNullOrWhiteSpace($AuditedAt)) {
        $since = "the last full audit ($AuditedAt)"
    }

    "Tag definitions changed since $($since): $($parts -join '; ')."
    'Re-check all books: .\Invoke-CalibreToolsPipeline.ps1 -ChangedWithinDays 0. Add -FullContent when tags were added or their meaning changed, because the content profiles may lack the new concepts.'
    if (@($Change.Removed).Count -gt 0) {
        'Delete removed tags in Calibre too (Tag browser), otherwise books keep them as undefined tags.'
    }
    'This warning repeats until a run with -ChangedWithinDays 0 completes.'
}

Export-ModuleMember -Function Read-TagDefinitionFile, Get-TagDefinitionBaseline, Save-TagDefinitionBaseline, Compare-TagDefinition, Format-TagDefinitionChange
