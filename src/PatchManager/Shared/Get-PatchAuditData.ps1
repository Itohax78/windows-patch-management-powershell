function Get-PatchAuditData {
    <#
    .SYNOPSIS
        Collecte, sur le poste où elle s'exécute, les informations système et de correctifs.

    .DESCRIPTION
        Cette fonction est le "collecteur" de la solution. Elle est exécutée :
          - à distance via Invoke-Command (PowerShell Remoting / WinRM) ;
          - localement lorsque le poste d'administration fait aussi partie du parc ;
          - dans le point de terminaison JEA "PatchAudit" (voir jea/), où elle est la
            SEULE commande visible par le compte d'audit.

        Sortie : un enregistrement RecordType='System' (informations du poste), puis un
        enregistrement 'HotFix' par correctif et un 'UpdateHistory' par entrée d'historique.

        Elle est volontairement autonome (aucune dépendance au module PatchManager) et
        compatible Windows PowerShell 5.1, car c'est la version présente par défaut sur
        tous les postes Windows 10/11.

        Chaque section est protégée par try/catch : une erreur partielle (ex. accès à
        l'historique Windows Update refusé) n'empêche pas la collecte du reste. Les erreurs
        sont renvoyées dans la propriété Errors pour être journalisées côté administrateur.

        Lecture seule : la fonction ne modifie rien sur le poste audité.
    #>
    [CmdletBinding()]
    param(
        # Inclure l'historique Windows Update (API COM Microsoft.Update.Session)
        [bool] $IncludeUpdateHistory = $true
    )

    $errors = New-Object System.Collections.Generic.List[string]

    $result = [ordered]@{
        ComputerName       = $env:COMPUTERNAME
        Domain             = $null
        Manufacturer       = $null
        Model              = $null
        BiosVersion        = $null
        BiosManufacturer   = $null
        SerialNumber       = $null
        OSCaption          = $null
        OSVersion          = $null
        OSBuild            = $null
        OSDisplayVersion   = $null
        OSUBR              = $null
        OSArchitecture     = $null
        LastBootUpTime     = $null
        TotalMemoryGB      = $null
        SystemDrive        = $env:SystemDrive
        SystemDriveSizeGB  = $null
        SystemDriveFreeGB  = $null
        WUServiceStatus    = $null
        WUServiceStartType = $null
        RebootPending      = $null
        HotFixCount        = 0
        CollectedAt        = Get-Date
        PSVersion          = $PSVersionTable.PSVersion.ToString()
        Errors             = $null
    }
    $hotFixes = @()
    $history  = @()
    $pendingUpdates = @()

    # --- Matériel : modèle, mémoire, domaine -------------------------------------------
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $result.ComputerName  = $cs.Name
        $result.Domain        = $cs.Domain
        $result.Manufacturer  = $cs.Manufacturer
        $result.Model         = $cs.Model
        $result.TotalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
    } catch { $errors.Add("Win32_ComputerSystem : $($_.Exception.Message)") }

    # --- BIOS --------------------------------------------------------------------------
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $result.BiosVersion      = $bios.SMBIOSBIOSVersion
        $result.BiosManufacturer = $bios.Manufacturer
        $result.SerialNumber     = $bios.SerialNumber
    } catch { $errors.Add("Win32_BIOS : $($_.Exception.Message)") }

    # --- Système d'exploitation ----------------------------------------------------------
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $result.OSCaption      = $os.Caption
        $result.OSVersion      = $os.Version
        $result.OSBuild        = $os.BuildNumber
        $result.OSArchitecture = $os.OSArchitecture
        $result.LastBootUpTime = $os.LastBootUpTime
        if ($os.SystemDrive) { $result.SystemDrive = $os.SystemDrive }
    } catch { $errors.Add("Win32_OperatingSystem : $($_.Exception.Message)") }

    # Version commerciale (ex. 23H2) et révision de build (UBR) : indispensables pour
    # savoir quel niveau de mise à jour cumulative est réellement appliqué.
    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($cv.DisplayVersion) { $result.OSDisplayVersion = $cv.DisplayVersion }
        elseif ($cv.ReleaseId) { $result.OSDisplayVersion = $cv.ReleaseId }
        $result.OSUBR = $cv.UBR
    } catch { $errors.Add("Registre CurrentVersion : $($_.Exception.Message)") }

    # --- Disque système ------------------------------------------------------------------
    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($result.SystemDrive)'" -ErrorAction Stop
        if ($disk) {
            $result.SystemDriveSizeGB = [math]::Round($disk.Size / 1GB, 2)
            $result.SystemDriveFreeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
        }
    } catch { $errors.Add("Win32_LogicalDisk : $($_.Exception.Message)") }

    # --- Service Windows Update (wuauserv) ----------------------------------------------
    try {
        $svc = Get-Service -Name wuauserv -ErrorAction Stop
        $result.WUServiceStatus = $svc.Status.ToString()
        try {
            # StartType n'existe pas sur les très anciennes versions : repli sur CIM
            $result.WUServiceStartType = $svc.StartType.ToString()
        } catch {
            $result.WUServiceStartType = (Get-CimInstance Win32_Service -Filter "Name='wuauserv'").StartMode
        }
    } catch { $errors.Add("Service wuauserv : $($_.Exception.Message)") }

    # --- Redémarrage en attente (un correctif installé n'est actif qu'après reboot) ------
    try {
        $pending = $false
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        )
        foreach ($k in $keys) { if (Test-Path -Path $k) { $pending = $true } }
        $result.RebootPending = $pending
    } catch { $errors.Add("Redémarrage en attente : $($_.Exception.Message)") }

    # --- Correctifs installés (Get-HotFix = classe Win32_QuickFixEngineering) -------------
    try {
        $hotFixes = @(
            Get-HotFix -ErrorAction Stop | ForEach-Object {
                $installedOn = $null
                try { if ($_.InstalledOn) { $installedOn = [datetime]$_.InstalledOn } } catch { $installedOn = $null }
                [pscustomobject]@{
                    RecordType  = 'HotFix'
                    HotFixID    = ([string]$_.HotFixID).Trim().ToUpperInvariant()
                    Description = $_.Description
                    InstalledOn = $installedOn
                    InstalledBy = $_.InstalledBy
                }
            }
        )
    } catch { $errors.Add("Get-HotFix : $($_.Exception.Message)") }

    # --- Historique Windows Update (complète Get-HotFix) ---------------------------------
    # Get-HotFix ne voit que les correctifs CBS ; l'historique de l'agent Windows Update
    # contient aussi les mises à jour Defender, .NET, pilotes, etc.
    if ($IncludeUpdateHistory) {
        try {
            $session  = New-Object -ComObject 'Microsoft.Update.Session'
            $searcher = $session.CreateUpdateSearcher()
            $count    = $searcher.GetTotalHistoryCount()
            if ($count -gt 0) {
                $history = @(
                    $searcher.QueryHistory(0, $count) | ForEach-Object {
                        if ($_.Title -match '(KB\d{6,8})') {
                            [pscustomobject]@{
                                RecordType = 'UpdateHistory'
                                KB         = $Matches[1].ToUpperInvariant()
                                Title      = $_.Title
                                # l'API renvoie une date UTC : conversion en heure locale
                                Date       = [datetime]::SpecifyKind($_.Date, 'Utc').ToLocalTime()
                                # 1 = installation, 2 = désinstallation
                                Operation  = [int]$_.Operation
                                # 2 = réussi, 3 = réussi avec erreurs, 4 = échec, 5 = annulé
                                ResultCode = [int]$_.ResultCode
                            }
                        }
                    }
                )
            }
        } catch { $errors.Add("Historique Windows Update : $($_.Exception.Message)") }

        # Mises à jour applicables NON installées, d'après l'agent Windows Update (recherche
        # hors ligne, sans réseau). Sert à écarter un KB que l'historique dit « installé »
        # alors qu'il a été désinstallé hors de Windows Update (Paramètres, DISM) : dans ce
        # cas l'historique n'enregistre pas la désinstallation.
        try {
            $offline = (New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateSearcher()
            $offline.Online = $false
            $pendingUpdates = @(
                $offline.Search("IsInstalled=0 and Type='Software'").Updates | ForEach-Object {
                    $title = $_.Title
                    foreach ($id in @($_.KBArticleIDs)) {
                        [pscustomobject]@{ RecordType = 'PendingUpdate'; KB = ('KB' + $id).ToUpperInvariant(); Title = $title }
                    }
                }
            )
        } catch { Write-Verbose "Recherche hors ligne Windows Update impossible : $($_.Exception.Message)" }
    }

    # Sortie "à plat" : PowerShell Remoting ne sérialise fidèlement qu'un niveau de
    # propriétés. Plutôt qu'un objet contenant des tableaux d'objets (qui arriveraient
    # sous forme de chaînes), on émet des enregistrements typés par RecordType.
    $result.HotFixCount = $hotFixes.Count
    $result.Errors = ($errors.ToArray() -join ' | ')
    $system = [pscustomobject]$result
    $system | Add-Member -NotePropertyName RecordType -NotePropertyValue 'System' -PassThru
    $hotFixes
    $history
    $pendingUpdates
}
