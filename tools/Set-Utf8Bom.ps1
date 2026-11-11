<#
.SYNOPSIS
    Ré-encode les scripts PowerShell du projet en UTF-8 AVEC BOM.
.DESCRIPTION
    Windows PowerShell 5.1 lit un script sans BOM comme du Windows-1252 : les caractères
    accentués (messages, rapports) seraient corrompus. Le BOM garantit une lecture correcte
    par PowerShell 5.1 et 7.
#>
param([string] $Path = (Split-Path $PSScriptRoot -Parent))
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -Path $Path -Recurse -File -Include *.ps1, *.psm1, *.psd1, *.psrc, *.pssc |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
    ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $text = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
            Write-Host "BOM ajouté : $($_.FullName)"
        }
    }
