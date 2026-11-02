<#
.SYNOPSIS
    Pester tests for Modules\Calibre.Console.psd1.

.DESCRIPTION
    Verifies the module manifest, ConvertTo-DisplayPath, Format-Duration, and Write-ScriptLog. The tests use Pester v4-compatible syntax (Describe/Context/It with "Should Be") and run in Windows PowerShell 5.1 with Pester 3.4 or 4.x; Pester 5 does not support this syntax.
    Write-ScriptLog calls DonGrobione.Logging\Write-Log with a module-qualified name, so the tests load an in-memory stub module named DonGrobione.Logging that records every call instead of writing a log file. The stub is removed after the tests.

.EXAMPLE
    Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Tests\Calibre.Console.Tests.ps1
#>

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$manifestPath = Join-Path -Path $projectRoot -ChildPath 'Modules\Calibre.Console.psd1'

Get-Module -Name DonGrobione.Logging, Calibre.Console | Remove-Module -Force
$loggingStub = New-Module -Name DonGrobione.Logging -ScriptBlock {
    $script:Calls = New-Object -TypeName System.Collections.ArrayList

    # Records the bound parameters of each call instead of writing a log file.
    function Write-Log {
        param($Message, $Level, $ErrorRecord)
        $call = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            $call[$key] = $PSBoundParameters[$key]
        }
        [void]$script:Calls.Add($call)
    }

    # Returns the recorded Write-Log calls as an array.
    function Get-WriteLogCall {
        , $script:Calls.ToArray()
    }

    # Removes all recorded Write-Log calls.
    function Clear-WriteLogCall {
        $script:Calls.Clear()
    }

    Export-ModuleMember -Function Write-Log, Get-WriteLogCall, Clear-WriteLogCall
}
Import-Module -ModuleInfo $loggingStub -Force
Import-Module -Name $manifestPath -Force

