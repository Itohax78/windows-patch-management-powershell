function Invoke-PMRemediation {
    <#
    .SYNOPSIS
        BONUS (partie 5) - Remédiation : recherche et installe les correctifs manquants
        sur les postes non conformes.

    .DESCRIPTION
        L'API Windows Update refuse de télécharger/installer des mises à jour depuis une
        session WinRM (erreur 0x80070005, accès refusé). Le contournement standard consiste à :
          1. déposer sur le poste un petit script "worker" ;
          2. le faire exécuter par une TÂCHE PLANIFIÉE TEMPORAIRE sous le compte SYSTEM ;
          3. attendre son résultat (fichier JSON), puis supprimer la tâche et le script.

        Modes :
          -ScanOnly  : recherche seulement les mises à jour applicables (aucune modification) ;
          -KB        : n'installe que les KB indiqués (ceux de la politique manquants) ;
          sinon      : installe les mises à jour de sécurité et critiques disponibles.
        Le redémarrage n'est JAMAIS automatique, sauf avec -AllowReboot (préavis de 5 min).

        Sécurité : action d'administration (modification des postes). Elle demande une
        confirmation (ConfirmImpact High), supporte -WhatIf, est journalisée, et nécessite le
        point de terminaison administrateur : le rôle JEA d'audit (lecture seule) ne peut pas
        l'utiliser. C'est la séparation des rôles « auditer » / « corriger ».

    .OUTPUTS
        Un objet par poste : Poste, Mode, Trouvees, Installees, Echecs, RedemarrageRequis, Detail.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [object[]] $Computer,
        [ValidatePattern('^(?i)KB\d{6,8}$')] [string[]] $KB = @(),
        [switch] $ScanOnly,
        [switch] $AllowReboot,
        [ValidateRange(1, 240)] [int] $TimeoutMinutes = 60,
        [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    $cfg = Get-PMConfiguration
    $mode = if ($ScanOnly) { 'Recherche' } elseif ($KB.Count) { 'Installation ciblée' } else { 'Installation sécurité/critiques' }

    # Code exécuté SUR LE POSTE (dans la session WinRM) : prépare et pilote la tâche SYSTEM
    $remoteBlock = {
        param([string[]] $KbList, [bool] $Scan, [bool] $Reboot, [int] $Timeout)
        $ErrorActionPreference = 'Stop'
        $dir = Join-Path $env:ProgramData 'PatchManager\Remediation'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        $resultFile = Join-Path $dir 'result.json'
        Remove-Item -Path $resultFile -ErrorAction SilentlyContinue

        # Paramètres transmis au worker par fichier (pas d'argument en ligne de commande)
        @{ KB = @($KbList | ForEach-Object { $_.ToUpperInvariant().Replace('KB', '') }); Scan = $Scan } |
            ConvertTo-Json | Set-Content -Path (Join-Path $dir 'params.json') -Encoding UTF8

        # Worker exécuté par la tâche planifiée sous SYSTEM (seul contexte autorisé par l'API WU)
        $worker = @'
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:ProgramData 'PatchManager\Remediation'
$p = Get-Content (Join-Path $dir 'params.json') -Raw | ConvertFrom-Json
$out = [ordered]@{ Trouvees = 0; Installees = 0; Echecs = 0; RedemarrageRequis = $false; Details = @(); Erreur = $null }
try {
    $session  = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $search   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    # Classifications retenues par défaut : Mises à jour de sécurité et Mises à jour critiques
    $classes  = @('0fa1201d-4330-4fa8-8ae9-b877473b6441', 'e6cf1350-c01b-414d-a61f-263d14d133b4')
    $selected = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    foreach ($u in $search.Updates) {
        $kbs = @($u.KBArticleIDs)
        $keep = if (@($p.KB).Count) { @($kbs | Where-Object { $p.KB -contains $_ }).Count -gt 0 }
                else { @($u.Categories | Where-Object { $classes -contains $_.CategoryID }).Count -gt 0 }
        if ($keep) {
            if (-not $p.Scan -and -not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$selected.Add($u)
            $out.Details += ('KB' + ($kbs -join ',KB') + ' - ' + $u.Title)
        }
    }
    $out.Trouvees = $selected.Count
    # Aucune KB demandée trouvée : on liste ce que Windows Update propose réellement
    # (souvent une mise à jour cumulative plus récente qui remplace la KB exigée)
    if ($selected.Count -eq 0 -and $search.Updates.Count -gt 0) {
        $out.Details += 'KB demandée(s) non proposée(s) ; disponibles : ' + (@($search.Updates | ForEach-Object { 'KB' + (@($_.KBArticleIDs) -join ',KB') + ' - ' + $_.Title }) -join ' ; ')
    } elseif ($search.Updates.Count -eq 0) {
        $out.Details += 'Windows Update ne propose aucune mise à jour pour ce poste'
    }
    if (-not $p.Scan -and $selected.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $selected; [void]$dl.Download()
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $selected
        $res = $inst.Install()
        for ($i = 0; $i -lt $selected.Count; $i++) {
            # 2 = réussi, 3 = réussi avec erreurs
            if ($res.GetUpdateResult($i).ResultCode -in 2, 3) { $out.Installees++ } else { $out.Echecs++ }
        }
        $out.RedemarrageRequis = [bool]$res.RebootRequired
    }
} catch {
    # Codes Windows Update fréquents traduits en cause probable
    $hr = '0x{0:X8}' -f $_.Exception.HResult
    $cause = switch ($hr) {
        '0x80240438' { 'serveur Windows Update injoignable : vérifier l''accès Internet du poste et que les mises à jour ne sont pas suspendues (Paramètres > Windows Update)' }
        '0x8024402C' { 'nom du serveur Windows Update non résolu (DNS / proxy)' }
        '0x80072EE2' { 'délai dépassé en contactant Windows Update (réseau)' }
        '0x80240016' { 'une autre installation Windows Update est déjà en cours sur le poste' }
        '0x8024001E' { 'service Windows Update en cours d''arrêt (redémarrage en attente ?)' }
        default      { $null }
    }
    $out.Erreur = if ($cause) { "$hr - $cause" } else { "$hr - $($_.Exception.Message)" }
}
$out | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $dir 'result.json') -Encoding UTF8
'@
        $workerPath = Join-Path $dir 'worker.ps1'
        Set-Content -Path $workerPath -Value $worker -Encoding UTF8

        # Tâche planifiée temporaire, exécutée immédiatement sous SYSTEM
        $taskName = 'PatchManager-Remediation'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$workerPath`""
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $Timeout) -AllowStartIfOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName $taskName
            # Attente du fichier résultat (ou du délai maximal)
            $deadline = (Get-Date).AddMinutes($Timeout)
            while (-not (Test-Path $resultFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
            if (-not (Test-Path $resultFile)) { throw "Délai dépassé ($Timeout min) sans résultat de Windows Update" }
            $r = Get-Content -Path $resultFile -Raw | ConvertFrom-Json
        } finally {
            # Nettoyage systématique : aucune tâche ni script ne reste sur le poste
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -Path $workerPath, (Join-Path $dir 'params.json') -ErrorAction SilentlyContinue
        }
        if ($Reboot -and $r.RedemarrageRequis) {
            shutdown.exe /r /t 300 /c "PatchManager : redémarrage pour finaliser les mises à jour" | Out-Null
        }
        [pscustomobject]@{
            Trouvees = $r.Trouvees; Installees = $r.Installees; Echecs = $r.Echecs
            RedemarrageRequis = $r.RedemarrageRequis; Details = (@($r.Details) -join ' | '); Erreur = $r.Erreur
        }
    }

    $checks = @(Test-PMComputer -Computer $Computer)
    foreach ($c in $checks) {
        $row = [ordered]@{ Poste = $c.Name; AdresseIP = $c.IPAddress; Mode = $mode; Trouvees = $null; Installees = $null; Echecs = $null; RedemarrageRequis = $null; Detail = $null }

        # Un poste injoignable est signalé mais n'arrête pas les autres
        if (-not $c.Accessible) {
            $row.Detail = "Ignoré : $($c.Detail)"
            Write-PMLog -Level WARN -Message $c.Name, 'Remédiation impossible', $c.Detail
            [pscustomobject]$row; continue
        }
        $what = if ($ScanOnly) { 'Recherche des mises à jour applicables' } elseif ($KB.Count) { "Installation de $($KB -join ', ')" } else { 'Installation des mises à jour de sécurité et critiques' }
        if (-not $PSCmdlet.ShouldProcess("$($c.Name) ($($c.IPAddress))", $what)) {
            $row.Detail = 'Annulé (WhatIf ou refus de confirmation)'
            [pscustomobject]$row; continue
        }

        Write-PMLog $c.Name, "Remédiation démarrée ($mode)", ($KB -join ',')
        try {
            $arguments = @(@($KB), [bool]$ScanOnly, [bool]$AllowReboot, $TimeoutMinutes)
            if ($c.IsLocal) {
                $r = & $remoteBlock @arguments
            } else {
                # Point de terminaison ADMINISTRATEUR obligatoire (le rôle JEA d'audit est en lecture seule)
                $p = @{ ComputerName = $c.Target; ScriptBlock = $remoteBlock; ArgumentList = $arguments; ErrorAction = 'Stop' }
                if ($cfg.UseSSL) { $p.UseSSL = $true; $p.Port = $cfg.HttpsPort }
                if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $p.Credential = $Credential }
                $r = Invoke-Command @p
            }
            $row.Trouvees = $r.Trouvees; $row.Installees = $r.Installees; $row.Echecs = $r.Echecs
            $row.RedemarrageRequis = $r.RedemarrageRequis
            $row.Detail = if ($r.Erreur) { "Erreur Windows Update : $($r.Erreur)" } else { $r.Details }
            if ($r.Erreur) { Write-PMLog -Level ERROR -Message $c.Name, 'Remédiation en échec', $r.Erreur }
            else { Write-PMLog $c.Name, "Remédiation terminée : $($r.Trouvees) trouvée(s), $($r.Installees) installée(s), $($r.Echecs) échec(s)", "Redémarrage requis : $($r.RedemarrageRequis)" }
        } catch {
            $row.Detail = "Échec : $($_.Exception.Message)"
            Write-PMLog -Level ERROR -Message $c.Name, 'Remédiation en échec', $_.Exception.Message
        }
        [pscustomobject]$row
    }
}
