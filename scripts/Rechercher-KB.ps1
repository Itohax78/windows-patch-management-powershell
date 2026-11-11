<#
.SYNOPSIS
    Recherche un correctif de sécurité identifié par son numéro KB sur tout le parc.
.EXAMPLE
    .\scripts\Rechercher-KB.ps1 -KB KB5034441 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^(?i)KB\d{6,8}$')] [string] $KB,
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

$hosts = @(Invoke-PMCollection -Computer @(Read-PMComputerList) -Credential $Credential)
# Recherche du KB dans les correctifs collectés de chaque poste
$result = @(Find-PMPatch -HostResult $hosts -KB $KB)
Write-Host "`n=== Recherche de $($KB.ToUpper()) sur le parc ===`n" -ForegroundColor Cyan
$result | Format-Table -AutoSize Poste, AdresseIP, Resultat,
    @{ n = 'Date d''installation'; e = { if ($_.DateInstallation) { ([datetime]$_.DateInstallation).ToString('dd/MM/yyyy') } else { '—' } } }, Source | Out-Host
Write-PMLog "Recherche $($KB.ToUpper()) : $(@($result | Where-Object Resultat -eq 'INSTALLÉ').Count) poste(s) équipé(s) sur $($result.Count)"
