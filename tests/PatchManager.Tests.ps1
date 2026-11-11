#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Tests unitaires et d'intégration (sans réseau) de la solution PatchManager.
# Exécution : Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'src/PatchManager/PatchManager.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pm-tests-" + [guid]::NewGuid())
    New-Item -Path $script:tmp -ItemType Directory | Out-Null
    $script:logFile = Join-Path $script:tmp 'PatchManager.log'
    Import-PMConfiguration -Override @{
        LogFile = $script:logFile; OutputRoot = (Join-Path $script:tmp 'Output')
        Notification = @{ Enabled = $true; Method = 'File'; To = @('admin@entreprise.local') }
    } | Out-Null
}

AfterAll {
    Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Partie 1 - Lecture de computers.txt' {
    BeforeAll {
        $script:file = Join-Path $script:tmp 'computers.txt'
        @(
            '# commentaire', '', 'PC01;192.168.10.11', '  PC02 ; 192.168.10.12  ',
            'PC03;999.1.1.1', 'PC04', 'PC01;192.168.10.99', 'PC05;192.168.10.11', 'PC 06;192.168.10.16',
            'PC07;10.0.0.7'
        ) | Set-Content -Path $script:file -Encoding UTF8
        $script:list = @(Read-PMComputerList -Path $script:file -WarningAction SilentlyContinue)
    }
    It 'retient uniquement les lignes valides' {
        $script:list.Name | Should -Be @('PC01', 'PC02', 'PC07')
    }
    It 'supprime les espaces autour des champs' {
        ($script:list | Where-Object Name -eq 'PC02').IPAddress | Should -Be '192.168.10.12'
    }
    It 'signale les lignes invalides et les doublons par un avertissement' {
        $warnings = $null
        Read-PMComputerList -Path $script:file -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        $warnings.Count | Should -Be 5
    }
    It 'échoue clairement si le fichier est absent' {
        { Read-PMComputerList -Path (Join-Path $script:tmp 'absent.txt') } | Should -Throw '*introuvable*'
    }
}

Describe 'Partie 1 - Test de disponibilité' {
    It 'considère un poste accessible si WinRM répond même quand le ping est filtré' {
        InModuleScope PatchManager {
            Mock Test-PMPing { $false }
            Mock Test-PMTcpPort { $true }
            Mock Test-PMIsLocalTarget { $false }
            $r = Test-PMComputer -Computer ([pscustomobject]@{ Name = 'PC01'; IPAddress = '192.168.10.11' })
            $r.Status | Should -Be 'Accessible'
            $r.Detail | Should -BeLike '*ICMP filtré*'
        }
    }
    It 'signale "WinRM inaccessible" si la machine répond au ping mais pas WinRM' {
        InModuleScope PatchManager {
            Mock Test-PMPing { $true }
            Mock Test-PMTcpPort { $false }
            Mock Test-PMIsLocalTarget { $false }
            $r = Test-PMComputer -Computer ([pscustomobject]@{ Name = 'PC02'; IPAddress = '192.168.10.12' })
            $r.Status | Should -Be 'Inaccessible'
            $r.Detail | Should -BeLike 'WinRM inaccessible*'
        }
    }
    It 'signale un hôte injoignable' {
        InModuleScope PatchManager {
            Mock Test-PMPing { $false }
            Mock Test-PMTcpPort { $false }
            Mock Test-PMIsLocalTarget { $false }
            (Test-PMComputer -Computer ([pscustomobject]@{ Name = 'PC03'; IPAddress = '192.168.10.13' })).Detail | Should -Be 'Hôte injoignable'
        }
    }
}

