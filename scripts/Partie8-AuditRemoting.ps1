<#
.SYNOPSIS
    Partie 8 - Audit de sécurité de la configuration PowerShell Remoting / WinRM.

.DESCRIPTION
    Vérifie, sur le poste d'administration et sur chaque poste du parc accessible :
      - qui peut ouvrir une session distante (permissions des points de terminaison,
        membres des groupes Administrateurs et Utilisateurs de gestion à distance) ;
      - les modes d'authentification WinRM autorisés (Basic, Kerberos, Negotiate, CredSSP...) ;
      - le chiffrement (AllowUnencrypted, écouteurs HTTP / HTTPS) ;
      - les règles de pare-feu WinRM et leurs adresses sources autorisées ;
      - LocalAccountTokenFilterPolicy (jeton administrateur complet à distance) ;
      - la journalisation PowerShell (Script Block Logging, transcription) ;
      - la présence du moteur PowerShell 2.0 (permet de contourner la journalisation) ;
      - côté client : TrustedHosts.
    Chaque contrôle reçoit un niveau OK / ATTENTION / RISQUE et une recommandation.
    Résultats : console + Output\<date>\RemotingSecurityAudit.csv / .html

.EXAMPLE
    .\scripts\Partie8-AuditRemoting.ps1 -Credential (Get-Credential)
.EXAMPLE
    .\scripts\Partie8-AuditRemoting.ps1 -LocalOnly
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty,
    [switch] $LocalOnly
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

