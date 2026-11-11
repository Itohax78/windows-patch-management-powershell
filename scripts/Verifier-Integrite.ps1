<#
.SYNOPSIS
    Partie 8 - Vérifie l'intégrité des rapports d'audit (manifeste SHA256SUMS.txt).
.DESCRIPTION
    Par défaut, vérifie TOUS les audits complets du dossier Output (ceux qui possèdent un
    manifeste SHA256SUMS.txt, produit par Invoke-PatchAudit.ps1). Les dossiers créés par
    les scripts de parties isolées (Partie1..Partie8) n'ont pas de manifeste : ils sont
    simplement signalés.
.EXAMPLE
    .\scripts\Verifier-Integrite.ps1                       # tous les audits
.EXAMPLE
    .\scripts\Verifier-Integrite.ps1 -RunFolder .\Output\20261005-090000
#>
[CmdletBinding()]
param([string] $RunFolder, [string] $ConfigPath)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

# Dossiers à vérifier : celui demandé, sinon tous les audits qui ont un manifeste
if ($RunFolder) {
    $folders = @(Get-Item -Path $RunFolder)
} else {
    $all = @(Get-ChildItem -Path $PMConfig.OutputRoot -Directory | Sort-Object Name)
    $folders = @($all | Where-Object { Test-Path (Join-Path $_.FullName 'SHA256SUMS.txt') })
    $sans = @($all | Where-Object { -not (Test-Path (Join-Path $_.FullName 'SHA256SUMS.txt')) })
    if ($sans) {
        Write-Host "$($sans.Count) dossier(s) sans manifeste ignoré(s) (scripts de parties isolées) : $(($sans.Name) -join ', ')" -ForegroundColor DarkGray
    }
    if (-not $folders) { Write-Warning "Aucun audit avec manifeste dans $($PMConfig.OutputRoot) : lancer d'abord Invoke-PatchAudit.ps1"; exit 0 }
}

$alerte = $false
foreach ($f in $folders) {
    # Recalcul des empreintes SHA-256 et comparaison avec le manifeste
    $result = @(Test-PMIntegrity -RunFolder $f.FullName)
    $bad = @($result | Where-Object Etat -ne 'INTACT')
    if ($bad) {
        $alerte = $true
        Write-Host "`n$($f.Name) : ALERTE - $($bad.Count) fichier(s) modifié(s), supprimé(s) ou ajouté(s)" -ForegroundColor Red
        $result | Format-Table -AutoSize | Out-Host
        Write-PMLog -Level ERROR -Message "Intégrité compromise ($($f.FullName))", (($bad | ForEach-Object { "$($_.Fichier)=$($_.Etat)" }) -join ', ')
    } else {
        Write-Host "$($f.Name) : $($result.Count) fichier(s) INTACT(S)" -ForegroundColor Green
    }
}
if ($alerte) { exit 1 }
Write-Host "`nTous les audits vérifiés sont intacts." -ForegroundColor Green
