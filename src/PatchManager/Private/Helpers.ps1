# Fonctions internes du module PatchManager (non exportées)

function Resolve-PMPath {
    # Résout un chemin relatif par rapport à la racine du projet.
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $BasePath = $script:PMProjectRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    # Séparateurs normalisés (le projet est aussi testé sous PowerShell 7 Linux)
    $Path = $Path -replace '[\\/]', [System.IO.Path]::DirectorySeparatorChar
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function ConvertTo-PMSafeCsvValue {
    <#
        Protection contre l'injection de formules (CSV injection) : une valeur provenant
        d'un poste audité (ex. description de correctif, nom de modèle) qui commence par
        = + - @ serait interprétée comme une formule par Excel à l'ouverture du rapport.
        On la préfixe d'une apostrophe pour la neutraliser.
    #>
    param($Value)
    if ($null -eq $Value) { return $Value }
    if ($Value -isnot [string]) { return $Value }
    $dangerous = ($Value -match '^[=+@\t\r]') -or
                 ($Value -match '^-' -and $Value -ne '-' -and $Value -notmatch '^-?\d+([.,]\d+)?$')
    if ($dangerous) { return "'" + $Value }
    return $Value
}

function Export-PMCsv {
    # Export CSV homogène : séparateur configurable (« ; » pour Excel FR), UTF-8,
    # valeurs neutralisées contre l'injection de formules.
    param(
        # [object] et non [object[]] : PowerShell 5.1 refuse de convertir une List[object]
        # en object[] (« Les types des arguments ne correspondent pas »)
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Delimiter = ';'
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $rows = foreach ($o in @($InputObject | Where-Object { $null -ne $_ })) {
        $copy = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) {
            $v = $p.Value
            if ($v -is [datetime]) { $v = $v.ToString('dd/MM/yyyy HH:mm:ss') }
            elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $v = ($v -join ', ') }
            $copy[$p.Name] = ConvertTo-PMSafeCsvValue -Value $v
        }
        [pscustomobject]$copy
    }
    if (-not $rows) {
        # Fichier vide mais existant, pour que les consommateurs ne plantent pas
        Set-Content -Path $Path -Value '' -Encoding UTF8
        return
    }
    $rows | Export-Csv -Path $Path -Delimiter $Delimiter -NoTypeInformation -Encoding UTF8
}

function Test-PMPing {
    # Test ICMP avec délai maîtrisé (Test-Connection n'offre pas de délai en ms en 5.1).
    param([Parameter(Mandatory)] [string] $Target, [int] $TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($Target, $TimeoutMs)
        return ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    } finally {
        $ping.Dispose()
    }
}

function Test-PMTcpPort {
    # Vérifie qu'un port TCP accepte les connexions, avec délai court : évite d'attendre
    # le long délai d'expiration de WinRM sur une machine éteinte.
    param([Parameter(Mandatory)] [string] $Target, [Parameter(Mandatory)] [int] $Port, [int] $TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Target, $Port)
        if ($task.Wait($TimeoutMs)) { return $client.Connected }
        return $false
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-PMIsLocalTarget {
    # Indique si l'entrée de l'inventaire désigne la machine qui exécute le script.
    param([string] $Name, [string] $IPAddress)
    $localNames = @('localhost', '.', $env:COMPUTERNAME) | Where-Object { $_ }
    foreach ($n in $localNames) { if ($Name -and $Name -ieq $n) { return $true } }
    if ($IPAddress -in @('127.0.0.1', '::1')) { return $true }
    if ($IPAddress) {
        try {
            $local = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | ForEach-Object { $_.IPAddressToString }
            if ($local -contains $IPAddress) { return $true }
        } catch { Write-Verbose "Résolution des adresses locales impossible : $($_.Exception.Message)" }
    }
    return $false
}

function Format-PMDate {
    param($Date, [string] $Format = 'dd/MM/yyyy HH:mm', [string] $Empty = '—')
    if ($null -eq $Date -or ($Date -is [string] -and [string]::IsNullOrWhiteSpace($Date))) { return $Empty }
    try { return ([datetime]$Date).ToString($Format) } catch { return [string]$Date }
}

function ConvertTo-PMHtmlText {
    # Encodage HTML systématique de toute donnée issue des postes (anti-XSS dans le rapport)
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}
