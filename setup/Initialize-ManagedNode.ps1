#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prépare un poste SUPERVISÉ (machine virtuelle Windows) pour PatchManager.

.DESCRIPTION
    À exécuter une fois, en administrateur, sur chaque poste du parc :
      1. passe le profil réseau "Public" en "Privé" (Enable-PSRemoting refuse le profil Public) ;
      2. active PowerShell Remoting (service WinRM automatique + écouteur HTTP 5985) ;
      3. RESTREINT les règles de pare-feu WinRM à l'adresse du poste d'administration
         (par défaut Windows les ouvre à tout le sous-réseau local) ;
      4. autorise le ping (ICMPv4 echo) uniquement depuis le poste d'administration ;
      5. durcit la configuration WinRM : pas de trafic non chiffré, pas d'authentification
         Basic, CredSSP désactivé ;
      6. (option -EnableHttps) crée un écouteur HTTPS 5986 avec un certificat et exporte
         ce certificat pour l'approuver sur le poste d'administration ;
      7. affiche un état final (service, écouteurs, Test-WSMan, règles de pare-feu).

.PARAMETER AdminStationIP
    Adresse(s) IP du (des) poste(s) d'administration autorisé(s) à se connecter.

.EXAMPLE
    .\Initialize-ManagedNode.ps1 -AdminStationIP 192.168.10.10
.EXAMPLE
    .\Initialize-ManagedNode.ps1 -AdminStationIP 192.168.10.10 -EnableHttps
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateScript({ [System.Net.IPAddress]::TryParse($_, [ref]$null) })] [string[]] $AdminStationIP,
    [switch] $EnableHttps,
    [switch] $NoPing
)
$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }

# 1. Profil réseau --------------------------------------------------------------------
Write-Step 'Profil réseau'
foreach ($p in (Get-NetConnectionProfile)) {
    if ($p.NetworkCategory -eq 'Public' -and $PSCmdlet.ShouldProcess($p.InterfaceAlias, 'Passage du profil Public en Private')) {
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
        Write-Host "  $($p.InterfaceAlias) : Public -> Private"
    } else {
        Write-Host "  $($p.InterfaceAlias) : $($p.NetworkCategory)"
    }
}

# 2. PowerShell Remoting --------------------------------------------------------------
Write-Step 'Activation de PowerShell Remoting (Enable-PSRemoting)'
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Enable-PSRemoting')) {
    Enable-PSRemoting -Force | Out-Null
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM
}
Get-Service -Name WinRM | Format-Table -AutoSize Name, Status, StartType | Out-Host

# 3. Pare-feu : WinRM limité au poste d'administration ------------------------------------
Write-Step "Pare-feu : WinRM limité à $($AdminStationIP -join ', ')"
# Les règles intégrées sont identifiées par leur NOM (indépendant de la langue de Windows)
$winrmRules = Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue
foreach ($rule in $winrmRules) {
    if ($PSCmdlet.ShouldProcess($rule.Name, "RemoteAddress = $($AdminStationIP -join ',')")) {
        Set-NetFirewallRule -Name $rule.Name -RemoteAddress $AdminStationIP
    }
}
# La règle du profil Public est désactivée : un poste en réseau public n'est pas administré
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -ErrorAction SilentlyContinue | Disable-NetFirewallRule

# 4. Ping depuis le poste d'administration uniquement -----------------------------------
if (-not $NoPing) {
    Write-Step 'Pare-feu : ICMPv4 echo autorisé depuis le poste d''administration'
    $name = 'PatchManager-ICMPv4-In'
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $name -DisplayName 'PatchManager - Ping depuis le poste d''administration' `
        -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress $AdminStationIP -Action Allow -Profile Domain, Private | Out-Null
}

# 5. Durcissement du service WinRM ------------------------------------------------------
Write-Step 'Durcissement WinRM'
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false
Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $false
Set-Item -Path WSMan:\localhost\Service\Auth\CredSSP -Value $false
try { Disable-WSManCredSSP -Role Server -ErrorAction SilentlyContinue } catch { Write-Verbose 'CredSSP déjà désactivé' }
Get-ChildItem -Path WSMan:\localhost\Service\Auth | Format-Table -AutoSize Name, Value | Out-Host

# 6. Écouteur HTTPS (optionnel) ------------------------------------------------------------
if ($EnableHttps) {
    Write-Step 'Écouteur WinRM HTTPS (5986)'
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress)
    $dns = @($env:COMPUTERNAME) + $ips
    # En production : certificat émis par l'autorité de certification de l'entreprise (AD CS)
    $cert = New-SelfSignedCertificate -DnsName $dns -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -KeyLength 2048 -NotAfter (Get-Date).AddYears(2) -FriendlyName 'WinRM HTTPS - PatchManager'
    Get-ChildItem -Path WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
    $name = 'PatchManager-WinRM-HTTPS-In'
    Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $name -DisplayName 'PatchManager - WinRM HTTPS depuis le poste d''administration' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -RemoteAddress $AdminStationIP -Action Allow -Profile Domain, Private | Out-Null
    $cer = Join-Path -Path $PWD -ChildPath "$env:COMPUTERNAME-winrm.cer"
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Write-Host "  Certificat exporté : $cer"
    Write-Host '  -> Le copier sur le poste d''administration puis, en administrateur :'
    Write-Host "     Import-Certificate -FilePath .\$env:COMPUTERNAME-winrm.cer -CertStoreLocation Cert:\LocalMachine\Root"
    Write-Host '  -> Puis mettre UseSSL = $true dans config\PatchManager.config.psd1'
}

# 7. État final ------------------------------------------------------------------------
Write-Step 'Vérifications'
Get-ChildItem -Path WSMan:\localhost\Listener | ForEach-Object {
    [pscustomobject]@{ Ecouteur = $_.Name; Transport = ($_.Keys | Where-Object { $_ -like 'Transport=*' }) -replace 'Transport=' }
} | Format-Table -AutoSize | Out-Host
Test-WSMan -ComputerName localhost | Format-List ProductVendor, ProductVersion | Out-Host
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*', 'PatchManager-*' -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{
        Regle   = $_.Name
        Active  = $_.Enabled
        Profil  = $_.Profile
        Sources = ($_ | Get-NetFirewallAddressFilter).RemoteAddress -join ', '
    }
} | Format-Table -AutoSize | Out-Host

$lat = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
if ($lat -eq 1) {
    Write-Warning 'LocalAccountTokenFilterPolicy = 1 (positionné par Enable-PSRemoting en groupe de travail) : les comptes administrateurs locaux obtiennent un jeton complet à distance. Préférer le point de terminaison JEA avec un compte non administrateur (voir jea\).'
}
Write-Host "`nPoste $env:COMPUTERNAME prêt pour PatchManager." -ForegroundColor Green
