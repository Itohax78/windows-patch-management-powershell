<#
.SYNOPSIS
    Enregistre un secret (identifiants WinRM ou SMTP, URL de webhook) chiffré par DPAPI.

.DESCRIPTION
    Aucun mot de passe ne doit apparaître en clair dans les scripts ou la configuration.
    Export-Clixml chiffre la partie secrète (SecureString) avec DPAPI : le fichier n'est
    déchiffrable QUE par le même compte Windows sur la même machine. Un fichier volé ou
    copié sur un autre poste est inutilisable.

    Pour une tâche planifiée, exécuter ce script SOUS LE COMPTE de la tâche
    (runas /user:... powershell) afin que ce compte puisse relire le secret.

    En production, on préférera un coffre-fort (module Microsoft.PowerShell.SecretManagement
    + SecretStore, Azure Key Vault, CyberArk...) ou un compte de service géré (gMSA), qui
    supprime totalement le besoin de stocker un mot de passe.

.EXAMPLE
    .\Save-PMSecret.ps1 -Type WinRM      # -> secrets\winrm.cred.xml
.EXAMPLE
    .\Save-PMSecret.ps1 -Type Smtp       # -> secrets\smtp.cred.xml
.EXAMPLE
    .\Save-PMSecret.ps1 -Type Webhook    # -> secrets\webhook.cred.xml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('WinRM', 'Smtp', 'Webhook')] [string] $Type,
    [string] $Path
)
$ErrorActionPreference = 'Stop'
$secrets = Join-Path (Split-Path $PSScriptRoot -Parent) 'secrets'
if (-not (Test-Path $secrets)) { New-Item -Path $secrets -ItemType Directory | Out-Null }
if (-not $Path) { $Path = Join-Path $secrets ("{0}.cred.xml" -f $Type.ToLowerInvariant()) }

# Saisie masquée : le secret n'apparaît jamais à l'écran ni dans l'historique
switch ($Type) {
    'WinRM'   { $secret = Get-Credential -Message 'Compte utilisé pour les connexions WinRM (ex. .\svc-patchaudit)' }
    'Smtp'    { $secret = Get-Credential -Message 'Compte du serveur SMTP' }
    'Webhook' { $secret = Read-Host -Prompt 'URL du webhook (saisie masquée)' -AsSecureString }
}
# Chiffrement DPAPI : seul ce compte, sur ce poste, pourra relire le fichier
$secret | Export-Clixml -Path $Path
Write-Host "Secret chiffré (DPAPI, compte $env:USERDOMAIN\$env:USERNAME) enregistré dans $Path" -ForegroundColor Green
switch ($Type) {
    'WinRM'   { Write-Host "Utilisation : .\Invoke-PatchAudit.ps1 -CredentialFile `"$Path`"" }
    'Smtp'    { Write-Host "Utilisation : Notification.CredentialFile = '$Path' dans config\PatchManager.config.psd1" }
    'Webhook' { Write-Host "Utilisation : Notification.Method = 'Webhook' et Notification.WebhookUrlFile = '$Path'" }
}
