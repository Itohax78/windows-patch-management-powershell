# Configuration de la solution PatchManager
# Les chemins relatifs sont résolus par rapport à la racine du projet.
# AUCUN secret (mot de passe, jeton) ne doit figurer dans ce fichier :
# les identifiants sont stockés chiffrés par DPAPI dans le dossier secrets\
# (voir setup\Save-PMSecret.ps1).
@{
    # --- Fichiers d'entrée -------------------------------------------------------------
    ComputersFile        = 'computers.txt'
    RequiredPatchesFile  = 'required-patches.txt'

    # --- Sorties -------------------------------------------------------------------------
    # Chaque exécution crée un sous-dossier horodaté (historique des audits).
    OutputRoot           = 'Output'
    LogFile              = 'Logs\PatchManager.log'
    CsvDelimiter         = ';'
    # Durée de conservation des rapports (jours) ; 0 = pas de purge automatique
    RetentionDays        = 180

    # --- Connexion distante (PowerShell Remoting / WinRM) -------------------------------
    # 'IP'   : connexion par adresse IP (groupe de travail ; nécessite TrustedHosts + NTLM)
    # 'Name' : connexion par nom (domaine Active Directory ; permet Kerberos, recommandé)
    ConnectBy            = 'IP'
    # 'Microsoft.PowerShell' = point de terminaison standard (administrateur requis)
    # 'PatchAudit'           = point de terminaison JEA restreint (voir jea\)
    ConfigurationName    = 'Microsoft.PowerShell'
    # WinRM sur HTTPS (5986) : à activer en production (voir docs\SECURITE.md)
    UseSSL               = $false
    HttpPort             = 5985
    HttpsPort            = 5986
    # Authentification : 'Default' (Kerberos si possible, sinon Negotiate), 'Kerberos', 'Negotiate'
    Authentication       = 'Default'

    # --- Performances et délais -----------------------------------------------------------
    PingTimeoutMs        = 1000
    PortTimeoutMs        = 2000
    # Délais de session WinRM (ms)
    OpenTimeoutMs        = 15000
    OperationTimeoutMs   = 180000
    # Nombre de postes interrogés en parallèle par Invoke-Command
    ThrottleLimit        = 16

    # Le poste d'administration peut lui-même figurer dans computers.txt :
    # il est alors audité localement, sans passer par WinRM.
    RunLocalWithoutRemoting = $true
    # Inclure l'historique de l'agent Windows Update en plus de Get-HotFix
    IncludeUpdateHistory = $true

    # --- Seuils d'alerte (points d'attention du rapport) --------------------------------
    MinFreeDiskPercent   = 10
    MaxUptimeDays        = 30

    # --- Notification (partie 7) -----------------------------------------------------------
    Notification = @{
        Enabled         = $true
        # 'Smtp', 'Webhook' ou 'File' (écrit seulement le message dans le dossier de sortie)
        Method          = 'Smtp'
        SmtpServer      = 'localhost'
        SmtpPort        = 25
        SmtpUseSsl      = $false
        From            = 'patchmanager@entreprise.local'
        To              = @('admin@entreprise.local')
        # Fichier d'identifiants SMTP chiffré (DPAPI) ; vide = envoi anonyme (relais interne)
        CredentialFile  = ''
        # Fichier contenant l'URL du webhook chiffrée (DPAPI) pour Method = 'Webhook'
        WebhookUrlFile  = ''
        AttachCsv       = $true
    }
}