Describe 'Parties 2/3 - Collecte distante (WinRM simulé)' {
    It 'interroge les postes accessibles, ignore les autres et ferme les sessions' {
        InModuleScope PatchManager {
            . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
            Mock Test-PMComputer {
                foreach ($c in $Computer) {
                    $ok = $c.Name -ne 'PC03'
                    [pscustomobject]@{ Name = $c.Name; IPAddress = $c.IPAddress; Target = $c.IPAddress; IsLocal = $false; Ping = $ok
                        WinRMPort = $ok; WSMan = $ok; Accessible = $ok; Status = $(if ($ok) { 'Accessible' } else { 'Inaccessible' })
                        Detail = $(if ($ok) { 'OK' } else { 'Hôte injoignable' }); CheckedAt = Get-Date }
                }
            }
            Mock New-PMSessionOption { New-Object System.Management.Automation.Remoting.PSSessionOption }
            Mock New-PSSession {
                if ($ComputerName -eq '192.168.10.12') { throw 'Accès refusé' }
                [pscustomobject]@{ ComputerName = [string]$ComputerName[0] }
            }
            Mock Remove-PSSession { } -RemoveParameterType Session
            Mock Invoke-Command -RemoveParameterType Session {
                . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
                foreach ($s in $Session) {
                    $fake = New-FakeHostResult -Name 'PC01' -HotFix 'KB5034441', 'KB5062553'
                    foreach ($rec in @($fake.System) + $fake.HotFixes) {
                        $rec | Add-Member -NotePropertyName PSComputerName -NotePropertyValue $s.ComputerName -PassThru
                    }
                }
            }

            $computers = @(
                [pscustomobject]@{ Name = 'PC01'; IPAddress = '192.168.10.11' },
                [pscustomobject]@{ Name = 'PC02'; IPAddress = '192.168.10.12' },
                [pscustomobject]@{ Name = 'PC03'; IPAddress = '192.168.10.13' }
            )
            $res = @(Invoke-PMCollection -Computer $computers)

            $res.Count | Should -Be 3
            ($res | Where-Object Name -eq 'PC01').Errors -join ';' | Should -Be ''
            ($res | Where-Object Name -eq 'PC01').System.Model | Should -Be 'VirtualBox'
            ($res | Where-Object Name -eq 'PC01').HotFixes.Count | Should -Be 2
            ($res | Where-Object Name -eq 'PC02').Status | Should -Be 'Inaccessible'
            ($res | Where-Object Name -eq 'PC02').Errors -join '' | Should -BeLike '*Accès refusé*'
            ($res | Where-Object Name -eq 'PC03').Status | Should -Be 'Inaccessible'
            Should -Invoke New-PSSession -Times 2 -Exactly
            Should -Invoke Invoke-Command -Times 1 -Exactly
            Should -Invoke Remove-PSSession -Times 1 -Exactly
        }
    }
}

Describe 'Parties 2/3 - Inventaires' {
    BeforeAll {
        $script:hosts = @(
            (New-FakeHostResult -Name 'PC01' -HotFix 'KB5034441', 'KB5062553', 'KB5063878'),
            (New-FakeHostResult -Name 'PC02' -IPAddress '192.168.10.12' -HotFix 'KB5034441' -WUStatus 'Stopped'),
            (New-FakeHostResult -Name 'PC03' -IPAddress '192.168.10.13' -Inaccessible)
        )
    }
    It 'produit une ligne d''inventaire par poste, y compris les inaccessibles' {
        $inv = @(ConvertTo-PMInventory -HostResult $script:hosts)
        $inv.Count | Should -Be 3
        ($inv | Where-Object Poste -eq 'PC01').Windows | Should -Be 'Microsoft Windows 11 Professionnel 24H2'
        ($inv | Where-Object Poste -eq 'PC01').Build | Should -Be '26100.4652'
        ($inv | Where-Object Poste -eq 'PC01').NbMAJInstallees | Should -Be 3
        ($inv | Where-Object Poste -eq 'PC03').Etat | Should -Be 'Inaccessible'
        ($inv | Where-Object Poste -eq 'PC03').Erreur | Should -Be 'Hôte injoignable'
    }
    It 'trie l''inventaire des correctifs par poste puis par date décroissante' {
        $p = @(ConvertTo-PMPatchInventory -HostResult $script:hosts)
        $p.Count | Should -Be 4
        $p[0].Poste | Should -Be 'PC01'
        $p[0].KB | Should -Be 'KB5063878'
        $p[2].KB | Should -Be 'KB5034441'
        $p[3].Poste | Should -Be 'PC02'
    }
    It 'calcule la synthèse par poste (nombre, date et KB du plus récent)' {
        $s = Get-PMPatchSummary -HostResult $script:hosts | Where-Object Poste -eq 'PC01'
        $s.NbCorrectifs | Should -Be 3
        $s.DernierKB | Should -Be 'KB5063878'
    }
    It 'complète Get-HotFix avec l''historique Windows Update et tient compte des désinstallations' {
        $h = New-FakeHostResult -Name 'PC09' -HotFix 'KB1111111' -History @(
            (New-FakeHistory -KB 'KB2222222' -Date (Get-Date '2026-08-01')),
            (New-FakeHistory -KB 'KB3333333' -Date (Get-Date '2026-08-01')),
            (New-FakeHistory -KB 'KB3333333' -Date (Get-Date '2026-08-05') -Operation 2),
            (New-FakeHistory -KB 'KB4444444' -Date (Get-Date '2026-08-01') -ResultCode 4)
        )
        $kbs = (Get-PMInstalledPatch -HostResult $h).KB
        $kbs | Should -Contain 'KB1111111'
        $kbs | Should -Contain 'KB2222222'
        $kbs | Should -Not -Contain 'KB3333333'
        $kbs | Should -Not -Contain 'KB4444444'
    }
    It 'écarte un KB désinstallé hors Windows Update (historique « installé » mais à nouveau applicable)' {
        $h = New-FakeHostResult -Name 'PC09' -HotFix 'KB1111111' -History @(
            (New-FakeHistory -KB 'KB5127648' -Date (Get-Date '2026-10-22')),
            (New-FakeHistory -KB 'KB2267602' -Date (Get-Date '2026-10-22'))
        )
        $h | Add-Member -NotePropertyName PendingUpdates -NotePropertyValue @(
            [pscustomobject]@{ RecordType = 'PendingUpdate'; KB = 'KB5127648'; Title = 'Correctif de sécurité (KB5127648)' }) -Force
        $kbs = (Get-PMInstalledPatch -HostResult $h).KB
        $kbs | Should -Not -Contain 'KB5127648'
        $kbs | Should -Contain 'KB2267602'
        $kbs | Should -Contain 'KB1111111'
    }
    It 'recherche un KB précis sur le parc' {
        $r = @(Find-PMPatch -HostResult $script:hosts -KB 'kb5062553')
        ($r | Where-Object Poste -eq 'PC01').Resultat | Should -Be 'INSTALLÉ'
        ($r | Where-Object Poste -eq 'PC02').Resultat | Should -Be 'ABSENT'
        ($r | Where-Object Poste -eq 'PC03').Resultat | Should -Be 'INACCESSIBLE'
    }
}

