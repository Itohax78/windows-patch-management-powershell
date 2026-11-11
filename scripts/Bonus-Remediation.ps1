<#
.SYNOPSIS
    BONUS (partie 5 « remédiation ») - Corrige les postes NON CONFORMES détectés par le dernier audit.

.DESCRIPTION
    Boucle complète du Patch Management : détecter -> corriger -> re-vérifier.
      1. lit le dernier ComplianceReport.csv (ou la liste -Computer fournie) ;
      2. pour chaque poste non conforme, installe les KB manquantes de la politique via une
         tâche planifiée SYSTEM temporaire (l'API Windows Update refuse l'installation à distance) ;
      3. (option -AuditAfter) relance un audit complet pour prouver la correction.
    Chaque action demande confirmation (désactivable avec -Confirm:$false) et est journalisée.

.EXAMPLE
    .\scripts\Bonus-Remediation.ps1 -Credential $cred -ScanOnly          # simulation : que manque-t-il ?
.EXAMPLE
    .\scripts\Bonus-Remediation.ps1 -Credential $cred -AuditAfter        # correction puis nouvel audit
.EXAMPLE
    .\scripts\Bonus-Remediation.ps1 -Computer PC02 -KB KB5063878 -Credential $cred -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]] $Computer,
    [string[]] $KB,
    [switch] $ScanOnly,
    [switch] $AllowReboot,
    [switch] $AuditAfter,
    [int] $TimeoutMinutes = 60,
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

# Liste des postes du parc (computers.txt) : la remédiation ne vise jamais un poste hors inventaire
$parc = @(Read-PMComputerList)

# Sans -Computer : on part du dernier audit et on ne garde que les postes NON CONFORMES
$missingByHost = @{}
if (-not $Computer) {
    $last = Get-ChildItem -Path $PMConfig.OutputRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'ComplianceReport.csv') } | Sort-Object Name | Select-Object -Last 1
    if (-not $last) { throw "Aucun audit trouvé : lancez d'abord .\Invoke-PatchAudit.ps1" }
    $nonConf = @(Import-Csv (Join-Path $last.FullName 'ComplianceReport.csv') -Delimiter $PMConfig.CsvDelimiter | Where-Object Etat -eq 'NON CONFORME')
    if (-not $nonConf) { Write-Host "Dernier audit ($($last.Name)) : aucun poste non conforme, rien à corriger." -ForegroundColor Green; return }
    foreach ($n in $nonConf) { $missingByHost[$n.Poste] = @($n.ListeKBManquantes -split ',\s*' | Where-Object { $_ }) }
    $Computer = @($missingByHost.Keys)
    Write-Host "Postes non conformes au dernier audit ($($last.Name)) : $($Computer -join ', ')" -ForegroundColor Yellow
}
$targets = @($parc | Where-Object { $Computer -contains $_.Name })
if (-not $targets) { throw "Aucun des postes demandés ne figure dans computers.txt" }

Write-PMLog "Début de la remédiation ($(if ($ScanOnly) { 'recherche seule' } else { 'installation' }))"
$results = foreach ($t in $targets) {
    # KB à installer : celles passées en paramètre, sinon celles manquantes pour CE poste
    # @(...) obligatoire : un « if » qui renvoie @() produit $null, refusé par la validation de -KB
    $kbs = @(if ($KB) { $KB } elseif ($missingByHost.ContainsKey($t.Name)) { $missingByHost[$t.Name] })
    $p = @{ Computer = $t; ScanOnly = $ScanOnly; AllowReboot = $AllowReboot; TimeoutMinutes = $TimeoutMinutes; Credential = $Credential }
    # Sans KB : recherche / installation des mises à jour de sécurité et critiques
    if ($kbs.Count) { $p.KB = $kbs }
    Invoke-PMRemediation @p
}

Write-Host "`n=== Résultat de la remédiation ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap Poste, Mode, Trouvees, Installees, Echecs, RedemarrageRequis, Detail | Out-Host
$path = Join-Path (New-PMRunFolder) 'Remediation.csv'
Export-PMCsv -InputObject @($results) -Path $path -Delimiter $PMConfig.CsvDelimiter
Write-PMLog "Fin de la remédiation ($path)"

# Les correctifs installés ne sont actifs qu'après redémarrage : on le rappelle à l'administrateur
if (@($results | Where-Object RedemarrageRequis).Count -and -not $AllowReboot) {
    Write-Warning 'Redémarrage requis sur au moins un poste : relancez avec -AllowReboot ou redémarrez manuellement avant de ré-auditer.'
}

# Boucle fermée : nouvel audit pour vérifier que les postes sont désormais conformes
if ($AuditAfter -and -not $ScanOnly) {
    Write-Host "`n=== Nouvel audit de contrôle ===" -ForegroundColor Cyan
    & (Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-PatchAudit.ps1') -ConfigPath $ConfigPath -Credential $Credential -NoNotification
}
