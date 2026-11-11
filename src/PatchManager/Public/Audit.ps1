function Invoke-PMAudit {
    <#
    .SYNOPSIS
        Chaîne complète de Patch Management :
        inventaire -> connexion distante -> collecte des correctifs -> contrôle de
        conformité -> détection des anomalies -> rapport -> notification.
    .DESCRIPTION
        Produit dans Output\<horodatage>\ :
          Inventory.csv, PatchesInventory.csv, PatchesSummary.csv, ComplianceReport.csv,
          SecurityReport.csv, SecurityReport.html, Interventions.csv, Notification.txt,
          SHA256SUMS.txt (empreintes d'intégrité)
        et journalise chaque étape dans PatchManager.log.
    .OUTPUTS
        Objet récapitulatif contenant toutes les données de l'audit.
    #>
    [CmdletBinding()]
    param(
        [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty,
        [switch] $NoNotification,
        [switch] $SkipWSManTest
    )

    $cfg = Get-PMConfiguration
    $start = Get-Date
    Write-PMLog "Début de l'audit"
    Write-PMLog "Opérateur $([Environment]::UserDomainName)\$([Environment]::UserName) depuis $([Environment]::MachineName)"

    try {
        $runFolder = New-PMRunFolder
        $computers = @(Read-PMComputerList -Path $cfg.ComputersFile)
        $required  = @(Read-PMRequiredPatch -Path $cfg.RequiredPatchesFile)
        Write-PMLog "Inventaire chargé : $($computers.Count) poste(s) ; politique : $($required.Count) correctif(s) obligatoire(s)"
        if ($computers.Count -eq 0) { throw 'Aucun poste valide dans computers.txt' }

        # --- Collecte -----------------------------------------------------------------
        Write-Progress -Activity 'Audit des correctifs' -Status 'Test des postes et collecte via WinRM...' -PercentComplete 10
        $hosts = @(Invoke-PMCollection -Computer $computers -Credential $Credential -SkipWSManTest:$SkipWSManTest)
        foreach ($h in $hosts) {
            if ($h.Accessible) { Write-PMLog $h.Name, 'Accessible' }
            elseif ($h.Detail -like 'WinRM inaccessible*') { Write-PMLog -Level WARN -Message $h.Name, 'WinRM inaccessible' }
            else { Write-PMLog -Level WARN -Message $h.Name, 'Inaccessible', $h.Detail }
        }

        # --- Inventaires (parties 2 et 3) --------------------------------------------
        Write-Progress -Activity 'Audit des correctifs' -Status 'Construction des inventaires...' -PercentComplete 60
        $inventory = @(ConvertTo-PMInventory -HostResult $hosts)
        $patches   = @(ConvertTo-PMPatchInventory -HostResult $hosts)
        $summary3  = @(Get-PMPatchSummary -HostResult $hosts)
        Export-PMCsv -InputObject $inventory -Path (Join-Path $runFolder 'Inventory.csv') -Delimiter $cfg.CsvDelimiter
        Export-PMCsv -InputObject $patches   -Path (Join-Path $runFolder 'PatchesInventory.csv') -Delimiter $cfg.CsvDelimiter
        Export-PMCsv -InputObject $summary3  -Path (Join-Path $runFolder 'PatchesSummary.csv') -Delimiter $cfg.CsvDelimiter

        # --- Conformité (partie 4) ---------------------------------------------------
        Write-Progress -Activity 'Audit des correctifs' -Status 'Contrôle de conformité...' -PercentComplete 75
        $compliance = @(Test-PMCompliance -HostResult $hosts -RequiredPatch $required -ControlDate $start)
        foreach ($c in $compliance) {
            switch ($c.Etat) {
                'CONFORME'     { Write-PMLog $c.Poste, 'Conforme' }
                'NON CONFORME' { Write-PMLog -Level WARN -Message $c.Poste, 'Non conforme', $c.ListeKBManquantes }
            }
        }
        Export-PMCsv -InputObject $compliance -Path (Join-Path $runFolder 'ComplianceReport.csv') -Delimiter $cfg.CsvDelimiter
        $rate = Get-PMComplianceRate -Compliance $compliance

        # --- Rapport (partie 6) ------------------------------------------------------
        Write-Progress -Activity 'Audit des correctifs' -Status 'Génération du rapport...' -PercentComplete 90
        $report       = @(New-PMSecurityReport -Inventory $inventory -Compliance $compliance)
        $parcSummary  = Get-PMParcSummary -Report $report
        $interventions = @(Get-PMInterventionList -Report $report)
        $attention    = @(Get-PMAttentionPoint -Inventory $inventory)
        $csvReport    = Join-Path $runFolder 'SecurityReport.csv'
        $htmlReport   = Join-Path $runFolder 'SecurityReport.html'
        Export-PMCsv -InputObject $report -Path $csvReport -Delimiter $cfg.CsvDelimiter
        Export-PMCsv -InputObject $interventions -Path (Join-Path $runFolder 'Interventions.csv') -Delimiter $cfg.CsvDelimiter
        Export-PMCsv -InputObject @($parcSummary) -Path (Join-Path $runFolder 'ParcSummary.csv') -Delimiter $cfg.CsvDelimiter

        # BONUS : comparaison avec l'audit précédent et historique de la conformité
        $trend = Get-PMTrend -Report $report -RunFolder $runFolder
        if ($trend) {
            foreach ($g in $trend.Regressions) { Write-PMLog -Level WARN -Message $g.Poste, "Régression ($($g.EtatPrecedent) -> $($g.EtatActuel))" }
            foreach ($f in $trend.Fixed) { Write-PMLog $f.Poste, "Corrigé ($($f.EtatPrecedent) -> CONFORME)" }
            Export-PMCsv -InputObject $trend.Changes -Path (Join-Path $runFolder 'Evolution.csv') -Delimiter $cfg.CsvDelimiter
        }
        Add-PMHistory -Summary $parcSummary -RunFolder $runFolder
        $trendSvg = ConvertTo-PMTrendSvg -History @(Get-PMHistory)

        Export-PMHtmlReport -Report $report -Summary $parcSummary -Intervention $interventions -AttentionPoint $attention -RequiredPatch $required -Trend $trend -TrendSvg $trendSvg -Path $htmlReport | Out-Null
        Write-PMLog "Rapport généré ($runFolder)"

        # --- Notification (partie 7) -------------------------------------------------
        $notified = $null
        if ($NoNotification) {
            Write-PMLog 'Notification ignorée (option -NoNotification)'
        } else {
            $attachments = @($htmlReport)
            if ($cfg.Notification.AttachCsv) { $attachments += $csvReport }
            $notified = Send-PMNotification -Report $report -Attachment $attachments -RunFolder $runFolder -Trend $trend
        }

        Write-PMIntegrityManifest -RunFolder $runFolder | Out-Null
        Remove-PMExpiredRun
        Write-Progress -Activity 'Audit des correctifs' -Completed

        [pscustomobject]@{
            RunFolder      = $runFolder
            HtmlReport     = $htmlReport
            Hosts          = $hosts
            Inventory      = $inventory
            Patches        = $patches
            PatchSummary   = $summary3
            RequiredPatch  = $required
            Compliance     = $compliance
            ComplianceRate = $rate
            Report         = $report
            Summary        = $parcSummary
            Interventions  = $interventions
            Trend          = $trend
            AttentionPoint = $attention
            Notified       = $notified
            Duration       = (Get-Date) - $start
        }
    } catch {
        Write-PMLog -Level ERROR -Message "Audit interrompu : $($_.Exception.Message)"
        throw
    } finally {
        Write-PMLog "Fin de l'audit"
    }
}
