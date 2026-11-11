function Read-PMComputerList {
    <#
    .SYNOPSIS
        Lit l'inventaire du parc (computers.txt, format NOM;IP).
    .DESCRIPTION
        - ignore les lignes vides et les commentaires (#) ;
        - valide le nom (caractères NetBIOS) et l'adresse IP ;
        - signale et ignore les lignes invalides et les doublons, sans arrêter le script.
    .OUTPUTS
        Objets { Name ; IPAddress ; LineNumber }
    #>
    [CmdletBinding()]
    param([string] $Path = (Get-PMConfiguration).ComputersFile)

    if (-not (Test-Path -Path $Path)) { throw "Fichier d'inventaire introuvable : $Path" }

    $seenNames = @{}
    $seenIPs   = @{}
    $lineNumber = 0
    foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
        $lineNumber++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        $fields = $line.Split(';') | ForEach-Object { $_.Trim() }
        if ($fields.Count -lt 2 -or -not $fields[0] -or -not $fields[1]) {
            Write-Warning "computers.txt ligne $lineNumber ignorée (format attendu NOM;IP) : '$line'"
            continue
        }
        $name, $ip = $fields[0], $fields[1]

        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9\-_.]{0,62}$') {
            Write-Warning "computers.txt ligne $lineNumber ignorée : nom de poste invalide '$name'"
            continue
        }
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed) -or $ip -notmatch '^[0-9a-fA-F:.]+$' -or ($parsed.AddressFamily -eq 'InterNetwork' -and $ip.Split('.').Count -ne 4)) {
            Write-Warning "computers.txt ligne $lineNumber ignorée : adresse IP invalide '$ip'"
            continue
        }
        if ($seenNames.ContainsKey($name.ToUpperInvariant())) {
            Write-Warning "computers.txt ligne $lineNumber ignorée : poste '$name' déjà présent"
            continue
        }
        if ($seenIPs.ContainsKey($ip)) {
            Write-Warning "computers.txt ligne $lineNumber ignorée : adresse $ip déjà attribuée à $($seenIPs[$ip])"
            continue
        }
        $seenNames[$name.ToUpperInvariant()] = $true
        $seenIPs[$ip] = $name

        [pscustomobject]@{
            Name       = $name
            IPAddress  = $ip
            LineNumber = $lineNumber
        }
    }
}

function Test-PMComputer {
    <#
    .SYNOPSIS
        Partie 1 : teste la disponibilité de chaque poste (ICMP, port WinRM, Test-WSMan).
    .DESCRIPTION
        Trois niveaux de test, du plus simple au plus complet :
          1. Ping ICMP          : la machine répond-elle sur le réseau ? (peut être filtré)
          2. Port TCP 5985/5986 : le service WinRM écoute-t-il et le pare-feu l'autorise-t-il ?
          3. Test-WSMan         : le service répond-il réellement au protocole WS-Management ?
        Un poste est "Accessible" si WinRM répond, même si le ping est bloqué par le pare-feu
        (comportement par défaut de Windows sur le profil Public).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [object[]] $Computer,
        [switch] $UseTestWSMan
    )
    begin {
        $cfg  = Get-PMConfiguration
        $port = if ($cfg.UseSSL) { $cfg.HttpsPort } else { $cfg.HttpPort }
        $hasTestWSMan = [bool](Get-Command -Name Test-WSMan -ErrorAction SilentlyContinue)
    }
    process {
        foreach ($c in $Computer) {
            $isLocal = $cfg.RunLocalWithoutRemoting -and (Test-PMIsLocalTarget -Name $c.Name -IPAddress $c.IPAddress)
            $target  = if ($cfg.ConnectBy -eq 'Name') { $c.Name } else { $c.IPAddress }
            $ping    = Test-PMPing -Target $c.IPAddress -TimeoutMs $cfg.PingTimeoutMs

            $portOpen = $null; $wsman = $null; $detail = $null
            if ($isLocal) {
                $winrmOk = $true
                $detail  = 'Poste local (audit sans WinRM)'
            } else {
                $portOpen = Test-PMTcpPort -Target $target -Port $port -TimeoutMs $cfg.PortTimeoutMs
                if ($portOpen -and $UseTestWSMan -and $hasTestWSMan) {
                    try {
                        $wsParams = @{ ComputerName = $target; Port = $port; ErrorAction = 'Stop' }
                        if ($cfg.UseSSL) { $wsParams.UseSSL = $true }
                        Test-WSMan @wsParams | Out-Null
                        $wsman = $true
                    } catch {
                        $wsman  = $false
                        $detail = "Test-WSMan : $($_.Exception.Message)"
                    }
                }
                $winrmOk = [bool]$portOpen -and ($wsman -ne $false)
                if (-not $detail) {
                    $detail = switch ($true) {
                        ($winrmOk -and $ping)      { 'OK'; break }
                        ($winrmOk -and -not $ping) { 'WinRM OK (ICMP filtré par le pare-feu)'; break }
                        ($ping)                    { "WinRM inaccessible (port $port fermé ou filtré)"; break }
                        default                    { 'Hôte injoignable' }
                    }
                }
            }

            [pscustomobject]@{
                Name       = $c.Name
                IPAddress  = $c.IPAddress
                Target     = $target
                IsLocal    = $isLocal
                Ping       = $ping
                WinRMPort  = $portOpen
                WSMan      = $wsman
                Accessible = $winrmOk
                Status     = if ($winrmOk) { 'Accessible' } else { 'Inaccessible' }
                Detail     = $detail
                CheckedAt  = Get-Date
            }
        }
    }
}

