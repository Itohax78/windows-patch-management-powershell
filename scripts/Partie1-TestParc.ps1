<#
.SYNOPSIS
    Partie 1 - Lit computers.txt et affiche, pour chaque poste, son nom, son adresse IP
    et son état de disponibilité (ping ICMP, port WinRM, Test-WSMan).
.EXAMPLE
    .\scripts\Partie1-TestParc.ps1
.EXAMPLE
    .\scripts\Partie1-TestParc.ps1 -ComputersFile .\computers.txt -ExportCsv
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $ComputersFile,
    [switch] $ExportCsv
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath -Override @{ ComputersFile = $ComputersFile }

Write-Host "`n=== Partie 1 : disponibilité des postes ($($PMConfig.ComputersFile)) ===`n" -ForegroundColor Cyan
# Lecture de computers.txt (lignes invalides et doublons signalés puis ignorés)
$computers = @(Read-PMComputerList)
# Pour chaque poste : ping ICMP, test du port WinRM puis Test-WSMan
$results = @(Test-PMComputer -Computer $computers -UseTestWSMan)

$results | Format-Table -AutoSize -Property @{ n = 'Poste'; e = { $_.Name } },
    @{ n = 'Adresse IP'; e = { $_.IPAddress } },
    @{ n = 'Ping'; e = { if ($_.Ping) { 'OK' } else { 'KO' } } },
    @{ n = 'WinRM'; e = { if ($_.IsLocal) { 'local' } elseif ($_.Accessible) { 'OK' } else { 'KO' } } },
    @{ n = 'État'; e = { $_.Status } },
    @{ n = 'Détail'; e = { $_.Detail } } | Out-Host

$ok = @($results | Where-Object Accessible).Count
Write-Host ("{0} poste(s) accessible(s) sur {1}" -f $ok, $results.Count) -ForegroundColor $(if ($ok -eq $results.Count) { 'Green' } else { 'Yellow' })
# Traçabilité : chaque test est inscrit dans PatchManager.log
foreach ($r in $results) { Write-PMLog $r.Name, $r.Status, $r.Detail }

if ($ExportCsv) {
    $path = Join-Path (New-PMRunFolder) 'Disponibilite.csv'
    Export-PMCsv -InputObject $results -Path $path -Delimiter $PMConfig.CsvDelimiter
    Write-Host "Export : $path"
}
