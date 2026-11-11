<#
.SYNOPSIS
    Partie 3 - Inventaire des correctifs : liste locale, collecte distante sur tout le
    parc, export PatchesInventory.csv trié par poste puis date décroissante, synthèse.
.EXAMPLE
    .\scripts\Partie3-Correctifs.ps1 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty,
    [switch] $SkipLocal
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

if (-not $SkipLocal) {
    # Questions 1-2 : correctifs de la machine locale (KB, description, date, compte)
    Write-Host "`n=== Correctifs installés sur la machine locale ($env:COMPUTERNAME) ===`n" -ForegroundColor Cyan
    # InstalledOn peut lever une exception sur certaines entrées (date mal formée) :
    # on la convertit une seule fois, sans bloquer, avant de trier
    Get-HotFix | ForEach-Object {
            $date = $null
            try { if ($_.InstalledOn) { $date = [datetime]$_.InstalledOn } } catch { $date = $null }
            $_ | Add-Member -NotePropertyName DateInstallation -NotePropertyValue $date -Force -PassThru
        } | Sort-Object -Property DateInstallation -Descending |
        Format-Table -AutoSize -Property @{ n = 'KB'; e = { $_.HotFixID } }, Description,
            @{ n = 'Date d''installation'; e = { if ($_.DateInstallation) { $_.DateInstallation.ToString('dd/MM/yyyy') } else { '—' } } },
            @{ n = 'Installé par'; e = { if ($_.InstalledBy) { $_.InstalledBy } else { '(non renseigné)' } } } | Out-Host
}

# Questions 3-6 : collecte distante sur tout le parc
Write-PMLog 'Début de l''inventaire des correctifs'
# Collecte des correctifs sur tout le parc, en parallèle
$hosts   = @(Invoke-PMCollection -Computer @(Read-PMComputerList) -Credential $Credential)
# Une ligne par correctif, triée par poste puis par date décroissante
$patches = @(ConvertTo-PMPatchInventory -HostResult $hosts)
$summary = @(Get-PMPatchSummary -HostResult $hosts)

# Postes inaccessibles : ignorés proprement, sans interrompre l'exécution
foreach ($h in ($hosts | Where-Object { -not $_.System })) {
    Write-Warning "$($h.Name) ($($h.IPAddress)) ignoré : $($h.Detail)"
    Write-PMLog -Level WARN -Message $h.Name, 'Ignoré', $h.Detail
}

Write-Host "`n=== Inventaire des correctifs du parc ===`n" -ForegroundColor Cyan
$patches | Format-Table -AutoSize -Property Poste, @{ n = 'Adresse IP'; e = { $_.AdresseIP } }, KB, Description,
    @{ n = 'Date d''installation'; e = { if ($_.DateInstallation) { ([datetime]$_.DateInstallation).ToString('dd/MM/yyyy') } else { '—' } } }, Source | Out-Host

Write-Host '=== Synthèse par poste ===' -ForegroundColor Cyan
$summary | Format-Table -AutoSize -Property Poste, Etat, @{ n = 'Nb correctifs'; e = { $_.NbCorrectifs } },
    @{ n = 'Correctif le plus récent'; e = { if ($_.DateDernierCorrectif) { ([datetime]$_.DateDernierCorrectif).ToString('dd/MM/yyyy') } else { '—' } } },
    @{ n = 'Dernier KB'; e = { $_.DernierKB } } | Out-Host

# Export de PatchesInventory.csv et de la synthèse par poste
$folder = New-PMRunFolder
Export-PMCsv -InputObject $patches -Path (Join-Path $folder 'PatchesInventory.csv') -Delimiter $PMConfig.CsvDelimiter
Export-PMCsv -InputObject $summary -Path (Join-Path $folder 'PatchesSummary.csv') -Delimiter $PMConfig.CsvDelimiter
Write-PMLog "Inventaire des correctifs exporté ($folder)"
Write-Host "Exporté : $(Join-Path $folder 'PatchesInventory.csv')" -ForegroundColor Green
