<#
.SYNOPSIS
    Partie 2 - Inventaire du parc : caractéristiques système de chaque poste collectées
    via PowerShell Remoting, export automatique en CSV.
.EXAMPLE
    .\scripts\Partie2-Inventaire.ps1 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

Write-PMLog 'Début de l''inventaire du parc'
# Collecte via PowerShell Remoting (les postes inaccessibles sont gardés avec leur erreur)
$hosts = @(Invoke-PMCollection -Computer @(Read-PMComputerList) -Credential $Credential)
# Transformation en objets PowerShell : une ligne par poste
$inventory = @(ConvertTo-PMInventory -HostResult $hosts)

Write-Host "`n=== Partie 2 : inventaire du parc ===`n" -ForegroundColor Cyan
$inventory | Format-Table -AutoSize -Wrap -Property Poste,
    @{ n = 'Adresse IP'; e = { $_.AdresseIP } },
    @{ n = 'Windows'; e = { if ($_.Windows) { $_.Windows } else { '—' } } },
    @{ n = 'Architecture'; e = { if ($_.Architecture) { $_.Architecture } else { '—' } } },
    @{ n = 'Dernier démarrage'; e = { if ($_.DernierDemarrage) { ([datetime]$_.DernierDemarrage).ToString('dd/MM/yyyy') } else { '—' } } },
    @{ n = 'Windows Update'; e = { if ($_.WindowsUpdate) { $_.WindowsUpdate } else { '—' } } },
    @{ n = 'État'; e = { $_.Etat } } | Out-Host

Write-Host 'Détail matériel :' -ForegroundColor Cyan
$inventory | Where-Object Etat -eq 'Accessible' | Format-Table -AutoSize -Property Poste, Modele, BIOS, RAM_Go,
    @{ n = 'Disque libre (Go)'; e = { "$($_.DisqueLibre_Go) / $($_.DisqueTotal_Go)" } },
    @{ n = 'Dernière MAJ'; e = { if ($_.DerniereMAJ) { ([datetime]$_.DerniereMAJ).ToString('dd/MM/yyyy') } else { '—' } } },
    @{ n = 'Nb MAJ'; e = { $_.NbMAJInstallees } } | Out-Host

# Erreurs enregistrées dans l'inventaire (poste injoignable, commande échouée...)
$errors = @($inventory | Where-Object Erreur)
if ($errors) {
    Write-Host 'Erreurs enregistrées dans l''inventaire :' -ForegroundColor Yellow
    $errors | Format-Table -AutoSize -Wrap Poste, Erreur | Out-Host
}

# Export automatique en CSV (séparateur ; pour Excel en français)
$path = Join-Path (New-PMRunFolder) 'Inventory.csv'
Export-PMCsv -InputObject $inventory -Path $path -Delimiter $PMConfig.CsvDelimiter
Write-PMLog "Inventaire exporté ($path)"
Write-Host "Inventaire exporté : $path" -ForegroundColor Green
