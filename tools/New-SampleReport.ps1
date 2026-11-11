<#
.SYNOPSIS
    Génère un jeu de rapports d'EXEMPLE (données fictives) dans examples\, afin de
    visualiser le rendu des livrables sans disposer du laboratoire.
    Les rapports réels sont produits par Invoke-PatchAudit.ps1 dans Output\.
#>
[CmdletBinding()]
param([string] $Destination = (Join-Path (Split-Path $PSScriptRoot -Parent) 'examples'))

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\PatchManager\PatchManager.psd1') -Force
. (Join-Path $root 'tests\TestHelpers.ps1')

$log = Join-Path $Destination 'PatchManager.log'
if (Test-Path $log) { Remove-Item $log }
Import-PMConfiguration -Override @{ OutputRoot = $Destination; LogFile = $log; Notification = @{ Enabled = $true; Method = 'File'; To = @('admin@entreprise.local'); AttachCsv = $true } } | Out-Null

# Parc fictif : 2 postes conformes, 1 non conforme, 1 inaccessible
$hosts = @(
    (New-FakeHostResult -Name 'PC01' -IPAddress '192.168.10.11' -HotFix 'KB5062553', 'KB5063878', 'KB5054156'),
    (New-FakeHostResult -Name 'PC02' -IPAddress '192.168.10.12' -HotFix 'KB5034441', 'KB5048161' -Caption 'Microsoft Windows 10 Professionnel' -Build '19045' -WUStatus 'Stopped'),
    (New-FakeHostResult -Name 'PC03' -IPAddress '192.168.10.13' -HotFix 'KB5062553', 'KB5054156' -RebootPending $true),
    (New-FakeHostResult -Name 'PC04' -IPAddress '192.168.10.14' -Inaccessible -Detail 'WinRM inaccessible (port 5985 fermé ou filtré)')
)
$hosts[1].System.OSDisplayVersion = '22H2'; $hosts[1].System.OSUBR = 6093
foreach ($h in $hosts | Where-Object System) { $h.Ping = $true }

$required = @(Read-PMRequiredPatch -Path (Join-Path $root 'required-patches.txt'))
$folder = $Destination
Write-PMLog "Début de l'audit"
foreach ($h in $hosts) { if ($h.Accessible) { Write-PMLog $h.Name, 'Accessible' } else { Write-PMLog $h.Name, 'WinRM inaccessible' } }
$inventory  = @(ConvertTo-PMInventory -HostResult $hosts)
$patches    = @(ConvertTo-PMPatchInventory -HostResult $hosts)
$compliance = @(Test-PMCompliance -HostResult $hosts -RequiredPatch $required)
foreach ($c in $compliance | Where-Object Etat -ne 'INACCESSIBLE') {
    if ($c.Etat -eq 'CONFORME') { Write-PMLog $c.Poste, 'Conforme' } else { Write-PMLog $c.Poste, 'Non conforme', $c.ListeKBManquantes }
}
$report     = @(New-PMSecurityReport -Inventory $inventory -Compliance $compliance)
$summary    = Get-PMParcSummary -Report $report
$interv     = @(Get-PMInterventionList -Report $report)
$attention  = @(Get-PMAttentionPoint -Inventory $inventory)

$d = (Get-PMConfiguration).CsvDelimiter

# BONUS : audit précédent fictif (PC03 était conforme -> régression ; PC02 était non conforme -> corrigé)
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pm-sample-' + [guid]::NewGuid())
$prev = New-Item -Path (Join-Path $tmpRoot '20261001-090000') -ItemType Directory -Force
@(
    [pscustomobject]@{ Poste = 'PC01'; Conformite = 'CONFORME' }, [pscustomobject]@{ Poste = 'PC02'; Conformite = 'NON CONFORME' },
    [pscustomobject]@{ Poste = 'PC03'; Conformite = 'CONFORME' }, [pscustomobject]@{ Poste = 'PC04'; Conformite = 'INACCESSIBLE' }
) | Export-Csv -Path (Join-Path $prev.FullName 'SecurityReport.csv') -Delimiter $d -NoTypeInformation -Encoding UTF8
$trend = Get-PMTrend -Report $report -RunFolder (Join-Path $tmpRoot '20261008-090000') -OutputRoot $tmpRoot
Remove-Item -Path $tmpRoot -Recurse -Force
# Historique fictif sur 5 semaines
$histFile = Join-Path $folder 'History.csv'
if (Test-Path $histFile) { Remove-Item $histFile }
$rates = 33.3, 50, 50, 66.7
for ($i = 0; $i -lt $rates.Count; $i++) {
    Add-PMHistory -Summary ([pscustomobject]@{ NbPostes = 4; NbAccessibles = 3; NbInaccessibles = 1; NbConformes = 0; NbNonConformes = 0; NbCorrectifsManquants = 0; TauxConformite = $rates[$i] }) -RunFolder $folder
}
$h = @(Get-PMHistory)
$base = Get-Date '2026-09-10'
for ($i = 0; $i -lt $h.Count; $i++) { $h[$i].Date = $base.AddDays(7 * $i).ToString('dd/MM/yyyy 09:00:00') }
$h | Export-Csv -Path $histFile -Delimiter $d -NoTypeInformation -Encoding UTF8
Add-PMHistory -Summary $summary -RunFolder $folder
$trendSvg = ConvertTo-PMTrendSvg -History @(Get-PMHistory)
Export-PMCsv -InputObject $inventory  -Path (Join-Path $folder 'Inventory.csv') -Delimiter $d
Export-PMCsv -InputObject $patches    -Path (Join-Path $folder 'PatchesInventory.csv') -Delimiter $d
Export-PMCsv -InputObject @(Get-PMPatchSummary -HostResult $hosts) -Path (Join-Path $folder 'PatchesSummary.csv') -Delimiter $d
Export-PMCsv -InputObject $compliance -Path (Join-Path $folder 'ComplianceReport.csv') -Delimiter $d
Export-PMCsv -InputObject $report     -Path (Join-Path $folder 'SecurityReport.csv') -Delimiter $d
Export-PMCsv -InputObject $interv     -Path (Join-Path $folder 'Interventions.csv') -Delimiter $d
Export-PMCsv -InputObject $trend.Changes -Path (Join-Path $folder 'Evolution.csv') -Delimiter $d
Export-PMHtmlReport -Report $report -Summary $summary -Intervention $interv -AttentionPoint $attention -RequiredPatch $required -Trend $trend -TrendSvg $trendSvg -Path (Join-Path $folder 'SecurityReport.html') | Out-Null
Write-PMLog 'Rapport généré'
Send-PMNotification -Report $report -RunFolder $folder -Trend $trend | Out-Null
Write-PMLog "Fin de l'audit"
Write-Host "Exemples générés dans $folder"
