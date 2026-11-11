#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Partie 8 - Active la traçabilité des actions PowerShell / WinRM sur un poste.

.DESCRIPTION
    - Script Block Logging : le code PowerShell exécuté (y compris à distance) est
      enregistré dans le journal Microsoft-Windows-PowerShell/Operational (événement 4104) ;
    - Module Logging : les appels de commandes sont journalisés (événement 4103) ;
    - Transcription : copie texte de chaque session dans un dossier protégé ;
    - augmente la taille du journal PowerShell et active le journal WinRM ;
    - (option -DisablePowerShellV2) supprime le moteur 2.0, qui permet de contourner
      la journalisation et AMSI ("attaque par rétrogradation").
    En entreprise, ces paramètres sont déployés par GPO et les journaux transférés vers
    un collecteur central (Windows Event Forwarding / SIEM) pour ne pas pouvoir être
    effacés par un attaquant ayant compromis le poste.

.EXAMPLE
    .\Enable-PSAuditLogging.ps1 -DisablePowerShellV2
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TranscriptPath = (Join-Path $env:ProgramData 'PowerShellTranscripts'),
    [switch] $DisablePowerShellV2
)
$ErrorActionPreference = 'Stop'
$base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'

function Write-RegistryPolicy([string] $Key, [hashtable] $Values) {
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
    foreach ($n in $Values.Keys) {
        $type = if ($Values[$n] -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -Path $Key -Name $n -Value $Values[$n] -PropertyType $type -Force | Out-Null
    }
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Activation de la journalisation PowerShell')) {
    Write-RegistryPolicy "$base\ScriptBlockLogging" @{ EnableScriptBlockLogging = 1 }
    Write-RegistryPolicy "$base\ModuleLogging" @{ EnableModuleLogging = 1 }
    Write-RegistryPolicy "$base\ModuleLogging\ModuleNames" @{ '*' = '*' }

    # Dossier de transcription : écriture pour tous, lecture réservée aux administrateurs
    New-Item -Path $TranscriptPath -ItemType Directory -Force | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')), 'FullControl', $inh, 'None', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')), 'FullControl', $inh, 'None', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')), 'Write, ReadAttributes, Synchronize', $inh, 'None', 'Allow')))
    Set-Acl -Path $TranscriptPath -AclObject $acl
    Write-RegistryPolicy "$base\Transcription" @{ EnableTranscripting = 1; EnableInvocationHeader = 1; OutputDirectory = $TranscriptPath }

    # Journaux : taille augmentée, journal WinRM opérationnel actif
    wevtutil.exe sl 'Microsoft-Windows-PowerShell/Operational' /ms:104857600 | Out-Null
    wevtutil.exe sl 'Microsoft-Windows-WinRM/Operational' /e:true | Out-Null
}

if ($DisablePowerShellV2) {
    foreach ($f in 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2') {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -eq 'Enabled' -and $PSCmdlet.ShouldProcess($f, 'Désactivation')) {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart | Out-Null
            Write-Host "$f désactivé"
        }
    }
}

Write-Host 'Journalisation PowerShell activée. Consultation :' -ForegroundColor Green
Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-PowerShell/Operational' -MaxEvents 20 | Where-Object Id -eq 4104"
Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-WinRM/Operational' -MaxEvents 20"
