#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prépare le POSTE D'ADMINISTRATION (client WinRM) pour PatchManager.

.DESCRIPTION
    1. démarre le service WinRM (nécessaire pour configurer le client) ;
    2. renseigne TrustedHosts avec les SEULES adresses de computers.txt (jamais "*") :
       en groupe de travail, Kerberos est impossible et le client doit savoir à quels
       hôtes il accepte d'envoyer ses identifiants NTLM ;
    3. durcit le client WinRM (pas de Basic, pas de trafic non chiffré) ;
    4. crée les dossiers Output, Logs et secrets avec des ACL restrictives ;
    5. teste Test-WSMan sur chaque poste.

    En domaine Active Directory, l'étape 2 est inutile : utiliser ConnectBy = 'Name'
    (Kerberos, authentification mutuelle).

.EXAMPLE
    .\Initialize-AdminStation.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ComputersFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'computers.txt'),
    [string] $Operator = "$env:USERDOMAIN\$env:USERNAME"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\PatchManager\PatchManager.psd1') -Force
Import-PMConfiguration -Override @{ ComputersFile = $ComputersFile } | Out-Null

Write-Host "`n>> Service WinRM (client)" -ForegroundColor Cyan
# Le service WinRM doit tourner pour pouvoir configurer le client
if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
Get-Service WinRM | Format-Table -AutoSize Name, Status, StartType | Out-Host

Write-Host '>> TrustedHosts' -ForegroundColor Cyan
$computers = @(Read-PMComputerList)
# TrustedHosts limité aux seuls postes du parc (jamais '*')
$trusted = ($computers.IPAddress + $computers.Name | Sort-Object -Unique) -join ','
if ($PSCmdlet.ShouldProcess('WSMan:\localhost\Client\TrustedHosts', $trusted)) {
    Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $trusted -Force
}
Write-Host "  TrustedHosts = $((Get-Item WSMan:\localhost\Client\TrustedHosts).Value)"

Write-Host '>> Durcissement du client WinRM' -ForegroundColor Cyan
# Refus des flux non chiffrés et de l'authentification Basic
Set-Item -Path WSMan:\localhost\Client\AllowUnencrypted -Value $false
Set-Item -Path WSMan:\localhost\Client\Auth\Basic -Value $false
Get-ChildItem WSMan:\localhost\Client\Auth | Format-Table -AutoSize Name, Value | Out-Host

Write-Host '>> Dossiers de travail protégés' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Protect-PMData.ps1') -Operator $Operator

Write-Host '>> Test-WSMan sur le parc' -ForegroundColor Cyan
# Vérification finale : chaque poste répond-il à WinRM ?
foreach ($c in $computers) {
    try {
        Test-WSMan -ComputerName $c.IPAddress -ErrorAction Stop | Out-Null
        Write-Host ("  {0,-10} {1,-16} WinRM OK" -f $c.Name, $c.IPAddress) -ForegroundColor Green
    } catch {
        Write-Host ("  {0,-10} {1,-16} WinRM KO : {2}" -f $c.Name, $c.IPAddress, $_.Exception.Message) -ForegroundColor Yellow
    }
}
