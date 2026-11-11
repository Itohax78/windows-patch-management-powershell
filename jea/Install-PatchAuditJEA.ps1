#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Partie 8 (question 7) - Installe le point de terminaison JEA "PatchAudit" sur un poste supervisé.

.DESCRIPTION
    Just Enough Administration (JEA) permet de déléguer une tâche précise à un compte
    NON administrateur :
      - le compte d'audit (membre du groupe local PatchAuditors) se connecte au point de
        terminaison "PatchAudit" au lieu de "Microsoft.PowerShell" ;
      - la session est en mode NoLanguage : impossible d'exécuter un script arbitraire ;
      - seule la fonction Get-PatchAuditData (lecture seule) est visible ;
      - la commande s'exécute sous un compte virtuel temporaire (RunAsVirtualAccount),
        créé pour la session puis détruit : le mot de passe d'un compte privilégié n'est
        jamais exposé ;
      - chaque session est enregistrée (transcription) dans C:\ProgramData\PatchAuditJEA\Transcripts.

    Étapes :
      1. crée le groupe local PatchAuditors (et, en option, le compte svc-patchaudit) ;
      2. installe le module PatchAuditJEA dans Program Files (modifiable par les seuls admins) ;
      3. génère le fichier de configuration de session (.pssc) et l'enregistre.

    Le compte svc-patchaudit n'étant membre ni d'Administrateurs ni de "Utilisateurs de
    gestion à distance", il ne peut PAS ouvrir de session sur le point de terminaison
    standard Microsoft.PowerShell : seul PatchAudit lui est accessible.

    Côté poste d'administration, il suffit ensuite de mettre dans la configuration :
        ConfigurationName = 'PatchAudit'
    et d'utiliser les identifiants du compte svc-patchaudit.

.EXAMPLE
    .\Install-PatchAuditJEA.ps1 -CreateServiceAccount
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $GroupName = 'PatchAuditors',
    [string] $EndpointName = 'PatchAudit',
    [switch] $CreateServiceAccount,
    [string] $ServiceAccountName = 'svc-patchaudit',
    # Mot de passe du compte de service (demandé de manière masquée s'il est omis)
    [securestring] $Password
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# 1. Groupe local (et compte de service optionnel) ------------------------------------
if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $GroupName -Description 'Audit des correctifs via JEA (lecture seule)' | Out-Null
    Write-Host "Groupe local $GroupName créé"
}
if ($CreateServiceAccount) {
    if (-not (Get-LocalUser -Name $ServiceAccountName -ErrorAction SilentlyContinue)) {
        if (-not $Password) { $Password = Read-Host -Prompt "Mot de passe de $ServiceAccountName (long et unique)" -AsSecureString }
        New-LocalUser -Name $ServiceAccountName -Password $Password -Description 'Compte de service PatchManager (audit JEA)' `
            -PasswordNeverExpires:$false -UserMayNotChangePassword | Out-Null
        Write-Host "Compte $ServiceAccountName créé (membre d'aucun groupe privilégié)"
    }
    Add-LocalGroupMember -Group $GroupName -Member $ServiceAccountName -ErrorAction SilentlyContinue
}

# 2. Module JEA ------------------------------------------------------------------------
$moduleDest = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PatchAuditJEA'
if ($PSCmdlet.ShouldProcess($moduleDest, 'Installation du module JEA')) {
    New-Item -Path $moduleDest -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot 'PatchAuditJEA\*') -Destination $moduleDest -Recurse -Force
    Copy-Item -Path (Join-Path $repo 'src\PatchManager\Shared\Get-PatchAuditData.ps1') -Destination $moduleDest -Force
    Get-ChildItem -Path $moduleDest -Recurse -File | Unblock-File
}

# Le module JEA est un script (.psm1) chargé à chaque session. Sur Windows 10/11 la
# stratégie par défaut de la machine est "Restricted" : la session JEA ne pourrait pas
# le charger. RemoteSigned autorise les scripts locaux (le module est dans Program Files,
# modifiable par les seuls administrateurs) mais exige une signature pour ceux téléchargés.
$policy = Get-ExecutionPolicy -Scope LocalMachine
if ($policy -in 'Undefined', 'Restricted', 'AllSigned') {
    if ($PSCmdlet.ShouldProcess('LocalMachine', "Stratégie d'exécution $policy -> RemoteSigned")) {
        # Si la session courante est en Bypass (-Scope Process), PowerShell enregistre bien la
        # stratégie mais signale qu'elle est masquée : ce n'est pas une erreur ici
        try { Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop }
        catch [System.Security.SecurityException] { Write-Verbose $_.Exception.Message }
        Write-Host "Stratégie d'exécution de la machine : $policy -> RemoteSigned"
    }
}

# 3. Configuration de session ------------------------------------------------------------
$transcripts = Join-Path $env:ProgramData 'PatchAuditJEA\Transcripts'
New-Item -Path $transcripts -ItemType Directory -Force | Out-Null
$pssc = Join-Path $env:ProgramData "PatchAuditJEA\$EndpointName.pssc"
New-PSSessionConfigurationFile -Path $pssc `
    -SessionType RestrictedRemoteServer `
    -RunAsVirtualAccount `
    -TranscriptDirectory $transcripts `
    -RoleDefinitions @{ "$env:COMPUTERNAME\$GroupName" = @{ RoleCapabilities = 'PatchAuditor' } } `
    -Description 'PatchManager - audit des correctifs en lecture seule (JEA)'
if (-not (Test-PSSessionConfigurationFile -Path $pssc)) { throw "Fichier de configuration invalide : $pssc" }

if ($PSCmdlet.ShouldProcess($EndpointName, 'Register-PSSessionConfiguration')) {
    if (Get-PSSessionConfiguration -Name $EndpointName -ErrorAction SilentlyContinue) {
        Unregister-PSSessionConfiguration -Name $EndpointName -Force
    }
    # -Force redémarre WinRM : les sessions ouvertes sont coupées
    Register-PSSessionConfiguration -Name $EndpointName -Path $pssc -Force | Out-Null
}

# 4. Vérification ------------------------------------------------------------------------
Get-PSSessionConfiguration -Name $EndpointName | Format-List Name, RunAsVirtualAccount, SessionType, TranscriptDirectory, Permission | Out-Host
Write-Host @"
Point de terminaison JEA '$EndpointName' installé.
Test depuis le poste d'administration :
  `$c = Get-Credential .\$ServiceAccountName
  Invoke-Command -ComputerName <IP> -ConfigurationName $EndpointName -Credential `$c -ScriptBlock { Get-Command }
  Invoke-Command -ComputerName <IP> -ConfigurationName $EndpointName -Credential `$c -ScriptBlock { Get-PatchAuditData }
  Invoke-Command -ComputerName <IP> -ConfigurationName $EndpointName -Credential `$c -ScriptBlock { Stop-Computer }   # REFUSÉ
"@ -ForegroundColor Green