Describe 'Partie 4 - Contrôle de conformité' {
    BeforeAll {
        $script:policyFile = Join-Path $script:tmp 'required-patches.txt'
        @(
            '# politique', 'KB5034441;WinRE;*', 'kb5062553;Cumulative Win11;*Windows 11*',
            'KB1234;invalide', 'KB5034441;doublon', 'KB5000001;Win10 seulement;*Windows 10*'
        ) | Set-Content -Path $script:policyFile -Encoding UTF8
        $script:required = @(Read-PMRequiredPatch -Path $script:policyFile -WarningAction SilentlyContinue)
        $script:hosts = @(
            (New-FakeHostResult -Name 'PC01' -HotFix 'KB5034441', 'KB5062553'),
            (New-FakeHostResult -Name 'PC02' -IPAddress '192.168.10.12' -HotFix 'KB5034441'),
            (New-FakeHostResult -Name 'PC03' -IPAddress '192.168.10.13' -Inaccessible),
            (New-FakeHostResult -Name 'PC04' -IPAddress '192.168.10.14' -HotFix 'KB5034441' -Caption 'Microsoft Windows 10 Professionnel' -Build '19045')
        )
        $script:compliance = @(Test-PMCompliance -HostResult $script:hosts -RequiredPatch $script:required)
    }
    It 'lit la politique, normalise les KB et ignore les lignes invalides' {
        $script:required.KB | Should -Be @('KB5034441', 'KB5062553', 'KB5000001')
    }
    It 'déclare CONFORME un poste qui a tous les correctifs applicables' {
        ($script:compliance | Where-Object Poste -eq 'PC01').Etat | Should -Be 'CONFORME'
        ($script:compliance | Where-Object Poste -eq 'PC01').KBRequises | Should -Be 2
    }
    It 'déclare NON CONFORME et liste précisément les KB manquantes' {
        $c = $script:compliance | Where-Object Poste -eq 'PC02'
        $c.Etat | Should -Be 'NON CONFORME'
        $c.KBManquantes | Should -Be 1
        $c.ListeKBManquantes | Should -Be 'KB5062553'
    }
    It 'déclare INACCESSIBLE un poste non joignable' {
        ($script:compliance | Where-Object Poste -eq 'PC03').Etat | Should -Be 'INACCESSIBLE'
    }
    It 'n''exige un correctif que sur les versions de Windows ciblées' {
        $c = $script:compliance | Where-Object Poste -eq 'PC04'
        $c.KBRequises | Should -Be 2
        $c.ListeKBManquantes | Should -Be 'KB5000001'
    }
    It 'horodate le contrôle' {
        $script:compliance[0].DateControle | Should -BeOfType [datetime]
    }
    It 'calcule le taux de conformité sans les postes inaccessibles' {
        Get-PMComplianceRate -Compliance $script:compliance | Should -Be 33.3
    }
    It 'renvoie $null si aucun poste n''a pu être évalué' {
        Get-PMComplianceRate -Compliance @([pscustomobject]@{ Etat = 'INACCESSIBLE' }) | Should -BeNullOrEmpty
    }
}

