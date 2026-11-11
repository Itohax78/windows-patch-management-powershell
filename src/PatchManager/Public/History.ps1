function Add-PMHistory {
    <#
    .SYNOPSIS
        BONUS - Ajoute le résultat de l'audit à l'historique Output\History.csv.
    .DESCRIPTION
        Une ligne par audit (date, compteurs, taux). Cet historique permet de suivre
        l'évolution de la conformité dans le temps et alimente le graphique du rapport HTML.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)] [string] $RunFolder,
        [string] $OutputRoot = (Get-PMConfiguration).OutputRoot
    )
    $path = Join-Path -Path $OutputRoot -ChildPath 'History.csv'
    $row = [pscustomobject][ordered]@{
        Date                  = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')
        Audit                 = Split-Path -Path $RunFolder -Leaf
        NbPostes              = $Summary.NbPostes
        NbAccessibles         = $Summary.NbAccessibles
        NbInaccessibles       = $Summary.NbInaccessibles
        NbConformes           = $Summary.NbConformes
        NbNonConformes        = $Summary.NbNonConformes
        NbCorrectifsManquants = $Summary.NbCorrectifsManquants
        # Taux stocké avec un point décimal pour rester lisible quelle que soit la langue
        TauxConformite        = if ($null -eq $Summary.TauxConformite) { '' } else { ([double]$Summary.TauxConformite).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    }
    $delimiter = (Get-PMConfiguration).CsvDelimiter
    if (Test-Path -Path $path) {
        $row | Export-Csv -Path $path -Delimiter $delimiter -NoTypeInformation -Encoding UTF8 -Append
    } else {
        $row | Export-Csv -Path $path -Delimiter $delimiter -NoTypeInformation -Encoding UTF8
    }
}

function Get-PMHistory {
    <#
    .SYNOPSIS
        BONUS - Lit l'historique des audits (les N derniers).
    #>
    [CmdletBinding()]
    param(
        [string] $OutputRoot = (Get-PMConfiguration).OutputRoot,
        [int] $Last = 15
    )
    $path = Join-Path -Path $OutputRoot -ChildPath 'History.csv'
    if (-not (Test-Path -Path $path)) { return @() }
    @(Import-Csv -Path $path -Delimiter (Get-PMConfiguration).CsvDelimiter | Select-Object -Last $Last)
}

function Get-PMTrend {
    <#
    .SYNOPSIS
        BONUS - Compare l'audit courant avec l'audit précédent.
    .DESCRIPTION
        Pour chaque poste : état précédent, état actuel et évolution :
          - Régression : le poste était conforme (ou absent) et ne l'est plus ;
          - Corrigé    : le poste était non conforme / inaccessible et est désormais conforme ;
          - Inchangé   : même état qu'au contrôle précédent ;
          - Nouveau    : poste absent du contrôle précédent.
        Les régressions sont signalées en priorité dans le rapport et la notification.
    .OUTPUTS
        { PreviousAudit ; PreviousRate ; CurrentRate ; Delta ; Changes ; Regressions ; Fixed }
        ou $null s'il n'existe pas d'audit précédent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Report,
        [Parameter(Mandatory)] [string] $RunFolder,
        [string] $OutputRoot = (Get-PMConfiguration).OutputRoot
    )
    # Dossier d'audit précédent : le plus récent avant l'audit courant qui contient un rapport
    $current = Split-Path -Path $RunFolder -Leaf
    $previous = Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and $_.Name -lt $current -and (Test-Path (Join-Path $_.FullName 'SecurityReport.csv')) } |
        Sort-Object -Property Name | Select-Object -Last 1
    if (-not $previous) { return $null }

    $old = @(Import-Csv -Path (Join-Path $previous.FullName 'SecurityReport.csv') -Delimiter (Get-PMConfiguration).CsvDelimiter)
    $oldByName = @{}
    foreach ($o in $old) { $oldByName[$o.Poste] = $o.Conformite }

    $changes = foreach ($r in $Report) {
        $before = $oldByName[$r.Poste]
        $evolution = if (-not $before) { 'Nouveau' }
                     elseif ($before -eq $r.Conformite) { 'Inchangé' }
                     elseif ($r.Conformite -eq 'CONFORME') { 'Corrigé' }
                     elseif ($before -eq 'CONFORME') { 'Régression' }
                     else { 'Inchangé' }   # NON CONFORME <-> INACCESSIBLE : toujours en anomalie
        [pscustomobject][ordered]@{
            Poste         = $r.Poste
            EtatPrecedent = if ($before) { $before } else { '—' }
            EtatActuel    = $r.Conformite
            Evolution     = $evolution
        }
    }

    # Taux précédent recalculé à partir du rapport précédent (même règle : sans les inaccessibles)
    $prevRate = Get-PMComplianceRate -Compliance @($old | ForEach-Object { [pscustomobject]@{ Etat = $_.Conformite } })
    $curRate  = Get-PMComplianceRate -Compliance @($Report | ForEach-Object { [pscustomobject]@{ Etat = $_.Conformite } })
    [pscustomobject]@{
        PreviousAudit = $previous.Name
        PreviousRate  = $prevRate
        CurrentRate   = $curRate
        Delta         = if ($null -ne $prevRate -and $null -ne $curRate) { [math]::Round($curRate - $prevRate, 1) } else { $null }
        Changes       = @($changes)
        Regressions   = @($changes | Where-Object Evolution -eq 'Régression')
        Fixed         = @($changes | Where-Object Evolution -eq 'Corrigé')
    }
}