function Invoke-PMCollection {
    <#
    .SYNOPSIS
        Collecte centralisée : teste les postes puis exécute le collecteur sur tous les
        postes accessibles via PowerShell Remoting (en parallèle).
    .DESCRIPTION
        - Les postes inaccessibles sont écartés proprement (aucune tentative inutile).
        - Une session PSSession est ouverte par poste ; un échec d'ouverture (droits,
          authentification, TrustedHosts...) est consigné et n'interrompt pas l'audit.
        - Le collecteur est exécuté en un seul aller-retour, en parallèle sur toutes les
          sessions (Invoke-Command -Session ... -ThrottleLimit), ce qui permet de passer
          à l'échelle sur un parc plus important.
        - Les sessions sont toujours fermées (bloc finally).
    .OUTPUTS
        Un objet par poste : état d'accessibilité + données collectées (System, HotFixes,
        UpdateHistory) + erreurs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Computer,
        [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty,
        [switch] $SkipWSManTest
    )

    $cfg = Get-PMConfiguration
    $port = if ($cfg.UseSSL) { $cfg.HttpsPort } else { $cfg.HttpPort }
    $results = [ordered]@{}

    foreach ($check in (Test-PMComputer -Computer $Computer -UseTestWSMan:(-not $SkipWSManTest))) {
        $results[$check.Name] = [pscustomobject]@{
            Name          = $check.Name
            IPAddress     = $check.IPAddress
            Target        = $check.Target
            IsLocal       = $check.IsLocal
            Ping          = $check.Ping
            Accessible    = $check.Accessible
            Status        = $check.Status
            Detail        = $check.Detail
            System        = $null
            HotFixes      = @()
            UpdateHistory = @()
            PendingUpdates = @()
            Errors        = New-Object System.Collections.Generic.List[string]
            CheckedAt     = $check.CheckedAt
        }
        if (-not $check.Accessible) { $results[$check.Name].Errors.Add($check.Detail) }
    }

    # --- 1. Postes locaux : exécution directe du collecteur ---------------------------
    foreach ($r in @($results.Values | Where-Object { $_.Accessible -and $_.IsLocal })) {
        try {
            $records = @(Get-PatchAuditData -IncludeUpdateHistory $cfg.IncludeUpdateHistory)
            Add-PMCollectedData -HostResult $r -Records $records
        } catch {
            Add-PMCollectionFailure -HostResult $r -Message "Collecte locale : $($_.Exception.Message)"
        }
    }

    # --- 2. Postes distants : sessions PowerShell Remoting ------------------------------
    $remote = @($results.Values | Where-Object { $_.Accessible -and -not $_.IsLocal })
    if ($remote.Count -eq 0) { return $results.Values }

    $sessionOption = New-PMSessionOption -Config $cfg
    $sessions = @()
    $sessionMap = @{}
    try {
        foreach ($r in $remote) {
            $p = @{
                ComputerName      = $r.Target
                Port              = $port
                SessionOption     = $sessionOption
                ConfigurationName = $cfg.ConfigurationName
                Authentication    = $cfg.Authentication
                ErrorAction       = 'Stop'
            }
            if ($cfg.UseSSL) { $p.UseSSL = $true }
            if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $p.Credential = $Credential }
            try {
                $s = New-PSSession @p
                $sessions += $s
                $sessionMap[([string]$s.ComputerName).ToUpperInvariant()] = $r
            } catch {
                Add-PMCollectionFailure -HostResult $r -Message "Ouverture de session WinRM refusée : $($_.Exception.Message)"
            }
        }

        if ($sessions.Count -gt 0) {
            $remoteErrors = $null
            $icParams = @{
                Session       = $sessions
                ThrottleLimit = $cfg.ThrottleLimit
                ErrorAction   = 'SilentlyContinue'
                ErrorVariable = 'remoteErrors'
            }
            if ($cfg.ConfigurationName -eq 'Microsoft.PowerShell') {
                # Point de terminaison standard : on envoie le code du collecteur
                $icParams.ScriptBlock  = ${function:Get-PatchAuditData}
                $icParams.ArgumentList = @([bool]$cfg.IncludeUpdateHistory)
            } else {
                # Point de terminaison JEA : seule la commande Get-PatchAuditData est
                # autorisée (mode NoLanguage, aucun script arbitraire accepté).
                $icParams.ScriptBlock = { Get-PatchAuditData }
            }
            $output = @(Invoke-Command @icParams)

            foreach ($group in ($output | Group-Object -Property PSComputerName)) {
                $r = $sessionMap[([string]$group.Name).ToUpperInvariant()]
                if ($r) { Add-PMCollectedData -HostResult $r -Records $group.Group }
            }
            foreach ($e in @($remoteErrors)) {
                $origin = $null
                if ($e.OriginInfo) { $origin = $e.OriginInfo.PSComputerName }
                elseif ($e.TargetObject -is [System.Management.Automation.Runspaces.PSSession]) { $origin = $e.TargetObject.ComputerName }
                $r = if ($origin) { $sessionMap[$origin.ToUpperInvariant()] } else { $null }
                if ($r) { $r.Errors.Add("Commande distante : $($e.Exception.Message)") }
                else { Write-PMLog -Level WARN -Message "Erreur distante non attribuée : $($e.Exception.Message)" }
            }
            # Session ouverte mais aucune donnée reçue : la collecte a échoué
            foreach ($r in $sessionMap.Values) {
                if (-not $r.System -and $r.Accessible) {
                    $msg = if ($r.Errors.Count) { $r.Errors[-1] } else { 'Aucune donnée renvoyée par le poste' }
                    Add-PMCollectionFailure -HostResult $r -Message $msg
                }
            }
        }
    } finally {
        if ($sessions.Count -gt 0) { $sessions | Remove-PSSession -ErrorAction SilentlyContinue }
    }

    return $results.Values
}