Describe 'Partie 6 - Rapport de sécurité' {
    BeforeAll {
        $hosts = @(
            (New-FakeHostResult -Name 'PC01' -HotFix 'KB5034441'),
            (New-FakeHostResult -Name 'PC02' -IPAddress '192.168.10.12' -HotFix @() -WUStartType 'Disabled' -WUStatus 'Stopped' -RebootPending $true -FreeGB 5),
            (New-FakeHostResult -Name 'PC03' -IPAddress '192.168.10.13' -Inaccessible)
        )
        $hosts[1].System.Model = '<script>alert(1)</script>'
        $required = @([pscustomobject]@{ KB = 'KB5034441'; Description = 'WinRE'; Target = '*' })
        $script:inv = @(ConvertTo-PMInventory -HostResult $hosts)
        $comp = @(Test-PMCompliance -HostResult $hosts -RequiredPatch $required)
        $script:report = @(New-PMSecurityReport -Inventory $script:inv -Compliance $comp)
        $script:summary = Get-PMParcSummary -Report $script:report
    }
    It 'contient tous les champs demandés pour chaque poste' {
        $expected = 'Poste', 'AdresseIP', 'Accessibilite', 'Windows', 'DernierDemarrage', 'WindowsUpdate',
                    'KBRequises', 'KBManquantes', 'ListeKBManquantes', 'Conformite', 'DateControle'
        foreach ($p in $expected) { $script:report[0].PSObject.Properties.Name | Should -Contain $p }
    }
    It 'produit la synthèse globale du parc' {
        $script:summary.NbPostes | Should -Be 3
        $script:summary.NbAccessibles | Should -Be 2
        $script:summary.NbInaccessibles | Should -Be 1
        $script:summary.NbConformes | Should -Be 1
        $script:summary.NbNonConformes | Should -Be 1
        $script:summary.NbCorrectifsManquants | Should -Be 1
        $script:summary.TauxConformite | Should -Be 50
    }
    It 'liste uniquement les postes nécessitant une intervention' {
        (Get-PMInterventionList -Report $script:report).Poste | Should -Be @('PC02', 'PC03')
    }
    It 'détecte les points d''attention (WU désactivé, redémarrage, disque)' {
        $a = @(Get-PMAttentionPoint -Inventory $script:inv | Where-Object Poste -eq 'PC02')
        $a.Count | Should -Be 3
    }
    It 'génère un rapport HTML autonome dont les données sont encodées (anti-XSS)' {
        $path = Join-Path $script:tmp 'report.html'
        Export-PMHtmlReport -Report $script:report -Summary $script:summary -Intervention (Get-PMInterventionList -Report $script:report) -Path $path | Out-Null
        $html = Get-Content -Path $path -Raw
        $html | Should -Match 'Synthèse globale du parc'
        $html | Should -Match 'Postes nécessitant une intervention \(2\)'
        $html | Should -Not -Match '<script>'
        $html | Should -Not -Match 'https?://'
    }
    It 'neutralise les formules dans les exports CSV (injection CSV)' {
        $path = Join-Path $script:tmp 'x.csv'
        Export-PMCsv -InputObject @([pscustomobject]@{ A = '=cmd|/c calc!A1'; B = '-5'; C = '@SUM(1)'; D = 'normal' }) -Path $path
        $row = Import-Csv -Path $path -Delimiter ';'
        $row.A | Should -Be "'=cmd|/c calc!A1"
        $row.B | Should -Be '-5'
        $row.C | Should -Be "'@SUM(1)"
        $row.D | Should -Be 'normal'
    }
}

Describe 'Partie 6 - Journal PatchManager.log' {
    It 'respecte le format "date ; élément ; élément"' {
        Write-PMLog 'PC02', 'Non conforme', 'KB5034441'
        $last = Get-Content -Path $script:logFile | Select-Object -Last 1
        $last | Should -Match '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2} ; PC02 ; Non conforme ; KB5034441$'
    }
    It 'préfixe les erreurs par ERREUR' {
        Write-PMLog -Level ERROR -Message 'Notification non envoyée'
        Get-Content -Path $script:logFile | Select-Object -Last 1 | Should -Match ' ; ERREUR ; Notification non envoyée$'
    }
    It 'empêche l''injection de fausses lignes de journal' {
        Write-PMLog "PC09`r`n06/09/2026 09:00:05 ; PC09 ; Conforme"
        (Get-Content -Path $script:logFile | Select-Object -Last 1) | Should -Match '^\d{2}/\d{2}/\d{4} .* ; PC09 06/09/2026'
    }
}