# Contrôles exécutés sur chaque poste (localement ou via Invoke-Command)
$nodeChecks = {
    $out = New-Object System.Collections.Generic.List[object]
    function Add-Finding($Categorie, $Controle, $Valeur, $Niveau, $Recommandation) {
        $out.Add([pscustomobject]@{
            Poste = $env:COMPUTERNAME; Categorie = $Categorie; Controle = $Controle
            Valeur = [string]$Valeur; Niveau = $Niveau; Recommandation = $Recommandation
        })
    }

    # Service WinRM
    $svc = Get-Service WinRM -ErrorAction SilentlyContinue
    Add-Finding 'Service' 'Service WinRM' "$($svc.Status) / $($svc.StartType)" 'OK' 'Nécessaire à l''administration distante ; désactiver sur les postes non administrés'

    # Qui peut se connecter ?
    try {
        foreach ($cfg in (Get-PSSessionConfiguration -ErrorAction Stop)) {
            $niveau = if ($cfg.Permission -match 'Everyone|Tout le monde|Authenticated Users|Utilisateurs authentifiés|INTERACTIVE') { 'RISQUE' } else { 'OK' }
            Add-Finding 'Accès' "Point de terminaison $($cfg.Name)" $cfg.Permission $niveau 'Seuls les groupes d''administration ou le groupe JEA dédié doivent être autorisés'
        }
    } catch { Add-Finding 'Accès' 'Points de terminaison' "Lecture impossible : $($_.Exception.Message)" 'ATTENTION' 'Exécuter en administrateur' }
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-32-580') {
        try {
            $grp = Get-LocalGroup -SID $sid -ErrorAction Stop
            $members = @(Get-LocalGroupMember -SID $sid -ErrorAction Stop | ForEach-Object Name)
            $niveau = if ($sid -eq 'S-1-5-32-544' -and $members.Count -gt 3) { 'ATTENTION' } else { 'OK' }
            Add-Finding 'Accès' "Membres de $($grp.Name)" ($members -join ', ') $niveau 'Limiter au strict nécessaire (moindre privilège) ; un compte nominatif par administrateur'
        } catch { Add-Finding 'Accès' "Groupe $sid" "Lecture impossible : $($_.Exception.Message)" 'ATTENTION' '' }
    }

    # Authentification et chiffrement côté service (le lecteur WSMan: exige le service WinRM :
    # sans ce test, PowerShell demanderait en boucle s'il faut le démarrer)
    if ((Get-Service WinRM -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Add-Finding 'Authentification' 'Configuration WSMan' 'non lisible : service WinRM arrêté' 'OK' 'Poste non administrable à distance tant que WinRM est arrêté'
    } else { try {
        $auth = @{}
        Get-ChildItem WSMan:\localhost\Service\Auth -ErrorAction Stop | ForEach-Object { $auth[$_.Name] = $_.Value }
        Add-Finding 'Authentification' 'Basic (mot de passe en clair encodé base64)' $auth['Basic'] $(if ($auth['Basic'] -eq 'true') { 'RISQUE' } else { 'OK' }) 'Désactiver'
        Add-Finding 'Authentification' 'Kerberos' $auth['Kerberos'] 'OK' 'Méthode préférée en domaine (authentification mutuelle, pas de mot de passe transmis)'
        Add-Finding 'Authentification' 'Negotiate (NTLM en groupe de travail)' $auth['Negotiate'] 'OK' 'Accepté en groupe de travail, avec TrustedHosts restreint et HTTPS'
        Add-Finding 'Authentification' 'CredSSP (délégation des identifiants)' $auth['CredSSP'] $(if ($auth['CredSSP'] -eq 'true') { 'RISQUE' } else { 'OK' }) 'Désactiver : les identifiants seraient exposés sur le poste distant'
        $unenc = (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value
        Add-Finding 'Chiffrement' 'AllowUnencrypted (service)' $unenc $(if ($unenc -eq 'true') { 'RISQUE' } else { 'OK' }) 'Doit rester à false'
        $listeners = @(Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { ($_.Keys | Where-Object { $_ -like 'Transport=*' }) -replace 'Transport=' })
        $niveau = if ($listeners -contains 'HTTPS') { 'OK' } else { 'ATTENTION' }
        Add-Finding 'Chiffrement' 'Écouteurs WinRM' ($listeners -join ', ') $niveau 'HTTP : flux chiffré par Kerberos/NTLM mais serveur non authentifié par certificat ; HTTPS recommandé hors domaine'
    } catch { Add-Finding 'Authentification' 'Configuration WSMan' "Lecture impossible : $($_.Exception.Message)" 'ATTENTION' 'Exécuter en administrateur' } }

    # Pare-feu
    try {
        $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction Stop |
            Where-Object { ($_ | Get-NetFirewallPortFilter).LocalPort -in '5985', '5986' })
        if (-not $rules) { Add-Finding 'Pare-feu' 'Règles WinRM entrantes' 'aucune règle active' 'ATTENTION' 'WinRM bloqué : normal si le poste n''est pas administré à distance' }
        foreach ($r in $rules) {
            $src = @(($r | Get-NetFirewallAddressFilter).RemoteAddress)
            $niveau = if ($src -contains 'Any' -or $src -contains 'LocalSubnet') { 'RISQUE' } else { 'OK' }
            Add-Finding 'Pare-feu' "Règle $($r.Name) ($($r.Profile))" ("sources : " + ($src -join ', ')) $niveau 'Limiter RemoteAddress à l''adresse du poste d''administration'
        }
    } catch { Add-Finding 'Pare-feu' 'Règles WinRM' "Lecture impossible : $($_.Exception.Message)" 'ATTENTION' '' }

    # UAC distant
    $lat = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    Add-Finding 'Privilèges' 'LocalAccountTokenFilterPolicy' $(if ($null -eq $lat) { 'absent (0)' } else { $lat }) $(if ($lat -eq 1) { 'ATTENTION' } else { 'OK' }) 'À 1, tout compte administrateur local obtient un jeton complet à distance (mouvement latéral facilité) ; préférer JEA'

    # Journalisation PowerShell
    $sbl = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' -ErrorAction SilentlyContinue).EnableScriptBlockLogging
    Add-Finding 'Traçabilité' 'Script Block Logging' $(if ($sbl -eq 1) { 'activé' } else { 'désactivé' }) $(if ($sbl -eq 1) { 'OK' } else { 'ATTENTION' }) 'Activer (setup\Enable-PSAuditLogging.ps1) : journal Microsoft-Windows-PowerShell/Operational, événement 4104'
    $tr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription' -ErrorAction SilentlyContinue).EnableTranscripting
    Add-Finding 'Traçabilité' 'Transcription PowerShell' $(if ($tr -eq 1) { 'activée' } else { 'désactivée' }) $(if ($tr -eq 1) { 'OK' } else { 'ATTENTION' }) 'Activer vers un dossier protégé ou un partage collecté'
    try {
        $v2 = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
        # Windows 11 24H2+ ne contient plus PowerShell 2.0 : la fonctionnalité est alors absente
        $etat = if ($v2 -and $v2.State) { [string]$v2.State } else { 'absent (retiré de Windows)' }
        Add-Finding 'Durcissement' 'Moteur PowerShell 2.0' $etat $(if ($etat -eq 'Enabled') { 'RISQUE' } else { 'OK' }) 'Désactiver : "powershell -version 2" contourne AMSI et la journalisation'
    } catch { Write-Verbose 'Fonctionnalité PowerShell v2 non vérifiable' }

    $out
}

