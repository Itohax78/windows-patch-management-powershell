function Import-PMConfiguration {
    <#
    .SYNOPSIS
        Charge le fichier de configuration et le rend disponible pour tout le module.
    .PARAMETER Path
        Fichier .psd1 de configuration (par défaut config\PatchManager.config.psd1).
    .PARAMETER Override
        Table de valeurs prioritaires (utilisée par les paramètres des scripts et les tests).
    #>
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path -Path $script:PMProjectRoot -ChildPath 'config\PatchManager.config.psd1'),
        [hashtable] $Override = @{}
    )

    $defaults = @{
        ComputersFile           = 'computers.txt'
        RequiredPatchesFile     = 'required-patches.txt'
        OutputRoot              = 'Output'
        LogFile                 = 'Logs\PatchManager.log'
        CsvDelimiter            = ';'
        RetentionDays           = 0
        ConnectBy               = 'IP'
        ConfigurationName       = 'Microsoft.PowerShell'
        UseSSL                  = $false
        HttpPort                = 5985
        HttpsPort               = 5986
        Authentication          = 'Default'
        PingTimeoutMs           = 1000
        PortTimeoutMs           = 2000
        OpenTimeoutMs           = 15000
        OperationTimeoutMs      = 180000
        ThrottleLimit           = 16
        RunLocalWithoutRemoting = $true
        IncludeUpdateHistory    = $true
        MinFreeDiskPercent      = 10
        MaxUptimeDays           = 30
        Notification            = @{ Enabled = $false; Method = 'File'; To = @() }
    }

    $resolved = (Resolve-PMPath -Path $Path)
    $fromFile = @{}
    if ($resolved -and (Test-Path -Path $resolved)) {
        $fromFile = Import-PowerShellDataFile -Path $resolved
    } else {
        Write-Warning "Fichier de configuration introuvable ($Path) : valeurs par défaut utilisées."
    }

    $config = @{}
    foreach ($k in $defaults.Keys) { $config[$k] = $defaults[$k] }
    foreach ($k in $fromFile.Keys) { $config[$k] = $fromFile[$k] }
    foreach ($k in $Override.Keys) {
        $v = $Override[$k]
        if ($null -ne $v -and -not ($v -is [string] -and $v -eq '')) { $config[$k] = $v }
    }

    if ($config.ConnectBy -notin @('IP', 'Name')) { throw "ConnectBy doit valoir 'IP' ou 'Name' (valeur : $($config.ConnectBy))." }
    if ($config.Authentication -notin @('Default', 'Kerberos', 'Negotiate')) { throw "Authentication doit valoir Default, Kerberos ou Negotiate." }

    # Chemins absolus
    $config.ComputersFile       = Resolve-PMPath -Path $config.ComputersFile
    $config.RequiredPatchesFile = Resolve-PMPath -Path $config.RequiredPatchesFile
    $config.OutputRoot          = Resolve-PMPath -Path $config.OutputRoot
    $config.LogFile             = Resolve-PMPath -Path $config.LogFile

    $script:PMConfig = $config
    return $config
}

function Get-PMConfiguration {
    # Renvoie la configuration courante (chargée à la demande).
    [CmdletBinding()]
    param()
    if (-not $script:PMConfig) { Import-PMConfiguration | Out-Null }
    return $script:PMConfig
}

function Write-PMLog {
    <#
    .SYNOPSIS
        Ajoute une ligne horodatée au journal PatchManager.log.
    .DESCRIPTION
        Format : "jj/MM/aaaa HH:mm:ss ; message ; ...". Chaque élément de -Message est
        séparé par " ; " conformément au format demandé. Le journal est en ajout seul
        (append) : le script n'efface ni ne réécrit jamais une ligne existante.
    .EXAMPLE
        Write-PMLog 'PC02', 'Non conforme', 'KB5034441'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [AllowEmptyString()] [AllowEmptyCollection()] [string[]] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO',
        [string] $Path
    )
    if (-not $Path) { $Path = (Get-PMConfiguration).LogFile }
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $parts = @((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))
    if ($Level -eq 'ERROR') { $parts += 'ERREUR' }
    # Les éléments vides sont ignorés (ex. liste de KB vide)
    $parts += @($Message | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    # Neutralise les retours à la ligne pour empêcher l'injection de fausses lignes de journal
    $line = (($parts | ForEach-Object { ([string]$_) -replace '[\r\n]+', ' ' }) -join ' ; ')

    # Ouverture en mode ajout avec partage en lecture, réessai si le fichier est verrouillé
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            try {
                # BOM écrit uniquement à la création du fichier (lisible par PowerShell 5.1 et le Bloc-notes)
                $sw = New-Object System.IO.StreamWriter($fs, (New-Object System.Text.UTF8Encoding($true)))
                $sw.WriteLine($line)
                $sw.Flush()
            } finally { $fs.Dispose() }
            break
        } catch {
            if ($i -eq 4) { Write-Warning "Impossible d'écrire dans le journal : $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 200
        }
    }
    switch ($Level) {
        'ERROR' { Write-Verbose "[ERREUR] $line" }
        'WARN'  { Write-Verbose "[AVERT.] $line" }
        default { Write-Verbose $line }
    }
}

