function Get-PMAnomaly {
    <#
    .SYNOPSIS
        Partie 7 : postes en anomalie (NON CONFORME ou INACCESSIBLE).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Report)
    @($Report | Where-Object { $_.Conformite -in 'NON CONFORME', 'INACCESSIBLE' })
}

function New-PMNotificationMessage {
    <#
    .SYNOPSIS
        Construit l'objet et le corps du message destiné à l'administrateur.
    .OUTPUTS
        { Subject ; Body } ou $null s'il n'y a aucune anomalie.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Construit un message en mémoire, ne modifie pas le système')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Report,
        [datetime] $ControlDate = (Get-Date),
        # BONUS : évolution depuis l'audit précédent (régressions mises en avant)
        $Trend
    )
    $anomalies = Get-PMAnomaly -Report $Report
    if ($anomalies.Count -eq 0) { return $null }

    $nonConf = @($anomalies | Where-Object { $_.Conformite -eq 'NON CONFORME' })
    $inacc   = @($anomalies | Where-Object { $_.Conformite -eq 'INACCESSIBLE' })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Date du contrôle : $($ControlDate.ToString('dd/MM/yyyy HH:mm'))")
    $lines.Add('')
    $lines.Add(('{0,-28}: {1}' -f 'Postes contrôlés', @($Report).Count))
    $lines.Add(('{0,-28}: {1}' -f 'Postes non conformes', $nonConf.Count))
    $lines.Add(('{0,-28}: {1}' -f 'Postes inaccessibles', $inacc.Count))
    $lines.Add('')
    foreach ($a in $anomalies) {
        $lines.Add("$($a.Poste) ($($a.AdresseIP)) : $($a.Conformite)")
        if ($a.Conformite -eq 'NON CONFORME') {
            foreach ($kb in ($a.ListeKBManquantes -split ',\s*' | Where-Object { $_ })) {
                $lines.Add("       $kb manquante")
            }
        } elseif ($a.Erreur) {
            $lines.Add("       $($a.Erreur)")
        }
        $lines.Add('')
    }
    # BONUS : les postes qui étaient conformes au contrôle précédent sont signalés en premier
    if ($Trend -and @($Trend.Regressions).Count) {
        $lines.Add("ATTENTION - régression depuis l'audit $($Trend.PreviousAudit) :")
        foreach ($g in $Trend.Regressions) { $lines.Add("       $($g.Poste) : $($g.EtatPrecedent) -> $($g.EtatActuel)") }
        $lines.Add('')
    }
    $lines.Add('Le rapport complet est joint à ce message.')
    $lines.Add('-- ')
    $lines.Add("Message automatique PatchManager - poste $([Environment]::MachineName)")

    [pscustomobject]@{
        Subject = '[PATCH MANAGEMENT] Anomalies détectées'
        Body    = ($lines -join [Environment]::NewLine)
    }
}

function Send-PMNotification {
    <#
    .SYNOPSIS
        Partie 7 : envoie la notification UNIQUEMENT si au moins une anomalie existe.
    .DESCRIPTION
        Méthodes :
          - Smtp    : courriel avec le rapport HTML (et CSV) en pièce jointe ;
          - Webhook : message JSON (Teams / Slack / Mattermost...) ;
          - File    : écrit seulement le message dans le dossier du rapport (démonstration).
        Aucun secret n'est écrit dans le script ni dans la configuration : les identifiants
        SMTP et l'URL du webhook sont lus depuis des fichiers chiffrés par DPAPI
        (Export-Clixml), déchiffrables uniquement par le même compte sur le même poste.
        Le message est toujours conservé dans Notification.txt (traçabilité), et l'envoi
        (ou son échec) est consigné dans PatchManager.log.
    .OUTPUTS
        $true si envoyée, $false si échec, $null si aucune anomalie (pas d'envoi).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]] $Report,
        [string[]] $Attachment = @(),
        [Parameter(Mandatory)] [string] $RunFolder,
        $Trend
    )
    $cfg = (Get-PMConfiguration).Notification
    $message = New-PMNotificationMessage -Report $Report -Trend $Trend
    if (-not $message) {
        Write-PMLog 'Aucune anomalie détectée - aucune notification envoyée'
        return $null
    }

    $msgFile = Join-Path -Path $RunFolder -ChildPath 'Notification.txt'
    Set-Content -Path $msgFile -Value ("Objet : $($message.Subject)`r`n`r`n$($message.Body)") -Encoding UTF8

    if (-not $cfg -or -not $cfg.Enabled) {
        Write-PMLog 'Notification désactivée dans la configuration - message conservé dans Notification.txt'
        return $false
    }

    $to = @($cfg.To) -join ', '
    try {
        switch ($cfg.Method) {
            'Smtp' {
                $params = @{
                    SmtpServer  = $cfg.SmtpServer
                    Port        = $cfg.SmtpPort
                    From        = $cfg.From
                    To          = @($cfg.To)
                    Subject     = $message.Subject
                    Body        = $message.Body
                    Encoding    = [System.Text.Encoding]::UTF8
                    ErrorAction = 'Stop'
                }
                if ($cfg.SmtpUseSsl) { $params.UseSsl = $true }
                $existing = @($Attachment | Where-Object { $_ -and (Test-Path -Path $_) })
                if ($existing.Count) { $params.Attachments = $existing }
                if ($cfg.CredentialFile) {
                    # PSCredential chiffré par DPAPI (setup\Save-PMSecret.ps1)
                    $params.Credential = Import-Clixml -Path (Resolve-PMPath -Path $cfg.CredentialFile)
                }
                if ($PSCmdlet.ShouldProcess($to, 'Envoi du courriel de notification')) {
                    # Send-MailMessage est marqué obsolète par Microsoft mais reste disponible
                    # sur Windows PowerShell 5.1 ; les alternatives sont discutées dans le rapport.
                    $wp = $WarningPreference; $WarningPreference = 'SilentlyContinue'
                    try { Send-MailMessage @params } finally { $WarningPreference = $wp }
                }
            }
            'Webhook' {
                if (-not $cfg.WebhookUrlFile) { throw 'WebhookUrlFile non renseigné dans la configuration' }
                $secure = Import-Clixml -Path (Resolve-PMPath -Path $cfg.WebhookUrlFile)
                $url = [System.Net.NetworkCredential]::new('', $secure).Password
                $payload = @{ text = "**$($message.Subject)**`n`n$($message.Body)" } | ConvertTo-Json
                if ($PSCmdlet.ShouldProcess('webhook', 'Envoi de la notification')) {
                    Invoke-RestMethod -Uri $url -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -ErrorAction Stop | Out-Null
                }
                $to = 'webhook'
            }
            'File' {
                # Aucun envoi réseau : le message reste disponible dans Notification.txt
                Write-PMLog "Notification enregistrée dans $msgFile (méthode File, destinataire prévu : $to)"
                return $true
            }
            default { throw "Méthode de notification inconnue : $($cfg.Method)" }
        }
        Write-PMLog "Notification envoyée à $to"
        return $true
    } catch {
        Write-PMLog -Level ERROR -Message 'Notification non envoyée', $_.Exception.Message
        Write-Warning "Notification non envoyée : $($_.Exception.Message)"
        return $false
    }
}