Describe 'Calibre.Console manifest' {
    $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

    It 'is a valid manifest with a semantic version' {
        $manifest.Version.ToString() | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'names DonGrobione as the author' {
        $manifest.Author | Should Be 'DonGrobione'
    }

    It 'targets Windows PowerShell 5.1' {
        $manifest.PowerShellVersion.ToString() | Should Be '5.1'
    }

    It 'exports exactly the public functions' {
        (@($manifest.ExportedFunctions.Keys) | Sort-Object) -join ',' | Should Be 'ConvertTo-DisplayPath,Format-Duration,Write-ScriptLog'
    }

    It 'contains no wildcard exports' {
        $content = Get-Content -LiteralPath $manifestPath -Raw
        $content -match "ToExport\s*=\s*'\*'" | Should Be $false
    }

    It 'defines tags and release notes' {
        @($manifest.PrivateData.PSData.Tags).Count -gt 0 | Should Be $true
        [string]::IsNullOrWhiteSpace($manifest.PrivateData.PSData.ReleaseNotes) | Should Be $false
    }
}

Describe 'ConvertTo-DisplayPath' {
    $basePath = 'C:\CalibreTagAuditorTestRoot'

    Context 'paths that are returned unchanged' {
        It 'returns an empty string unchanged' {
            ConvertTo-DisplayPath -Path '' -BasePath $basePath | Should Be ''
        }

        It 'accepts $null and returns an empty string' {
            ConvertTo-DisplayPath -Path $null -BasePath $basePath | Should Be ''
        }

        It 'returns a relative path unchanged' {
            ConvertTo-DisplayPath -Path '01-Export\file.json' -BasePath $basePath | Should Be '01-Export\file.json'
        }
    }

    Context 'paths inside the base path' {
        It 'returns .\ for the base path itself' {
            ConvertTo-DisplayPath -Path $basePath -BasePath $basePath | Should Be '.\'
        }

        It 'returns a project-relative path for a child path' {
            ConvertTo-DisplayPath -Path "$basePath\01-Export\file.json" -BasePath $basePath | Should Be '.\01-Export\file.json'
        }

        It 'ignores a trailing backslash on the base path' {
            ConvertTo-DisplayPath -Path "$basePath\03-ODS" -BasePath "$basePath\" | Should Be '.\03-ODS'
        }

        It 'compares the base path case-insensitively' {
            ConvertTo-DisplayPath -Path 'c:\calibretagauditortestroot\Modules' -BasePath $basePath | Should Be '.\Modules'
        }
    }

    Context 'paths outside the base path' {
        It 'returns the absolute path for a sibling folder with the same prefix' {
            ConvertTo-DisplayPath -Path "${basePath}Other\file.txt" -BasePath $basePath | Should Be "${basePath}Other\file.txt"
        }

        It 'returns paths below $env:TEMP as absolute paths' {
            $tempFile = Join-Path -Path ([System.IO.Path]::GetFullPath($env:TEMP)) -ChildPath 'calibre.csv'
            ConvertTo-DisplayPath -Path $tempFile -BasePath $env:TEMP | Should Be $tempFile
        }
    }
}

Describe 'Format-Duration' {
    It 'formats a zero duration' {
        Format-Duration -Duration ([timespan]::Zero) | Should Be '00:00:00'
    }

    It 'formats a duration below one hour' {
        Format-Duration -Duration (New-TimeSpan -Seconds 5) | Should Be '00:00:05'
    }

    It 'formats a duration below one day' {
        Format-Duration -Duration (New-TimeSpan -Hours 7 -Minutes 23 -Seconds 48) | Should Be '07:23:48'
    }

    It 'counts days as hours for a duration over 24 hours' {
        $duration = [datetime]'2026-11-02 14:55:26' - [datetime]'2026-11-01 07:31:38'
        Format-Duration -Duration $duration | Should Be '31:23:48'
    }

    It 'formats durations of 100 hours or more' {
        Format-Duration -Duration (New-TimeSpan -Days 4 -Hours 4) | Should Be '100:00:00'
    }

    It 'truncates fractions of a second' {
        Format-Duration -Duration ([timespan]::FromMilliseconds(59999)) | Should Be '00:00:59'
    }

    It 'prefixes a negative duration with a minus sign' {
        Format-Duration -Duration (New-TimeSpan -Hours -25 -Minutes -1) | Should Be '-25:01:00'
    }
}

Describe 'Write-ScriptLog' {
    Context 'forwarding to DonGrobione.Logging\Write-Log' {
        It 'forwards the message without a level when no level is bound' {
            Clear-WriteLogCall
            $null = Write-ScriptLog 'Export complete.' 6>&1
            $calls = Get-WriteLogCall
            $calls.Count | Should Be 1
            $calls[0]['Message'] | Should Be 'Export complete.'
            $calls[0].ContainsKey('Level') | Should Be $false
        }

        It 'forwards level and error record unchanged' {
            Clear-WriteLogCall
            try {
                throw 'Simulated failure'
            }
            catch {
                $errorRecord = $_
            }
            $null = Write-ScriptLog -Level ERROR -Message 'Step failed.' -ErrorRecord $errorRecord 6>&1
            $calls = Get-WriteLogCall
            $calls[0]['Level'] | Should Be 'ERROR'
            $calls[0]['ErrorRecord'].Exception.Message | Should Be 'Simulated failure'
        }
    }

    Context 'terminal output on the information stream' {
        It 'writes INFO messages without a prefix' {
            $output = Write-ScriptLog 'Books/file: 10' 6>&1
            $output.MessageData | Should Be 'Books/file: 10'
        }

        It 'prefixes non-INFO messages with the level' {
            $output = Write-ScriptLog -Level WARN -Message 'Retrying.' 6>&1
            $output.MessageData | Should Be 'WARN: Retrying.'
        }
    }

    Context 'input validation' {
        It 'rejects an unknown level' {
            { Write-ScriptLog -Level VERBOSE -Message 'x' } | Should Throw
        }
    }
}

Remove-Module -Name Calibre.Console, DonGrobione.Logging -Force -ErrorAction SilentlyContinue