$findings = [System.Collections.Generic.List[object]]::new()

# --- Poste d'administration (client WinRM) -------------------------------------------
# Le service WinRM est en démarrage manuel sur un poste client : après un redémarrage il est
# arrêté et toute lecture du lecteur WSMan: déclencherait une demande de confirmation.
if ((Get-Service WinRM).Status -ne 'Running') {
    try {
        Start-Service WinRM -ErrorAction Stop
        Write-Host 'Service WinRM local démarré (nécessaire pour lire la configuration WSMan:).' -ForegroundColor DarkGray
    } catch { Write-Warning "Service WinRM local arrêté et non démarrable ($($_.Exception.Message)) : lancer le script en administrateur" }
}
$th = if ((Get-Service WinRM).Status -eq 'Running') { (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value }
$findings.Add([pscustomobject]@{
    Poste = "$env:COMPUTERNAME (client)"; Categorie = 'Client'; Controle = 'TrustedHosts'; Valeur = $th
    Niveau = if ($th -eq '*') { 'RISQUE' } else { 'OK' }
    Recommandation = 'Jamais "*" : lister uniquement les postes administrés (ou utiliser Kerberos/HTTPS)'
})
$cu = if ((Get-Service WinRM).Status -eq 'Running') { (Get-Item WSMan:\localhost\Client\AllowUnencrypted -ErrorAction SilentlyContinue).Value }
$findings.Add([pscustomobject]@{
    Poste = "$env:COMPUTERNAME (client)"; Categorie = 'Client'; Controle = 'AllowUnencrypted (client)'; Valeur = $cu
    Niveau = if ($cu -eq 'true') { 'RISQUE' } else { 'OK' }; Recommandation = 'Doit rester à false'
})
foreach ($f in (& $nodeChecks)) { $findings.Add($f) }

# --- Postes du parc -----------------------------------------------------------------
if (-not $LocalOnly) {
    $targets = @(Test-PMComputer -Computer @(Read-PMComputerList) | Where-Object { $_.Accessible -and -not $_.IsLocal })
    if ($targets) {
        $p = @{ ComputerName = $targets.Target; ScriptBlock = $nodeChecks; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'errs' }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $p.Credential = $Credential }
        if ($PMConfig.UseSSL) { $p.UseSSL = $true }
        foreach ($f in (Invoke-Command @p)) { $findings.Add(($f | Select-Object Poste, Categorie, Controle, Valeur, Niveau, Recommandation)) }
        foreach ($e in $errs) { Write-Warning "$($e.OriginInfo.PSComputerName) : $($e.Exception.Message)" }
    }
}

# Niveau affiché avant Valeur : les valeurs longues (permissions) ne le repoussent plus hors de l'écran
$findings | Sort-Object Poste, Categorie | Format-Table -AutoSize -Wrap Poste, Niveau, Categorie, Controle, Valeur | Out-Host
$risks = @($findings | Where-Object Niveau -eq 'RISQUE')
Write-Host ("{0} contrôle(s), {1} RISQUE(S), {2} point(s) d'attention" -f $findings.Count, $risks.Count, @($findings | Where-Object Niveau -eq 'ATTENTION').Count) -ForegroundColor $(if ($risks) { 'Red' } else { 'Green' })

$folder = New-PMRunFolder
Export-PMCsv -InputObject $findings.ToArray() -Path (Join-Path $folder 'RemotingSecurityAudit.csv') -Delimiter $PMConfig.CsvDelimiter
$head = '<meta charset="utf-8"><title>Audit de sécurité WinRM</title><style>body{font-family:Segoe UI,Arial;font-size:13px}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#eef2f7}</style>'
$findings | Sort-Object Poste, Categorie | ConvertTo-Html -Head $head -PreContent "<h1>Audit de sécurité PowerShell Remoting / WinRM</h1><p>$(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>" -Property Poste, Categorie, Controle, Valeur, Niveau, Recommandation |
    Set-Content -Path (Join-Path $folder 'RemotingSecurityAudit.html') -Encoding UTF8
Write-PMLog "Audit de sécurité WinRM : $($risks.Count) risque(s) ($folder)"
Write-Host "Résultats : $folder"