Describe 'Partie 7 - Notification' {
    BeforeAll {
        $script:okReport = @([pscustomobject]@{ Poste = 'PC01'; AdresseIP = '1.1.1.1'; Conformite = 'CONFORME'; ListeKBManquantes = ''; Erreur = '' })
        $script:badReport = @(
            [pscustomobject]@{ Poste = 'PC01'; AdresseIP = '192.168.10.11'; Conformite = 'CONFORME'; ListeKBManquantes = ''; Erreur = '' },
            [pscustomobject]@{ Poste = 'PC02'; AdresseIP = '192.168.10.12'; Conformite = 'NON CONFORME'; ListeKBManquantes = 'KB5034441, KB5062553'; Erreur = '' },
            [pscustomobject]@{ Poste = 'PC05'; AdresseIP = '192.168.10.15'; Conformite = 'INACCESSIBLE'; ListeKBManquantes = ''; Erreur = 'Hôte injoignable' }
        )
    }
    It 'n''envoie rien quand aucune anomalie n''est détectée' {
        $folder = New-Item -Path (Join-Path $script:tmp 'run-ok') -ItemType Directory -Force
        Send-PMNotification -Report $script:okReport -RunFolder $folder.FullName | Should -BeNullOrEmpty
        Test-Path (Join-Path $folder.FullName 'Notification.txt') | Should -BeFalse
        Get-Content -Path $script:logFile | Select-Object -Last 1 | Should -Match 'Aucune anomalie'
    }
    It 'construit le message au format attendu' {
        $m = New-PMNotificationMessage -Report $script:badReport
        $m.Subject | Should -Be '[PATCH MANAGEMENT] Anomalies détectées'
        $m.Body | Should -Match 'Postes contrôlés\s+: 3'
        $m.Body | Should -Match 'Postes non conformes\s+: 1'
        $m.Body | Should -Match 'Postes inaccessibles\s+: 1'
        $m.Body | Should -Match 'PC02 \(192.168.10.12\) : NON CONFORME'
        $m.Body | Should -Match 'KB5062553 manquante'
        $m.Body | Should -Match 'PC05 \(192.168.10.15\) : INACCESSIBLE'
    }
    It 'journalise l''envoi réussi' {
        $folder = New-Item -Path (Join-Path $script:tmp 'run-ko') -ItemType Directory -Force
        Send-PMNotification -Report $script:badReport -RunFolder $folder.FullName | Should -BeTrue
        Test-Path (Join-Path $folder.FullName 'Notification.txt') | Should -BeTrue
        Get-Content -Path $script:logFile | Select-Object -Last 1 | Should -Match ' ; Notification enregistrée dans .*admin@entreprise.local'
    }
    It 'envoie le courriel SMTP avec le rapport joint et journalise le destinataire' {
        InModuleScope PatchManager -Parameters @{ Report = $script:badReport; Tmp = $script:tmp; Log = $script:logFile } {
            param($Report, $Tmp, $Log)
            $saved = $script:PMConfig.Notification
            $script:PMConfig.Notification = @{ Enabled = $true; Method = 'Smtp'; SmtpServer = 'smtp.entreprise.local'; SmtpPort = 25; From = 'pm@entreprise.local'; To = @('admin@entreprise.local') }
            Mock Send-MailMessage { }
            try {
                $folder = New-Item -Path (Join-Path $Tmp 'run-smtp-ok') -ItemType Directory -Force
                $att = Join-Path $folder.FullName 'SecurityReport.html'
                Set-Content -Path $att -Value '<html></html>'
                Send-PMNotification -Report $Report -RunFolder $folder.FullName -Attachment $att | Should -BeTrue
                Should -Invoke Send-MailMessage -Times 1 -Exactly -ParameterFilter {
                    $Subject -eq '[PATCH MANAGEMENT] Anomalies détectées' -and $Attachments -contains $att -and $To -contains 'admin@entreprise.local'
                }
                Get-Content -Path $Log | Select-Object -Last 1 | Should -Match ' ; Notification envoyée à admin@entreprise.local$'
            } finally { $script:PMConfig.Notification = $saved }
        }
    }
    It 'journalise l''échec d''envoi SMTP sans interrompre le script' {
        InModuleScope PatchManager -Parameters @{ Report = $script:badReport; Tmp = $script:tmp; Log = $script:logFile } {
            param($Report, $Tmp, $Log)
            $saved = $script:PMConfig.Notification
            $script:PMConfig.Notification = @{ Enabled = $true; Method = 'Smtp'; SmtpServer = 'smtp.invalid'; SmtpPort = 25; From = 'a@b.c'; To = @('admin@entreprise.local') }
            Mock Send-MailMessage { throw 'Serveur SMTP injoignable' }
            try {
                $folder = New-Item -Path (Join-Path $Tmp 'run-smtp') -ItemType Directory -Force
                Send-PMNotification -Report $Report -RunFolder $folder.FullName -WarningAction SilentlyContinue | Should -BeFalse
                Get-Content -Path $Log | Select-Object -Last 1 | Should -Match ' ; ERREUR ; Notification non envoyée'
            } finally { $script:PMConfig.Notification = $saved }
        }
    }
}

