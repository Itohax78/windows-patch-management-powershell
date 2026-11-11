function New-PMSecurityReport {
    <#
    .SYNOPSIS
        Partie 6 : fusionne inventaire et conformité en une ligne de rapport par poste.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Construit des objets en mémoire, ne modifie pas le système')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Inventory,
        [Parameter(Mandatory)] [object[]] $Compliance
    )
    $byName = @{}
    foreach ($c in $Compliance) { $byName[$c.Poste] = $c }

    foreach ($i in $Inventory) {
        $c = $byName[$i.Poste]
        [pscustomobject][ordered]@{
            Poste             = $i.Poste
            AdresseIP         = $i.AdresseIP
            Accessibilite     = $i.Etat
            Windows           = $i.Windows
            Build             = $i.Build
            DernierDemarrage  = $i.DernierDemarrage
            WindowsUpdate     = $i.WindowsUpdate
            KBRequises        = if ($c) { $c.KBRequises } else { $null }
            KBManquantes      = if ($c) { $c.KBManquantes } else { $null }
            ListeKBManquantes = if ($c) { $c.ListeKBManquantes } else { $null }
            Conformite        = if ($c) { $c.Etat } else { 'INACCESSIBLE' }
            DateControle      = if ($c) { $c.DateControle } else { $i.DateControle }
            Erreur            = $i.Erreur
        }
    }
}

function Get-PMParcSummary {
    <#
    .SYNOPSIS
        Partie 6 : synthèse globale du parc.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Report)

    $accessible   = @($Report | Where-Object { $_.Accessibilite -eq 'Accessible' })
    $conformes    = @($Report | Where-Object { $_.Conformite -eq 'CONFORME' })
    $nonConformes = @($Report | Where-Object { $_.Conformite -eq 'NON CONFORME' })
    $missing = 0
    foreach ($r in $nonConformes) { $missing += [int]$r.KBManquantes }
    $rate = Get-PMComplianceRate -Compliance @($Report | ForEach-Object { [pscustomobject]@{ Etat = $_.Conformite } })

    [pscustomobject][ordered]@{
        NbPostes                = @($Report).Count
        NbAccessibles           = $accessible.Count
        NbInaccessibles         = @($Report).Count - $accessible.Count
        NbConformes             = $conformes.Count
        NbNonConformes          = $nonConformes.Count
        NbCorrectifsManquants   = $missing
        TauxConformite          = $rate
        TauxConformiteTexte     = if ($null -eq $rate) { 'N/A (aucun poste évalué)' } else { ('{0} %' -f $rate) }
        DateControle            = Get-Date
    }
}

function Get-PMInterventionList {
    <#
    .SYNOPSIS
        Postes nécessitant une intervention (NON CONFORME ou INACCESSIBLE), avec l'action
        recommandée pour l'administrateur.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Report)
    foreach ($r in ($Report | Where-Object { $_.Conformite -ne 'CONFORME' })) {
        $action = if ($r.Conformite -eq 'NON CONFORME') {
            "Installer : $($r.ListeKBManquantes)"
        } else {
            'Vérifier que le poste est allumé, connecté, et que WinRM / le pare-feu autorisent le poste d''administration'
        }
        [pscustomobject][ordered]@{
            Poste             = $r.Poste
            AdresseIP         = $r.AdresseIP
            Conformite        = $r.Conformite
            ListeKBManquantes = $r.ListeKBManquantes
            Motif             = if ($r.Conformite -eq 'INACCESSIBLE') { $r.Erreur } else { "$($r.KBManquantes) correctif(s) manquant(s)" }
            ActionRecommandee = $action
        }
    }
}