function New-PMSessionOption {
    # Options de session WinRM : délais maîtrisés, pas de chargement de profil distant.
    # La vérification des certificats (HTTPS) n'est JAMAIS désactivée.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Construit un objet en mémoire, ne modifie pas le système')]
    param([Parameter(Mandatory)] [hashtable] $Config)
    New-PSSessionOption -OpenTimeout $Config.OpenTimeoutMs -OperationTimeout $Config.OperationTimeoutMs -NoMachineProfile
}

function Add-PMCollectedData {
    # Range les enregistrements renvoyés par le collecteur dans le résultat du poste.
    param([Parameter(Mandatory)] $HostResult, [object[]] $Records)
    $system = $Records | Where-Object { $_.RecordType -eq 'System' } | Select-Object -First 1
    if (-not $system) {
        Add-PMCollectionFailure -HostResult $HostResult -Message 'Réponse du collecteur invalide (aucune donnée système)'
        return
    }
    $HostResult.System        = $system
    $HostResult.HotFixes      = @($Records | Where-Object { $_.RecordType -eq 'HotFix' })
    $HostResult.UpdateHistory = @($Records | Where-Object { $_.RecordType -eq 'UpdateHistory' })
    $HostResult | Add-Member -NotePropertyName PendingUpdates -NotePropertyValue @($Records | Where-Object { $_.RecordType -eq 'PendingUpdate' }) -Force
    if ($system.Errors) {
        foreach ($e in ([string]$system.Errors -split ' \| ')) { if ($e) { $HostResult.Errors.Add($e) } }
    }
    if ($system.ComputerName -and $system.ComputerName -ne $HostResult.Name) {
        $HostResult.Errors.Add("Nom réel du poste ($($system.ComputerName)) différent de computers.txt ($($HostResult.Name))")
    }
}

