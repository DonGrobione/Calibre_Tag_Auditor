<#
.SYNOPSIS
    Konvertiert alle JSON-Dateien im Ergebnis-Verzeichnis (ohne Unterverzeichnisse) nach CSV.
.DESCRIPTION
    Liest jede JSON-Datei im Ordner 'Ergebnis' und speichert sie im selben Verzeichnis
    als CSV mit identischem Basisnamen.
.NOTES
    PowerShell 5.1+
#>

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ResultDir  = Join-Path -Path $ScriptDir -ChildPath "Ergebnis"

if (-not (Test-Path -Path $ResultDir)) {
    Write-Error "Fehler: Verzeichnis '$ResultDir' existiert nicht."
    exit 1
}

$files = Get-ChildItem -Path $ResultDir -Filter "*.json" -File | Sort-Object Name
if ($files.Count -eq 0) {
    Write-Host "Keine JSON-Dateien im Ordner '$ResultDir' gefunden."
    exit 0
}

foreach ($file in $files) {
    Write-Host "Konvertiere: $($file.Name)" -ForegroundColor Cyan
    try {
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        $json = ConvertFrom-Json -InputObject $content
    }
    catch {
        $raw = $content.Trim()
        $start = $raw.IndexOf('[')
        $end = $raw.LastIndexOf(']')
        if ($start -ge 0 -and $end -gt $start) {
            $jsonText = $raw.Substring($start, $end - $start + 1)
            try {
                $json = ConvertFrom-Json -InputObject $jsonText
            }
            catch {
                Write-Error "Fehler beim Parsen von '$($file.Name)' (nach der Extraktion des JSON-Teils): $_"
                continue
            }
        }
        else {
            Write-Error "Fehler beim Lesen oder Parsen von '$($file.Name)': $_"
            continue
        }
    }

    if ($null -eq $json) {
        Write-Error "Datei '$($file.Name)' enthält kein JSON."
        continue
    }

    if ($json -is [System.Collections.IEnumerable] -and -not ($json -is [string])) {
        $items = @($json)
    }
    else {
        $items = @($json)
    }

    $rows = @()
    $columns = [System.Collections.ArrayList]@()

    foreach ($item in $items) {
        if ($item -is [System.Management.Automation.PSObject]) {
            foreach ($prop in $item.PSObject.Properties.Name) {
                if (-not $columns.Contains($prop)) {
                    $columns.Add($prop) | Out-Null
                }
            }
        }
        else {
            Write-Error "Objekt in '$($file.Name)' konnte nicht in ein PSObject konvertiert werden."
        }
    }

    if ($columns.Count -eq 0) {
        Write-Error "Keine Spalten in '$($file.Name)' gefunden."
        continue
    }

    foreach ($item in $items) {
        $obj = [ordered]@{}
        foreach ($col in $columns) {
            $value = $null
            if ($item.PSObject.Properties.Match($col).Count -gt 0) {
                $value = $item.$col
            }
            $obj[$col] = $value
        }
        $rows += New-Object PSObject -Property $obj
    }

    $csvPath = [System.IO.Path]::ChangeExtension($file.FullName, ".csv")
    try {
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ";"
        Write-Host "  -> gespeichert als: $([System.IO.Path]::GetFileName($csvPath))" -ForegroundColor Green
    }
    catch {
        Write-Error "Fehler beim Schreiben von '$($csvPath)': $_"
    }
}

Write-Host "Konvertierung abgeschlossen." -ForegroundColor Cyan