function Get-PMAttentionPoint {
    <#
    .SYNOPSIS
        Points d'attention complémentaires (hors politique de conformité) : service
        Windows Update arrêté/désactivé, redémarrage en attente, disque presque plein,
        poste non redémarré depuis longtemps, erreurs partielles de collecte.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Inventory)
    $cfg = Get-PMConfiguration
    foreach ($i in ($Inventory | Where-Object { $_.Etat -eq 'Accessible' })) {
        if ($i.WindowsUpdateDemarrage -eq 'Disabled') {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Élevée'; Constat = 'Service Windows Update désactivé : le poste ne recevra plus aucun correctif' }
        } elseif ($i.WindowsUpdate -and $i.WindowsUpdate -ne 'Running') {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Info'; Constat = "Service Windows Update à l'état $($i.WindowsUpdate) (démarrage $($i.WindowsUpdateDemarrage)) : normal s'il est en démarrage manuel/déclenché" }
        }
        if ($i.RedemarrageEnAttente -eq $true) {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Moyenne'; Constat = 'Redémarrage en attente : des correctifs installés ne sont pas encore actifs' }
        }
        if ($null -ne $i.DisqueLibre_Pct -and $i.DisqueLibre_Pct -lt $cfg.MinFreeDiskPercent) {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Moyenne'; Constat = "Disque système presque plein ($($i.DisqueLibre_Pct) % libre) : risque d'échec des mises à jour" }
        }
        if ($i.DernierDemarrage -and ((Get-Date) - [datetime]$i.DernierDemarrage).TotalDays -gt $cfg.MaxUptimeDays) {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Faible'; Constat = "Aucun redémarrage depuis plus de $($cfg.MaxUptimeDays) jours" }
        }
        if ($i.Erreur) {
            [pscustomobject]@{ Poste = $i.Poste; Gravite = 'Info'; Constat = "Collecte partielle : $($i.Erreur)" }
        }
    }
}

