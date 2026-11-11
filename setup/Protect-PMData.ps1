#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Partie 8 (question 4) - Restreint l'accès aux fichiers produits par PatchManager.

.DESCRIPTION
    Les rapports et journaux décrivent précisément les faiblesses du parc (postes non
    à jour, KB manquantes) : c'est une information précieuse pour un attaquant.
    Ce script :
      - désactive l'héritage des droits sur Output, Logs et secrets ;
      - n'accorde l'accès qu'à SYSTEM, au groupe Administrateurs et au compte opérateur ;
      - interdit la SUPPRESSION des journaux à l'opérateur (refus explicite Delete) :
        le script peut ajouter des lignes mais pas effacer l'historique ;
      - restreint secrets\ (identifiants chiffrés) au seul opérateur et à SYSTEM.
    Les groupes sont désignés par SID (indépendant de la langue de Windows).

.EXAMPLE
    .\Protect-PMData.ps1 -Operator "PC-ADMIN\admin-patch"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Operator = "$env:USERDOMAIN\$env:USERNAME",
    [string] $ProjectRoot = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'

# Comptes désignés par SID : fonctionne quelle que soit la langue de Windows
$system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$op     = New-Object System.Security.Principal.NTAccount($Operator)
$inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$none    = [System.Security.AccessControl.PropagationFlags]::None

function Get-AccessRule($Identity, $Rights, $Type = 'Allow') {
    New-Object System.Security.AccessControl.FileSystemAccessRule($Identity, [System.Security.AccessControl.FileSystemRights]$Rights, $inherit, $none, $Type)
}

# Droits par dossier ; sur Logs, refus explicite de suppression pour l'opérateur
$plan = @{
    'Output'  = @((Get-AccessRule $system 'FullControl'), (Get-AccessRule $admins 'FullControl'), (Get-AccessRule $op 'Modify'))
    'Logs'    = @((Get-AccessRule $system 'FullControl'), (Get-AccessRule $admins 'FullControl'), (Get-AccessRule $op 'Modify'),
                  (Get-AccessRule $op 'Delete, DeleteSubdirectoriesAndFiles' 'Deny'))
    'secrets' = @((Get-AccessRule $system 'FullControl'), (Get-AccessRule $op 'Modify'))
}

# Application : héritage coupé, propriétaire = Administrateurs, puis nouvelles règles
foreach ($folder in $plan.Keys) {
    $path = Join-Path $ProjectRoot $folder
    if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)   # héritage désactivé, droits hérités supprimés
    $acl.SetOwner($admins)
    foreach ($rule in $plan[$folder]) { $acl.AddAccessRule($rule) }
    if ($PSCmdlet.ShouldProcess($path, 'Application des ACL restrictives')) {
        Set-Acl -Path $path -AclObject $acl
    }
    Write-Host "== $path" -ForegroundColor Cyan
    (Get-Acl -Path $path).Access | Format-Table -AutoSize IdentityReference, AccessControlType, FileSystemRights | Out-Host
}
Write-Host 'Remarque : le groupe "Utilisateurs" n''a plus aucun accès aux rapports, journaux et secrets.' -ForegroundColor Green
