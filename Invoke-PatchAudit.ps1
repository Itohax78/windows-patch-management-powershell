<#
.SYNOPSIS
    PatchManager - Audit centralisé des correctifs de sécurité d'un parc Windows.

.DESCRIPTION
    Point d'entrée principal de la solution. Enchaîne automatiquement :
      1. lecture de l'inventaire (computers.txt) et test de disponibilité des postes ;
      2. connexion distante PowerShell Remoting / WinRM ;
      3. collecte des informations système et des correctifs installés ;
      4. contrôle de conformité par rapport à required-patches.txt ;
      5. détection des anomalies (postes non conformes ou inaccessibles) ;
      6. production des rapports CSV et HTML, journalisation dans PatchManager.log ;
      7. notification de l'administrateur, uniquement en cas d'anomalie.

.PARAMETER Credential
    Compte utilisé pour les connexions WinRM. Par défaut : compte courant (Kerberos en
    domaine). En groupe de travail : -Credential (Get-Credential) ou un fichier chiffré
    créé par setup\Save-PMSecret.ps1 (-CredentialFile).

.PARAMETER CredentialFile
    Identifiants WinRM chiffrés par DPAPI (utile pour une tâche planifiée).

.PARAMETER NoNotification
    Ne pas envoyer de notification (le rapport est quand même généré).

.PARAMETER OpenReport
    Ouvre le rapport HTML à la fin de l'audit.

.EXAMPLE
    .\Invoke-PatchAudit.ps1 -Credential (Get-Credential) -OpenReport

.EXAMPLE
    .\Invoke-PatchAudit.ps1 -ConfigPath .\config\PatchManager.config.psd1 -CredentialFile .\secrets\winrm.cred.xml
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialFile', Justification = 'Chemin du fichier chiffré DPAPI, pas un mot de passe')]
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty,
    [string] $CredentialFile,
    [string] $ComputersFile,
    [string] $RequiredPatchesFile,
    [switch] $NoNotification,
    [switch] $OpenReport
)

$ErrorActionPreference = 'Stop'
# Chargement du module et de la configuration (les paramètres de la ligne de commande sont prioritaires)
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'src\PatchManager\PatchManager.psd1') -Force

$cfgParams = @{ Override = @{ ComputersFile = $ComputersFile; RequiredPatchesFile = $RequiredPatchesFile } }
if ($ConfigPath) { $cfgParams.Path = $ConfigPath }
$config = Import-PMConfiguration @cfgParams

if ($CredentialFile) {
    # PSCredential chiffré par DPAPI : lisible uniquement par ce compte sur ce poste
    $Credential = Import-Clixml -Path $CredentialFile
}

Write-Host ''
Write-Host '  PatchManager - audit des correctifs de sécurité Windows' -ForegroundColor Cyan
Write-Host "  Inventaire : $($config.ComputersFile)"
Write-Host "  Politique  : $($config.RequiredPatchesFile)"
Write-Host "  Connexion  : WinRM $(if ($config.UseSSL) { 'HTTPS' } else { 'HTTP' }) par $($config.ConnectBy), point de terminaison '$($config.ConfigurationName)'"
Write-Host ''

# Lancement de la chaîne complète : test des postes -> collecte -> conformité -> rapport -> notification
$audit = Invoke-PMAudit -Credential $Credential -NoNotification:$NoNotification
$s = $audit.Summary

# Affichage console du rapport (le détail complet est dans le HTML et les CSV)
Write-Host '=== Rapport de sécurité ===' -ForegroundColor Cyan
$audit.Report | Format-Table -AutoSize -Property Poste, @{ n = 'Adresse IP'; e = { $_.AdresseIP } },
    @{ n = 'Accès'; e = { $_.Accessibilite } },
    @{ n = 'Windows'; e = { if ($_.Windows) { $_.Windows } else { '—' } } },
    @{ n = 'WU'; e = { if ($_.WindowsUpdate) { $_.WindowsUpdate } else { '—' } } },
    @{ n = 'Requises'; e = { $_.KBRequises } },
    @{ n = 'Manquantes'; e = { $_.KBManquantes } },
    @{ n = 'Conformité'; e = { $_.Conformite } } | Out-Host

# Synthèse globale du parc demandée en partie 6
Write-Host '=== Synthèse globale ===' -ForegroundColor Cyan
$lines = [ordered]@{
    'Nombre total de postes'           = $s.NbPostes
    'Postes accessibles'               = $s.NbAccessibles
    'Postes inaccessibles'             = $s.NbInaccessibles
    'Postes conformes'                 = $s.NbConformes
    'Postes non conformes'             = $s.NbNonConformes
    'Total de correctifs manquants'    = $s.NbCorrectifsManquants
    'Taux de conformité (hors inacc.)' = $s.TauxConformiteTexte
}
foreach ($k in $lines.Keys) { Write-Host ('  {0,-34}: {1}' -f $k, $lines[$k]) }

# Postes à traiter en priorité (non conformes ou inaccessibles)
if ($audit.Interventions.Count) {
    Write-Host "`n=== Postes nécessitant une intervention ===" -ForegroundColor Red
    $audit.Interventions | Format-Table -AutoSize -Wrap Poste, Conformite, ListeKBManquantes, Motif, ActionRecommandee | Out-Host
} else {
    Write-Host "`nAucune intervention nécessaire : parc conforme." -ForegroundColor Green
}

$notif = if ($NoNotification) { 'ignorée (option -NoNotification)' } else { switch ($audit.Notified) { $true { 'envoyée' } $false { 'NON envoyée (voir PatchManager.log)' } default { 'aucune (pas d''anomalie ou désactivée)' } } }
Write-Host "Notification : $notif"
Write-Host "Rapports     : $($audit.RunFolder)"
Write-Host "Journal      : $($config.LogFile)"
Write-Host ("Durée        : {0:N1} s" -f $audit.Duration.TotalSeconds)

if ($OpenReport) { Invoke-Item -Path $audit.HtmlReport }

# Code de sortie exploitable par une tâche planifiée / supervision :
# 0 = parc conforme, 1 = au moins une anomalie
if ($audit.Interventions.Count) { exit 1 } else { exit 0 }