function Add-PMCollectionFailure {
    # Marque un poste comme inaccessible suite à un échec de collecte (erreur conservée).
    param([Parameter(Mandatory)] $HostResult, [Parameter(Mandatory)] [string] $Message)
    $HostResult.Accessible = $false
    $HostResult.Status     = 'Inaccessible'
    $HostResult.Detail     = $Message
    $HostResult.Errors.Add($Message)
}

function Get-PMInstalledPatch {
    <#
    .SYNOPSIS
        Liste consolidée des correctifs installés sur un poste (Get-HotFix + historique WU).
    .DESCRIPTION
        Get-HotFix (état actuel des composants CBS) fait foi. Un KB connu uniquement par
        l'historique Windows Update n'est retenu que si sa DERNIÈRE opération est une
        installation réussie (une désinstallation postérieure l'annule) ET si l'agent Windows
        Update ne le signale pas comme applicable non installé (désinstallation faite hors
        Windows Update, que l'historique n'enregistre pas).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $HostResult)

    $byKb = [ordered]@{}
    foreach ($h in $HostResult.HotFixes) {
        if (-not $h.HotFixID) { continue }
        $kb = ([string]$h.HotFixID).ToUpperInvariant()
        $byKb[$kb] = [pscustomobject]@{
            KB          = $kb
            Description = $h.Description
            InstalledOn = $h.InstalledOn
            InstalledBy = $h.InstalledBy
            Source      = 'Get-HotFix'
        }
    }
    # KB que Windows Update considère comme applicables mais NON installés (désinstallés
    # hors Windows Update) : l'historique ne suffit pas à les déclarer présents.
    $pendingProp = $HostResult.PSObject.Properties['PendingUpdates']
    $pendingKb = @(if ($pendingProp) { @($pendingProp.Value) | ForEach-Object { ([string]$_.KB).ToUpperInvariant() } })
    $history = @($HostResult.UpdateHistory | Where-Object { $_.KB } | Sort-Object -Property Date)
    $lastOp = @{}
    foreach ($u in $history) { $lastOp[$u.KB] = $u }  # trié par date : la dernière opération gagne
    foreach ($kb in $lastOp.Keys) {
        $u = $lastOp[$kb]
        # Get-HotFix reflète l'état actuel du système : il fait foi s'il connaît le KB.
        if ($byKb.Contains($kb)) { continue }
        $success = $u.ResultCode -in 2, 3
        if ($pendingKb -contains $kb) { continue }
        if ($u.Operation -eq 1 -and $success) {
            $byKb[$kb] = [pscustomobject]@{
                KB          = $kb
                Description = $u.Title
                InstalledOn = $u.Date
                InstalledBy = $null
                Source      = 'Historique Windows Update'
            }
        }
    }
    return @($byKb.Values)
}

function ConvertTo-PMInventory {
    <#
    .SYNOPSIS
        Partie 2 : construit l'inventaire du parc (un objet par poste).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $HostResult)

    foreach ($r in $HostResult) {
        $s = $r.System
        $patches = if ($s) { @(Get-PMInstalledPatch -HostResult $r) } else { @() }
        $lastPatch = $patches | Where-Object { $_.InstalledOn } | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1

        $windows = $null; $build = $null
        if ($s) {
            $windows = (@($s.OSCaption, $s.OSDisplayVersion) | Where-Object { $_ }) -join ' '
            $build   = if ($null -ne $s.OSUBR -and $s.OSBuild) { "$($s.OSBuild).$($s.OSUBR)" } else { $s.OSBuild }
        }
        $freePct = $null
        if ($s -and $s.SystemDriveSizeGB) { $freePct = [math]::Round(100 * $s.SystemDriveFreeGB / $s.SystemDriveSizeGB, 1) }

        [pscustomobject][ordered]@{
            Poste                  = $r.Name
            AdresseIP              = $r.IPAddress
            Etat                   = $r.Status
            Ping                   = if ($r.Ping) { 'OK' } else { 'KO' }
            NomReel                = if ($s) { $s.ComputerName } else { $null }
            Fabricant              = if ($s) { $s.Manufacturer } else { $null }
            Modele                 = if ($s) { $s.Model } else { $null }
            BIOS                   = if ($s) { $s.BiosVersion } else { $null }
            Windows                = $windows
            Build                  = $build
            Architecture           = if ($s) { $s.OSArchitecture } else { $null }
            DernierDemarrage       = if ($s) { $s.LastBootUpTime } else { $null }
            RAM_Go                 = if ($s) { $s.TotalMemoryGB } else { $null }
            DisqueSysteme          = if ($s) { $s.SystemDrive } else { $null }
            DisqueLibre_Go         = if ($s) { $s.SystemDriveFreeGB } else { $null }
            DisqueTotal_Go         = if ($s) { $s.SystemDriveSizeGB } else { $null }
            DisqueLibre_Pct        = $freePct
            DerniereMAJ            = if ($lastPatch) { $lastPatch.InstalledOn } else { $null }
            NbMAJInstallees        = if ($s) { $patches.Count } else { $null }
            WindowsUpdate          = if ($s) { $s.WUServiceStatus } else { $null }
            WindowsUpdateDemarrage = if ($s) { $s.WUServiceStartType } else { $null }
            RedemarrageEnAttente   = if ($s) { $s.RebootPending } else { $null }
            Erreur                 = ($r.Errors | Select-Object -Unique) -join ' | '
            DateControle           = $r.CheckedAt
        }
    }
}