function Export-PMHtmlReport {
    <#
    .SYNOPSIS
        Partie 6 : génère la version HTML (autonome, sans ressource externe) du rapport.
    .DESCRIPTION
        Toutes les valeurs issues des postes sont encodées en HTML : un nom de modèle ou
        une description de correctif malveillant ne peut pas injecter de script dans le
        navigateur de l'administrateur (XSS).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Report,
        [Parameter(Mandatory)] $Summary,
        [AllowEmptyCollection()] [object[]] $Intervention = @(),
        [AllowEmptyCollection()] [object[]] $AttentionPoint = @(),
        [AllowEmptyCollection()] [object[]] $RequiredPatch = @(),
        # BONUS : comparaison avec l'audit précédent (Get-PMTrend) et graphique SVG de l'historique
        $Trend,
        [string] $TrendSvg,
        [Parameter(Mandatory)] [string] $Path
    )

    $e = { param($v) ConvertTo-PMHtmlText $v }
    $badge = {
        param($state)
        $cls = switch ($state) { 'CONFORME' { 'ok' } 'NON CONFORME' { 'ko' } 'Accessible' { 'ok' } default { 'na' } }
        "<span class=""badge $cls"">$(ConvertTo-PMHtmlText $state)</span>"
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rapport de sécurité - Patch Management</title>
<style>
:root { --bg:#f5f7fa; --card:#fff; --text:#1f2933; --muted:#616e7c; --ok:#1e8e3e; --ko:#c5221f; --na:#7b8794; --accent:#1a5fb4; --line:#e4e7eb; }
* { box-sizing:border-box; }
body { margin:0; font-family:"Segoe UI",Arial,sans-serif; background:var(--bg); color:var(--text); font-size:14px; }
header { background:var(--accent); color:#fff; padding:24px 32px; }
header h1 { margin:0 0 4px; font-size:22px; }
header p { margin:0; opacity:.9; }
main { padding:24px 32px; max-width:1400px; margin:auto; }
h2 { font-size:17px; border-bottom:2px solid var(--accent); padding-bottom:6px; margin-top:32px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; }
.card { background:var(--card); border-radius:8px; padding:14px 16px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
.card .v { font-size:26px; font-weight:600; }
.card .l { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.card.ok .v { color:var(--ok); } .card.ko .v { color:var(--ko); } .card.na .v { color:var(--na); }
.bar { height:10px; background:#e4e7eb; border-radius:5px; overflow:hidden; margin-top:8px; }
.bar span { display:block; height:100%; background:var(--ok); }
table { width:100%; border-collapse:collapse; background:var(--card); box-shadow:0 1px 3px rgba(0,0,0,.08); border-radius:8px; overflow:hidden; }
th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
th { background:#eef2f7; font-size:12px; text-transform:uppercase; letter-spacing:.03em; color:var(--muted); }
tr:last-child td { border-bottom:none; }
.badge { display:inline-block; padding:2px 8px; border-radius:10px; font-size:12px; font-weight:600; color:#fff; white-space:nowrap; }
.badge.ok { background:var(--ok); } .badge.ko { background:var(--ko); } .badge.na { background:var(--na); }
.kb { font-family:Consolas,monospace; color:var(--ko); }
.muted { color:var(--muted); }
.empty { padding:14px; background:var(--card); border-radius:8px; color:var(--ok); }
footer { color:var(--muted); font-size:12px; padding:16px 32px 32px; text-align:center; }
@media print { header { background:#fff; color:#000; border-bottom:2px solid #000; } .card, table { box-shadow:none; border:1px solid #ccc; } }
</style>
</head>
<body>
<header>
  <h1>Rapport de sécurité &ndash; Gestion des mises à jour Windows</h1>
  <p>Contrôle du $(& $e (Format-PMDate $Summary.DateControle 'dd/MM/yyyy à HH:mm:ss')) &middot; poste d'administration : $(& $e ([Environment]::MachineName)) &middot; opérateur : $(& $e ([Environment]::UserName))</p>
</header>
<main>
<h2>Synthèse globale du parc</h2>
<div class="cards">
  <div class="card"><div class="v">$($Summary.NbPostes)</div><div class="l">Postes contrôlés</div></div>
  <div class="card ok"><div class="v">$($Summary.NbAccessibles)</div><div class="l">Accessibles</div></div>
  <div class="card na"><div class="v">$($Summary.NbInaccessibles)</div><div class="l">Inaccessibles</div></div>
  <div class="card ok"><div class="v">$($Summary.NbConformes)</div><div class="l">Conformes</div></div>
  <div class="card ko"><div class="v">$($Summary.NbNonConformes)</div><div class="l">Non conformes</div></div>
  <div class="card ko"><div class="v">$($Summary.NbCorrectifsManquants)</div><div class="l">Correctifs manquants</div></div>
  <div class="card"><div class="v">$(& $e $Summary.TauxConformiteTexte)</div><div class="l">Taux de conformité*</div>
    <div class="bar"><span style="width:$([int]([double]$Summary.TauxConformite))%"></span></div></div>
</div>
<p class="muted">* Taux calculé sur les postes évalués uniquement (conformes / (conformes + non conformes)), sans les postes inaccessibles.</p>
"@)

    # --- BONUS : évolution depuis l'audit précédent ----------------------------------------
    if ($Trend -or $TrendSvg) {
        [void]$sb.Append("<h2>Évolution de la conformité</h2>`n")
        if ($Trend) {
            $deltaTxt = if ($null -eq $Trend.Delta) { 'N/A' } elseif ($Trend.Delta -eq 0) { 'Taux stable' } elseif ($Trend.Delta -gt 0) { "+$($Trend.Delta) points" } else { "$($Trend.Delta) points" }
            # Un taux stable n'est pas « bon » s'il y a des régressions (ex. poste devenu
            # inaccessible : il sort du calcul du taux mais reste une anomalie)
            $deltaCls = if (($null -ne $Trend.Delta -and $Trend.Delta -lt 0) -or @($Trend.Regressions).Count) { 'ko' } else { 'ok' }
            [void]$sb.Append("<div class=""cards""><div class=""card $deltaCls""><div class=""v"">$(& $e $deltaTxt)</div><div class=""l"">Depuis l'audit $(& $e $Trend.PreviousAudit)</div></div>")
            [void]$sb.Append("<div class=""card ko""><div class=""v"">$(@($Trend.Regressions).Count)</div><div class=""l"">Régressions</div></div>")
            [void]$sb.Append("<div class=""card ok""><div class=""v"">$(@($Trend.Fixed).Count)</div><div class=""l"">Postes corrigés</div></div></div>")
            $moved = @($Trend.Changes | Where-Object Evolution -ne 'Inchangé')
            if ($moved.Count) {
                [void]$sb.Append('<table style="margin-top:12px"><tr><th>Poste</th><th>État précédent</th><th>État actuel</th><th>Évolution</th></tr>')
                foreach ($m in $moved) {
                    [void]$sb.Append("<tr><td><b>$(& $e $m.Poste)</b></td><td>$(& $badge $m.EtatPrecedent)</td><td>$(& $badge $m.EtatActuel)</td><td>$(& $e $m.Evolution)</td></tr>")
                }
                [void]$sb.Append('</table>')
            }
        }
        if ($TrendSvg) { [void]$sb.Append("<div class=""card"" style=""margin-top:12px"">$TrendSvg</div>") }
    }

    # --- Postes nécessitant une intervention ----------------------------------------------
    [void]$sb.Append("<h2>Postes nécessitant une intervention ($(@($Intervention).Count))</h2>`n")
    if (@($Intervention).Count -eq 0) {
        [void]$sb.Append('<div class="empty">Aucune intervention nécessaire : tous les postes sont accessibles et conformes.</div>')
    } else {
        [void]$sb.Append('<table><tr><th>Poste</th><th>Adresse IP</th><th>État</th><th>KB manquantes</th><th>Motif</th><th>Action recommandée</th></tr>')
        foreach ($i in $Intervention) {
            [void]$sb.Append("<tr><td><b>$(& $e $i.Poste)</b></td><td>$(& $e $i.AdresseIP)</td><td>$(& $badge $i.Conformite)</td><td class=""kb"">$(& $e $i.ListeKBManquantes)</td><td>$(& $e $i.Motif)</td><td>$(& $e $i.ActionRecommandee)</td></tr>")
        }
        [void]$sb.Append('</table>')
    }

    # --- Détail par poste ---------------------------------------------------------------
    [void]$sb.Append("<h2>Détail par poste</h2>`n<table><tr><th>Poste</th><th>Adresse IP</th><th>Accessibilité</th><th>Windows</th><th>Dernier démarrage</th><th>Windows Update</th><th>KB requises</th><th>KB manquantes</th><th>Liste des KB manquantes</th><th>Conformité</th><th>Date du contrôle</th></tr>")
    foreach ($r in $Report) {
        $win = if ($r.Windows) { "$(& $e $r.Windows)<br><span class=""muted"">build $(& $e $r.Build)</span>" } else { '—' }
        [void]$sb.Append("<tr><td><b>$(& $e $r.Poste)</b></td><td>$(& $e $r.AdresseIP)</td><td>$(& $badge $r.Accessibilite)</td><td>$win</td><td>$(& $e (Format-PMDate $r.DernierDemarrage))</td><td>$(& $e $(if ($r.WindowsUpdate) { $r.WindowsUpdate } else { '—' }))</td><td>$(& $e $r.KBRequises)</td><td>$(& $e $r.KBManquantes)</td><td class=""kb"">$(& $e $r.ListeKBManquantes)</td><td>$(& $badge $r.Conformite)</td><td>$(& $e (Format-PMDate $r.DateControle 'dd/MM/yyyy HH:mm:ss'))</td></tr>")
    }
    [void]$sb.Append('</table>')

    # --- Points d'attention -------------------------------------------------------------
    if (@($AttentionPoint).Count -gt 0) {
        [void]$sb.Append("<h2>Points d'attention complémentaires</h2>`n<table><tr><th>Poste</th><th>Gravité</th><th>Constat</th></tr>")
        foreach ($a in $AttentionPoint) {
            [void]$sb.Append("<tr><td>$(& $e $a.Poste)</td><td>$(& $e $a.Gravite)</td><td>$(& $e $a.Constat)</td></tr>")
        }
        [void]$sb.Append('</table>')
    }

    # --- Politique appliquée ------------------------------------------------------------
    if (@($RequiredPatch).Count -gt 0) {
        [void]$sb.Append("<h2>Politique de correctifs appliquée ($(@($RequiredPatch).Count) KB)</h2>`n<table><tr><th>KB</th><th>Description</th><th>Postes ciblés</th></tr>")
        foreach ($p in $RequiredPatch) {
            [void]$sb.Append("<tr><td class=""kb"">$(& $e $p.KB)</td><td>$(& $e $p.Description)</td><td>$(& $e $p.Target)</td></tr>")
        }
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append(@"
</main>
<footer>Rapport généré automatiquement par PatchManager (PowerShell) &middot; document interne &ndash; diffusion restreinte aux administrateurs</footer>
</body>
</html>
"@)

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return (Get-Item -Path $Path)
}