function New-PMRunFolder {
    # Crée le dossier de sortie horodaté de l'exécution courante : Output\AAAAMMJJ-HHmmss
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Création du dossier de résultats propre au script')]
    [CmdletBinding()]
    param([string] $OutputRoot = (Get-PMConfiguration).OutputRoot)
    $folder = Join-Path -Path $OutputRoot -ChildPath (Get-Date -Format 'yyyyMMdd-HHmmss')
    # Deux audits lancés dans la même seconde ne doivent jamais partager (ni écraser) un dossier
    while (Test-Path -Path $folder) {
        Start-Sleep -Milliseconds 300
        $folder = Join-Path -Path $OutputRoot -ChildPath (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    return $folder
}

function Remove-PMExpiredRun {
    # Purge des rapports plus anciens que RetentionDays (politique de conservation, partie 8).
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $OutputRoot = (Get-PMConfiguration).OutputRoot,
        [int] $RetentionDays = (Get-PMConfiguration).RetentionDays
    )
    if ($RetentionDays -le 0 -or -not (Test-Path -Path $OutputRoot)) { return }
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $OutputRoot -Directory |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and $_.CreationTime -lt $limit } |
        ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, 'Suppression (rétention dépassée)')) {
                Remove-Item -Path $_.FullName -Recurse -Force
                Write-PMLog "Purge du rapport expiré $($_.Name)"
            }
        }
}

function Write-PMIntegrityManifest {
    <#
    .SYNOPSIS
        Partie 8 : calcule l'empreinte SHA-256 de chaque fichier produit et l'enregistre
        dans SHA256SUMS.txt ; l'empreinte du manifeste est aussi inscrite dans le journal.
    .DESCRIPTION
        Toute modification ultérieure d'un rapport (falsification d'un état "CONFORME",
        suppression d'une KB manquante...) devient détectable avec Test-PMIntegrity.
        Le journal étant lui-même protégé (ajout seul) et idéalement transféré vers un
        collecteur central, l'attaquant ne peut pas recalculer le manifeste discrètement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RunFolder)
    $manifest = Join-Path -Path $RunFolder -ChildPath 'SHA256SUMS.txt'
    $lines = Get-ChildItem -Path $RunFolder -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    }
    Set-Content -Path $manifest -Value $lines -Encoding UTF8
    $hash = (Get-FileHash -Path $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-PMLog "Empreinte SHA-256 du manifeste $(Split-Path $RunFolder -Leaf) : $hash"
    return $hash
}

function Test-PMIntegrity {
    <#
    .SYNOPSIS
        Vérifie qu'aucun fichier d'un audit n'a été modifié depuis sa génération.
    .OUTPUTS
        Un objet par fichier : Fichier ; Etat (INTACT / MODIFIÉ / SUPPRIMÉ / AJOUTÉ).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RunFolder)
    $manifest = Join-Path -Path $RunFolder -ChildPath 'SHA256SUMS.txt'
    if (-not (Test-Path -Path $manifest)) { throw "Manifeste absent : $manifest" }
    $expected = @{}
    foreach ($l in (Get-Content -Path $manifest -Encoding UTF8)) {
        if ($l -match '^([0-9a-f]{64})  (.+)$') { $expected[$Matches[2]] = $Matches[1] }
    }
    foreach ($name in ($expected.Keys | Sort-Object)) {
        $path = Join-Path $RunFolder $name
        $state = if (-not (Test-Path -Path $path)) { 'SUPPRIMÉ' }
                 elseif ((Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expected[$name]) { 'INTACT' }
                 else { 'MODIFIÉ' }
        [pscustomobject]@{ Fichier = $name; Etat = $state }
    }
    Get-ChildItem -Path $RunFolder -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' -and -not $expected.ContainsKey($_.Name) } |
        ForEach-Object { [pscustomobject]@{ Fichier = $_.Name; Etat = 'AJOUTÉ' } }
}