function ConvertTo-PMTrendSvg {
    <#
    .SYNOPSIS
        BONUS - Graphique SVG (intégré au rapport HTML) de l'évolution du taux de conformité.
    .DESCRIPTION
        SVG généré directement en PowerShell : aucune bibliothèque ni ressource externe,
        le rapport reste un fichier unique consultable hors ligne.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $History)

    $points = @($History | Where-Object { $_.TauxConformite -ne '' -and $null -ne $_.TauxConformite })
    if ($points.Count -lt 2) { return '' }

    $w = 640; $h = 200; $left = 40; $right = 20; $top = 15; $bottom = 35
    $plotW = $w - $left - $right; $plotH = $h - $top - $bottom
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox=""0 0 $w $h"" width=""100%"" style=""max-width:${w}px"" role=""img"" aria-label=""Évolution du taux de conformité"">")

    # Grille horizontale 0 / 50 / 100 %
    foreach ($pct in 0, 50, 100) {
        $y = $top + $plotH - ($pct / 100 * $plotH)
        [void]$sb.Append("<line x1=""$left"" x2=""$($w - $right)"" y1=""$y"" y2=""$y"" stroke=""#e4e7eb""/>")
        [void]$sb.Append("<text x=""$($left - 6)"" y=""$($y + 4)"" font-size=""11"" text-anchor=""end"" fill=""#616e7c"">$pct %</text>")
    }

    # Courbe + points (une abscisse par audit)
    $coords = for ($i = 0; $i -lt $points.Count; $i++) {
        $x = $left + ($i * $plotW / ($points.Count - 1))
        $rate = [double]::Parse([string]$points[$i].TauxConformite, $inv)
        $y = $top + $plotH - ($rate / 100 * $plotH)
        [pscustomobject]@{ X = [math]::Round($x, 1); Y = [math]::Round($y, 1); Rate = $rate; Label = ([string]$points[$i].Date).Substring(0, 5) }
    }
    $path = ($coords | ForEach-Object { '{0},{1}' -f $_.X.ToString($inv), $_.Y.ToString($inv) }) -join ' '
    [void]$sb.Append("<polyline points=""$path"" fill=""none"" stroke=""#1a5fb4"" stroke-width=""2.5""/>")
    foreach ($c in $coords) {
        $cx = $c.X.ToString($inv); $cy = $c.Y.ToString($inv)
        [void]$sb.Append("<circle cx=""$cx"" cy=""$cy"" r=""4"" fill=""#1a5fb4""><title>$(ConvertTo-PMHtmlText $c.Label) : $($c.Rate) %</title></circle>")
        [void]$sb.Append("<text x=""$cx"" y=""$($h - 12)"" font-size=""10"" text-anchor=""middle"" fill=""#616e7c"">$(ConvertTo-PMHtmlText $c.Label)</text>")
    }
    [void]$sb.Append('</svg>')
    $sb.ToString()
}
