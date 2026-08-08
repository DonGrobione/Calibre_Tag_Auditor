<#
.SYNOPSIS
    Export Calibre Portable metadata to JSON files.

.DESCRIPTION
    Exports title, author, series, series index, and tags from a Calibre Portable
    library into one or more JSON files in the 01-Export directory.
    The output file names include a timestamp and sequence number when split.

.NOTES
    Version: 2.5
#>

try {
    $ErrorActionPreference = "Stop"

    $CalibrePaths = @(
        "E:\HiDrive\PortableApps\Calibre Portable"
        "D:\HiDrive\PortableApps\Calibre Portable"
    )

    $LibraryName = "Calibre Library"
    $BooksPerFile = 99

    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ExportDir = Join-Path $ScriptDir "01-Export"
    if (-not (Test-Path $ExportDir)) {
        New-Item -Path $ExportDir -ItemType Directory | Out-Null
    }

    Get-ChildItem -Path $ExportDir -Filter "01-Export-CalibreBooks_*.json" -File |
    Remove-Item -Force

    $CalibrePortablePath = $null
    foreach ($Path in $CalibrePaths) {
        if (Test-Path $Path) {
            $CalibrePortablePath = $Path
            break
        }
    }

    if (-not $CalibrePortablePath) {
        throw "Calibre Portable was not found. Checked paths:`n$($CalibrePaths -join "`n")"
    }

    $LibraryPath = Join-Path $CalibrePortablePath $LibraryName
    if (-not (Test-Path $LibraryPath)) {
        throw "Library path not found: '$LibraryPath'"
    }

    $CalibredbExe = Get-ChildItem -Path $CalibrePortablePath -Filter "calibredb.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $CalibredbExe) {
        throw "calibredb.exe was not found in '$CalibrePortablePath'."
    }

    Write-Host "Found:      $CalibrePortablePath"
    Write-Host "Tool:       $($CalibredbExe.FullName)"
    Write-Host "Library:    $LibraryPath"
    Write-Host "Output:     $ExportDir"

    $ExportDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    $JsonOutput = & $CalibredbExe.FullName list `
        --for-machine `
        --fields=title,authors,series,series_index,tags `
        "--with-library=$LibraryPath"

    if ($LASTEXITCODE -ne 0) {
        throw "calibredb failed (exit code: $LASTEXITCODE). Output: $($JsonOutput -join "`n")"
    }

    $JsonString = $JsonOutput -join "`n"
    $Books = $JsonString | ConvertFrom-Json

    if (-not $Books -or $Books.Count -eq 0) {
        Write-Warning "No books were found in the library."
        return
    }

    $TotalBooks = $Books.Count
    $NeedsSplitting = ($BooksPerFile -gt 0 -and $TotalBooks -gt $BooksPerFile)

    $Results = foreach ($Book in $Books) {
        [PSCustomObject]@{
            Title       = $Book.title
            Author      = $Book.authors
            Series      = $Book.series
            SeriesIndex = $Book.series_index
            Tags        = ($Book.tags -join ", ")
        }
    }

    if (-not $NeedsSplitting) {
        $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_01_$ExportDate.json"
        $Results | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFile -Encoding UTF8

        Write-Host ""
        Write-Host "Export complete:"
        Write-Host ("  Books: {0}" -f $Results.Count)
        Write-Host ("  File:  {0}" -f $JsonFile)
    } else {
        $FileCount = [Math]::Ceiling($TotalBooks / $BooksPerFile)
        $PadWidth = [Math]::Max(2, $FileCount.ToString().Length)
        $CurrentFile = 0
        $StartIndex = 0

        while ($StartIndex -lt $TotalBooks) {
            $CurrentFile++
            $EndIndex = [Math]::Min($StartIndex + $BooksPerFile, $TotalBooks) - 1
            $Batch = $Results[$StartIndex..$EndIndex]
            $Suffix = $CurrentFile.ToString("D$PadWidth")
            $JsonFile = Join-Path $ExportDir "01-Export-CalibreBooks_${Suffix}_$ExportDate.json"

            $Batch | ConvertTo-Json -Depth 10 | Set-Content -Path $JsonFile -Encoding UTF8

            Write-Host ("  File {0}/{1}: Books {2}-{3} ({4}) -> {5}" -f `
                $CurrentFile, $FileCount, ($StartIndex + 1), ($EndIndex + 1), $Batch.Count, $JsonFile)

            $StartIndex += $BooksPerFile
        }

        Write-Host ""
        Write-Host "Export complete:"
        Write-Host ("  Books:   {0}" -f $TotalBooks)
        Write-Host ("  Files:   {0}" -f $FileCount)
        Write-Host ("  Per file: max {0}" -f $BooksPerFile)
    }
} catch {
    Write-Error $_.Exception.Message
    throw
}