Describe 'Chaîne complète - Invoke-PMAudit' {
    BeforeAll {
        $computers = Join-Path $script:tmp 'parc.txt'
        'PC01;192.168.10.11', 'PC02;192.168.10.12', 'PC03;192.168.10.13' | Set-Content -Path $computers -Encoding UTF8
        $policy = Join-Path $script:tmp 'policy.txt'
        'KB5034441;WinRE;*', 'KB5062553;Cumulative;*' | Set-Content -Path $policy -Encoding UTF8
        $script:auditLog = Join-Path $script:tmp 'audit.log'
        Import-PMConfiguration -Override @{
            ComputersFile = $computers; RequiredPatchesFile = $policy; LogFile = $script:auditLog
            OutputRoot = (Join-Path $script:tmp 'AuditOutput')
            Notification = @{ Enabled = $true; Method = 'File'; To = @('admin@entreprise.local'); AttachCsv = $true }
        } | Out-Null
        InModuleScope PatchManager {
            Mock Invoke-PMCollection {
                . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
                @(
                    (New-FakeHostResult -Name 'PC01' -HotFix 'KB5034441', 'KB5062553'),
                    (New-FakeHostResult -Name 'PC02' -IPAddress '192.168.10.12' -HotFix 'KB5034441'),
                    (New-FakeHostResult -Name 'PC03' -IPAddress '192.168.10.13' -Inaccessible -Detail 'WinRM inaccessible (port 5985 fermé ou filtré)')
                )
            }
        }
        $script:audit = Invoke-PMAudit -WarningAction SilentlyContinue
    }
    It 'produit tous les fichiers attendus' {
        foreach ($f in 'SHA256SUMS.txt', 'Inventory.csv', 'PatchesInventory.csv', 'PatchesSummary.csv', 'ComplianceReport.csv', 'SecurityReport.csv', 'SecurityReport.html', 'Interventions.csv', 'Notification.txt') {
            Test-Path (Join-Path $script:audit.RunFolder $f) | Should -BeTrue -Because $f
        }
    }
    It 'calcule le bon taux de conformité' {
        $script:audit.ComplianceRate | Should -Be 50
    }
    It 'écrit le journal dans l''ordre attendu par l''énoncé' {
        $log = Get-Content -Path $script:auditLog | ForEach-Object { ($_ -split ' ; ', 2)[1] }
        $log[0] | Should -Be "Début de l'audit"
        $log | Should -Contain 'PC01 ; Accessible'
        $log | Should -Contain 'PC01 ; Conforme'
        $log | Should -Contain 'PC02 ; Non conforme ; KB5062553'
        $log | Should -Contain 'PC03 ; WinRM inaccessible'
        ($log | Where-Object { $_ -like 'Rapport généré*' }) | Should -Not -BeNullOrEmpty
        ($log | Where-Object { $_ -like 'Notification enregistrée*' }) | Should -Not -BeNullOrEmpty
        $log[-1] | Should -Be "Fin de l'audit"
    }
    It 'exporte ComplianceReport.csv avec séparateur ; lisible par Excel' {
        $rows = Import-Csv -Path (Join-Path $script:audit.RunFolder 'ComplianceReport.csv') -Delimiter ';'
        ($rows | Where-Object Poste -eq 'PC02').Etat | Should -Be 'NON CONFORME'
        ($rows | Where-Object Poste -eq 'PC03').KBManquantes | Should -Be '—'
    }
    It 'détecte toute modification d''un rapport après sa génération (intégrité SHA-256)' {
        @(Test-PMIntegrity -RunFolder $script:audit.RunFolder | Where-Object Etat -ne 'INTACT').Count | Should -Be 0
        $csv = Join-Path $script:audit.RunFolder 'ComplianceReport.csv'
        (Get-Content $csv -Raw) -replace 'NON CONFORME', 'CONFORME' | Set-Content $csv -Encoding UTF8
        (Test-PMIntegrity -RunFolder $script:audit.RunFolder | Where-Object Fichier -eq 'ComplianceReport.csv').Etat | Should -Be 'MODIFIÉ'
        Get-Content -Path $script:auditLog | Where-Object { $_ -match 'Empreinte SHA-256 du manifeste' } | Should -Not -BeNullOrEmpty
    }
    It 'BONUS : un second audit compare avec le précédent (Evolution.csv, section HTML, historique)' {
        $second = Invoke-PMAudit -WarningAction SilentlyContinue
        $second.RunFolder | Should -Not -Be $script:audit.RunFolder
        $second.Trend.PreviousAudit | Should -Be (Split-Path $script:audit.RunFolder -Leaf)
        Test-Path (Join-Path $second.RunFolder 'Evolution.csv') | Should -BeTrue
        Get-Content (Join-Path $second.RunFolder 'SecurityReport.html') -Raw | Should -Match 'Évolution de la conformité'
        @(Get-PMHistory).Count | Should -Be 2
    }
}

