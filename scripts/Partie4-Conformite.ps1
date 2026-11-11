<#
.SYNOPSIS
    Partie 4 - Contrôle de conformité du parc par rapport à required-patches.txt.
.EXAMPLE
    .\scripts\Partie4-Conformite.ps1 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RequiredPatchesFile,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath -Override @{ RequiredPatchesFile = $RequiredPatchesFile }

# Lecture de la politique : liste des KB obligatoires (required-patches.txt)
$required = @(Read-PMRequiredPatch)
Write-Host "`n=== Politique : $($required.Count) correctif(s) obligatoire(s) ===" -ForegroundColor Cyan
$required | Format-Table -AutoSize KB, Description, @{ n = 'Postes ciblés'; e = { $_.Target } } | Out-Host

Write-PMLog 'Début du contrôle de conformité'
$date = Get-Date
$hosts = @(Invoke-PMCollection -Computer @(Read-PMComputerList) -Credential $Credential)
# Comparaison installés / obligatoires : CONFORME, NON CONFORME ou INACCESSIBLE
$compliance = @(Test-PMCompliance -HostResult $hosts -RequiredPatch $required -ControlDate $date)

Write-Host "=== Conformité du parc - contrôle du $($date.ToString('dd/MM/yyyy HH:mm:ss')) ===`n" -ForegroundColor Cyan
$compliance | Format-Table -AutoSize -Property Poste, @{ n = 'KB requises'; e = { $_.KBRequises } },
    @{ n = 'KB manquantes'; e = { $_.KBManquantes } }, @{ n = 'État'; e = { $_.Etat } } | Out-Host

foreach ($c in $compliance) {
    switch ($c.Etat) {
        'CONFORME'     { Write-PMLog $c.Poste, 'Conforme' }
        'NON CONFORME' {
            Write-Host "$($c.Poste) : NON CONFORME - correctifs manquants : $($c.ListeKBManquantes)" -ForegroundColor Red
            Write-PMLog -Level WARN -Message $c.Poste, 'Non conforme', $c.ListeKBManquantes
        }
        'INACCESSIBLE' {
            Write-Host "$($c.Poste) : INACCESSIBLE - $($c.Motif)" -ForegroundColor DarkYellow
            Write-PMLog -Level WARN -Message $c.Poste, 'Inaccessible', $c.Motif
        }
    }
}

# Taux global calculé SANS les postes inaccessibles
$rate = Get-PMComplianceRate -Compliance $compliance
$rateText = if ($null -eq $rate) { 'N/A (aucun poste évalué)' } else { "$rate %" }
Write-Host "`nTaux global de conformité (hors postes inaccessibles) : $rateText" -ForegroundColor $(if ($rate -eq 100) { 'Green' } else { 'Yellow' })

# Sauvegarde du résultat horodaté dans ComplianceReport.csv
$path = Join-Path (New-PMRunFolder) 'ComplianceReport.csv'
Export-PMCsv -InputObject $compliance -Path $path -Delimiter $PMConfig.CsvDelimiter
Write-PMLog "Contrôle de conformité exporté ($path) ; taux $rateText"
Write-Host "Exporté : $path" -ForegroundColor Green
