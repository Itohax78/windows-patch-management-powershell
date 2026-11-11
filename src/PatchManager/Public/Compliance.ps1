function Read-PMRequiredPatch {
    <#
    .SYNOPSIS
        Partie 4 : lit la politique de correctifs obligatoires (required-patches.txt).
    .DESCRIPTION
        Format d'une ligne : KB;Description;Cible
          - Cible (optionnelle) : motif avec jokers comparé à "<Windows> <Build>" du poste.
            Permet d'exiger un correctif uniquement sur les versions concernées (un
            correctif Windows 10 n'existe pas pour Windows 11, et inversement).
        Les KB invalides ou en double sont signalés et ignorés.
    .OUTPUTS
        Objets { KB ; Description ; Target }
    #>
    [CmdletBinding()]
    param([string] $Path = (Get-PMConfiguration).RequiredPatchesFile)

    if (-not (Test-Path -Path $Path)) { throw "Fichier de politique introuvable : $Path" }
    $seen = @{}
    $n = 0
    foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
        $n++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $fields = @($line.Split(';') | ForEach-Object { $_.Trim() })
        $kb = $fields[0].ToUpperInvariant()
        if ($kb -notmatch '^KB\d{6,8}$') {
            Write-Warning "required-patches.txt ligne $n ignorée : identifiant KB invalide '$($fields[0])'"
            continue
        }
        if ($seen.ContainsKey($kb)) {
            Write-Warning "required-patches.txt ligne $n ignorée : $kb déjà présent"
            continue
        }
        $seen[$kb] = $true
        [pscustomobject]@{
            KB          = $kb
            Description = if ($fields.Count -gt 1) { $fields[1] } else { $null }
            Target      = if ($fields.Count -gt 2 -and $fields[2]) { $fields[2] } else { '*' }
        }
    }
}

function Get-PMApplicableRequiredPatch {
    # Correctifs obligatoires applicables à un poste, selon le champ Cible de la politique.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $HostResult, [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RequiredPatch)
    $s = $HostResult.System
    # Version de Windows inconnue : tous les correctifs sont exigés (principe "fail secure",
    # on ne déclare jamais conforme un poste que l'on n'a pas pu caractériser).
    $unknownOs = (-not $s) -or [string]::IsNullOrWhiteSpace([string]$s.OSCaption)
    $descriptor = if ($unknownOs) { '' } else { "$($s.OSCaption) $($s.OSDisplayVersion) $($s.OSBuild)" }
    foreach ($rp in $RequiredPatch) {
        if ($unknownOs -or $rp.Target -eq '*' -or $descriptor -like $rp.Target) { $rp }
    }
}

function Test-PMCompliance {
    <#
    .SYNOPSIS
        Partie 4 : compare les correctifs installés à la politique et attribue un état
        CONFORME / NON CONFORME / INACCESSIBLE à chaque poste.
    .DESCRIPTION
        Un poste est CONFORME uniquement si TOUS les correctifs obligatoires qui lui sont
        applicables sont installés. Un poste dont la collecte a échoué est INACCESSIBLE :
        on ne peut pas affirmer qu'il est conforme (principe "fail secure").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $HostResult,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $RequiredPatch,
        [datetime] $ControlDate = (Get-Date)
    )

    foreach ($r in $HostResult) {
        if (-not $r.System) {
            [pscustomobject][ordered]@{
                Poste            = $r.Name
                AdresseIP        = $r.IPAddress
                KBRequises       = @($RequiredPatch).Count
                KBManquantes     = '—'
                ListeKBManquantes = ''
                KBPresentes      = ''
                Etat             = 'INACCESSIBLE'
                Motif            = $r.Detail
                DateControle     = $ControlDate
            }
            continue
        }

        $applicable = @(Get-PMApplicableRequiredPatch -HostResult $r -RequiredPatch $RequiredPatch)
        $installed  = @(Get-PMInstalledPatch -HostResult $r | ForEach-Object { $_.KB })
        $missing    = @($applicable | Where-Object { $installed -notcontains $_.KB })
        $present    = @($applicable | Where-Object { $installed -contains $_.KB })
        # Si Get-HotFix a échoué sur le poste, les KB "manquantes" le sont peut-être à tort :
        # le poste reste NON CONFORME (on ne peut pas prouver sa conformité) mais le motif le précise.
        $hotFixError = @($r.Errors | Where-Object { $_ -like 'Get-HotFix*' }) | Select-Object -First 1

        [pscustomobject][ordered]@{
            Poste             = $r.Name
            AdresseIP         = $r.IPAddress
            KBRequises        = $applicable.Count
            KBManquantes      = $missing.Count
            ListeKBManquantes = ($missing | ForEach-Object { $_.KB }) -join ', '
            KBPresentes       = ($present | ForEach-Object { $_.KB }) -join ', '
            Etat              = if ($missing.Count -eq 0) { 'CONFORME' } else { 'NON CONFORME' }
            Motif             = if ($hotFixError) { "Inventaire des correctifs incomplet : $hotFixError" }
                                elseif ($missing.Count -eq 0) { 'Tous les correctifs requis sont installés' }
                                else { "$($missing.Count) correctif(s) obligatoire(s) manquant(s)" }
            DateControle      = $ControlDate
        }
    }
}

function Get-PMComplianceRate {
    <#
    .SYNOPSIS
        Taux global de conformité du parc, calculé SANS les postes inaccessibles :
        conformes / (conformes + non conformes) x 100.
    .OUTPUTS
        Pourcentage arrondi à 0,1 près, ou $null si aucun poste n'a pu être évalué.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Compliance)
    $evaluated = @($Compliance | Where-Object { $_.Etat -in 'CONFORME', 'NON CONFORME' })
    if ($evaluated.Count -eq 0) { return $null }
    $ok = @($evaluated | Where-Object { $_.Etat -eq 'CONFORME' }).Count
    return [math]::Round(100 * $ok / $evaluated.Count, 1)
}