function ConvertTo-PMPatchInventory {
    <#
    .SYNOPSIS
        Partie 3 : une ligne par correctif et par poste, triée par poste puis par date
        d'installation décroissante.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $HostResult)

    $rows = foreach ($r in ($HostResult | Where-Object { $_.System })) {
        foreach ($p in (Get-PMInstalledPatch -HostResult $r)) {
            [pscustomobject][ordered]@{
                Poste            = $r.Name
                AdresseIP        = $r.IPAddress
                KB               = $p.KB
                Description      = $p.Description
                DateInstallation = $p.InstalledOn
                InstallePar      = $p.InstalledBy
                Source           = $p.Source
            }
        }
    }
    # Les dates inconnues sont placées en fin de liste pour chaque poste
    $rows | Sort-Object -Property @{ Expression = 'Poste'; Ascending = $true },
                                  @{ Expression = { if ($_.DateInstallation) { [datetime]$_.DateInstallation } else { [datetime]::MinValue } }; Descending = $true }
}

function Get-PMPatchSummary {
    <#
    .SYNOPSIS
        Partie 3 : synthèse par poste (nombre de correctifs, date et KB du plus récent).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $HostResult)

    foreach ($r in $HostResult) {
        if (-not $r.System) {
            [pscustomobject][ordered]@{
                Poste = $r.Name; AdresseIP = $r.IPAddress; Etat = $r.Status
                NbCorrectifs = $null; DateDernierCorrectif = $null; DernierKB = $null
            }
            continue
        }
        $patches = @(Get-PMInstalledPatch -HostResult $r)
        $last = $patches | Where-Object { $_.InstalledOn } | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
        [pscustomobject][ordered]@{
            Poste                = $r.Name
            AdresseIP            = $r.IPAddress
            Etat                 = $r.Status
            NbCorrectifs         = $patches.Count
            DateDernierCorrectif = if ($last) { $last.InstalledOn } else { $null }
            DernierKB            = if ($last) { $last.KB } else { $null }
        }
    }
}

function Find-PMPatch {
    <#
    .SYNOPSIS
        Recherche un correctif de sécurité (numéro KB) sur l'ensemble des postes collectés.
    .EXAMPLE
        Find-PMPatch -HostResult $hosts -KB KB5034441
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $HostResult,
        [Parameter(Mandatory)] [ValidatePattern('^(?i)KB\d{6,8}$')] [string] $KB
    )
    $KB = $KB.ToUpperInvariant()
    foreach ($r in $HostResult) {
        $found = $null
        if ($r.System) { $found = Get-PMInstalledPatch -HostResult $r | Where-Object { $_.KB -eq $KB } | Select-Object -First 1 }
        [pscustomobject][ordered]@{
            Poste            = $r.Name
            AdresseIP        = $r.IPAddress
            KB               = $KB
            Resultat         = if (-not $r.System) { 'INACCESSIBLE' } elseif ($found) { 'INSTALLÉ' } else { 'ABSENT' }
            DateInstallation = if ($found) { $found.InstalledOn } else { $null }
            Source           = if ($found) { $found.Source } else { $null }
        }
    }
}
