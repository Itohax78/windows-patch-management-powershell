#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Planifie l'audit automatique quotidien (veille et maintenance).

.DESCRIPTION
    Crée la tâche planifiée "PatchManager - Audit quotidien" qui lance Invoke-PatchAudit.ps1
    chaque jour à l'heure indiquée, sous un compte dédié (jamais sous un compte personnel
    d'administrateur). Le fichier d'identifiants WinRM (secrets\winrm.cred.xml) doit avoir
    été créé PAR CE MÊME COMPTE avec setup\Save-PMSecret.ps1 (chiffrement DPAPI).

.EXAMPLE
    .\Register-PatchAuditTask.ps1 -At 07:00 -RunAs (Get-Credential PC-ADMIN\svc-patchmanager)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialFile', Justification = 'Chemin du fichier chiffré DPAPI, pas un mot de passe')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [System.Management.Automation.PSCredential] $RunAs,
    [string] $At = '07:00',
    [string] $TaskName = 'PatchManager - Audit quotidien',
    [string] $CredentialFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets\winrm.cred.xml')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'Invoke-PatchAudit.ps1'

# Ligne de commande de la tâche (identifiants lus depuis le fichier chiffré)
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
if (Test-Path $CredentialFile) { $arguments += " -CredentialFile `"$CredentialFile`"" }
else { Write-Warning "Fichier $CredentialFile absent : la tâche utilisera l'identité du compte $($RunAs.UserName) (Kerberos en domaine)." }

# Tâche quotidienne, une seule instance à la fois, durée limitée à 2 h
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $root
$trigger   = New-ScheduledTaskTrigger -Daily -At $At
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable -MultipleInstances IgnoreNew

if ($PSCmdlet.ShouldProcess($TaskName, 'Register-ScheduledTask')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -User $RunAs.UserName -Password $RunAs.GetNetworkCredential().Password -RunLevel Limited -Force | Out-Null
}
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State, @{ n = 'Compte'; e = { $_.Principal.UserId } }, @{ n = 'Déclencheur'; e = { $At } } | Out-Host
Write-Host "Test immédiat : Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Green