Describe 'BONUS - Historique et tendance' {
    BeforeAll {
        $script:histRoot = Join-Path $script:tmp 'HistOutput'
        Import-PMConfiguration -Override @{ OutputRoot = $script:histRoot; LogFile = (Join-Path $script:tmp 'hist.log') } | Out-Null
        # Audit précédent : PC01 conforme, PC02 non conforme, PC03 conforme
        $prev = New-Item -Path (Join-Path $script:histRoot '20261001-090000') -ItemType Directory -Force
        @(
            [pscustomobject]@{ Poste = 'PC01'; Conformite = 'CONFORME' },
            [pscustomobject]@{ Poste = 'PC02'; Conformite = 'NON CONFORME' },
            [pscustomobject]@{ Poste = 'PC03'; Conformite = 'CONFORME' }
        ) | Export-Csv -Path (Join-Path $prev.FullName 'SecurityReport.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8
        $script:current = (New-Item -Path (Join-Path $script:histRoot '20261008-090000') -ItemType Directory -Force).FullName
        # Audit courant : PC01 régresse, PC02 corrigé, PC03 inchangé, PC04 nouveau
        $script:curReport = @(
            [pscustomobject]@{ Poste = 'PC01'; Conformite = 'NON CONFORME' },
            [pscustomobject]@{ Poste = 'PC02'; Conformite = 'CONFORME' },
            [pscustomobject]@{ Poste = 'PC03'; Conformite = 'CONFORME' },
            [pscustomobject]@{ Poste = 'PC04'; Conformite = 'INACCESSIBLE' }
        )
        $script:trend = Get-PMTrend -Report $script:curReport -RunFolder $script:current
    }
    It 'détecte les régressions, les corrections et les nouveaux postes' {
        $script:trend.PreviousAudit | Should -Be '20261001-090000'
        $script:trend.Regressions.Poste | Should -Be @('PC01')
        $script:trend.Fixed.Poste | Should -Be @('PC02')
        ($script:trend.Changes | Where-Object Poste -eq 'PC03').Evolution | Should -Be 'Inchangé'
        ($script:trend.Changes | Where-Object Poste -eq 'PC04').Evolution | Should -Be 'Nouveau'
    }
    It 'calcule l''évolution du taux de conformité (hors inaccessibles)' {
        $script:trend.PreviousRate | Should -Be 66.7
        $script:trend.CurrentRate | Should -Be 66.7
        $script:trend.Delta | Should -Be 0
    }
    It 'renvoie $null s''il n''y a pas d''audit précédent' {
        Get-PMTrend -Report $script:curReport -RunFolder (Join-Path $script:histRoot '20260101-000000') | Should -BeNullOrEmpty
    }
    It 'alimente History.csv et produit un graphique SVG autonome' {
        foreach ($t in 50, 75.5) {
            Add-PMHistory -Summary ([pscustomobject]@{ NbPostes = 3; NbAccessibles = 3; NbInaccessibles = 0; NbConformes = 2; NbNonConformes = 1; NbCorrectifsManquants = 1; TauxConformite = $t }) -RunFolder $script:current
        }
        $h = @(Get-PMHistory)
        $h.Count | Should -Be 2
        $h[1].TauxConformite | Should -Be '75.5'
        $svg = ConvertTo-PMTrendSvg -History $h
        $svg | Should -Match '^<svg'
        $svg | Should -Match '<polyline'
        $svg | Should -Not -Match 'https?://'
    }
    It 'met les régressions en avant dans la notification' {
        $report = @([pscustomobject]@{ Poste = 'PC01'; AdresseIP = '1.1.1.1'; Conformite = 'NON CONFORME'; ListeKBManquantes = 'KB5000001'; Erreur = '' })
        (New-PMNotificationMessage -Report $report -Trend $script:trend).Body | Should -Match "régression depuis l'audit 20261001-090000"
    }
}

Describe 'BONUS - Remédiation' {
    BeforeAll {
        Import-PMConfiguration -Override @{ LogFile = (Join-Path $script:tmp 'remed.log'); OutputRoot = (Join-Path $script:tmp 'RemOut') } | Out-Null
    }
    It 'pilote la remédiation à distance, ignore les postes injoignables et journalise' {
        InModuleScope PatchManager -Parameters @{ Log = (Join-Path $script:tmp 'remed.log') } {
            param($Log)
            Mock Test-PMComputer {
                foreach ($c in $Computer) {
                    $ok = $c.Name -ne 'PC03'
                    [pscustomobject]@{ Name = $c.Name; IPAddress = $c.IPAddress; Target = $c.IPAddress; IsLocal = $false; Accessible = $ok; Detail = $(if ($ok) { 'OK' } else { 'Hôte injoignable' }) }
                }
            }
            Mock Invoke-Command { [pscustomobject]@{ Trouvees = 1; Installees = 1; Echecs = 0; RedemarrageRequis = $true; Details = 'KB5063878 - Mise à jour cumulative'; Erreur = $null } }
            $computers = @([pscustomobject]@{ Name = 'PC02'; IPAddress = '192.168.10.12' }, [pscustomobject]@{ Name = 'PC03'; IPAddress = '192.168.10.13' })
            $r = @(Invoke-PMRemediation -Computer $computers -KB 'KB5063878' -Confirm:$false)
            ($r | Where-Object Poste -eq 'PC02').Installees | Should -Be 1
            ($r | Where-Object Poste -eq 'PC02').RedemarrageRequis | Should -BeTrue
            ($r | Where-Object Poste -eq 'PC03').Detail | Should -BeLike 'Ignoré*'
            Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -contains 'KB5063878' }
            (Get-Content $Log) -join "`n" | Should -Match 'PC02 ; Remédiation terminée : 1 trouvée\(s\), 1 installée\(s\)'
        }
    }
    It 'ne modifie rien avec -WhatIf' {
        InModuleScope PatchManager {
            Mock Test-PMComputer { [pscustomobject]@{ Name = 'PC02'; IPAddress = '192.168.10.12'; Target = '192.168.10.12'; IsLocal = $false; Accessible = $true; Detail = 'OK' } }
            Mock Invoke-Command { throw 'ne doit pas être appelé' }
            $r = Invoke-PMRemediation -Computer ([pscustomobject]@{ Name = 'PC02'; IPAddress = '192.168.10.12' }) -WhatIf
            $r.Detail | Should -BeLike 'Annulé*'
            Should -Invoke Invoke-Command -Times 0
        }
    }
    It 'consigne l''échec d''un poste sans interrompre les autres' {
        InModuleScope PatchManager {
            Mock Test-PMComputer { foreach ($c in $Computer) { [pscustomobject]@{ Name = $c.Name; IPAddress = $c.IPAddress; Target = $c.IPAddress; IsLocal = $false; Accessible = $true; Detail = 'OK' } } }
            Mock Invoke-Command { if ($ComputerName -eq '10.0.0.1') { throw 'Accès refusé' } else { [pscustomobject]@{ Trouvees = 0; Installees = 0; Echecs = 0; RedemarrageRequis = $false; Details = ''; Erreur = $null } } }
            $r = @(Invoke-PMRemediation -Computer @([pscustomobject]@{ Name = 'A'; IPAddress = '10.0.0.1' }, [pscustomobject]@{ Name = 'B'; IPAddress = '10.0.0.2' }) -ScanOnly -Confirm:$false)
            $r[0].Detail | Should -BeLike 'Échec : *Accès refusé*'
            $r[1].Mode | Should -Be 'Recherche'
            $r[1].Trouvees | Should -Be 0
        }
    }
}
