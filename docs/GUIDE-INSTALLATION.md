# Guide d'installation et de démonstration — pas à pas

Ce guide décrit la mise en place complète du laboratoire puis l'exécution de chaque partie du projet.
Compter environ 2 h pour l'installation des machines virtuelles, puis 30 min pour les tests.

> Convention : les blocs `powershell` s'exécutent dans une console **PowerShell en administrateur**
> (clic droit sur *Windows PowerShell* → *Exécuter en tant qu'administrateur*), sauf indication contraire.

---

## 0. Architecture du laboratoire

| Rôle | Machine | Nom | Adresse IP (réseau privé hôte) |
|---|---|---|---|
| Poste d'administration | PC hôte Windows | (nom actuel) | 192.168.56.1 |
| Poste supervisé n°1 | VM Windows 10/11 | PC01 | 192.168.56.11 |
| Poste supervisé n°2 | VM Windows 10/11 | PC02 | 192.168.56.12 |
| Poste fictif (éteint) | — | PC03 | 192.168.56.13 |

`PC03` n'existe pas : il permet de démontrer la gestion d'un poste **inaccessible**.

Chaque VM a **deux cartes réseau** :
1. **NAT** : accès Internet, pour Windows Update ;
2. **Réseau privé hôte** (*Host-only*, `192.168.56.0/24`) : communication entre le PC hôte et les VM.

---

## 1. Création des machines virtuelles (VirtualBox)

1. Installer **VirtualBox 7** : <https://www.virtualbox.org/wiki/Downloads>.
2. Télécharger une ISO **Windows 11 Entreprise (évaluation 90 jours)** depuis le
   *Microsoft Evaluation Center* (<https://www.microsoft.com/fr-fr/evalcenter>). Windows 10 convient aussi.
3. Dans VirtualBox : *Fichier → Outils → Gestionnaire de réseau → Réseaux privés hôte* : vérifier
   qu'il existe un réseau `192.168.56.1/24` (sinon *Créer*). Désactiver son serveur DHCP.
4. Créer la VM **PC01** : 4 Go de RAM, 2 processeurs, disque de 64 Go, l'ISO Windows.
   VirtualBox 7 émule le TPM 2.0 et le Secure Boot exigés par Windows 11.
5. *Configuration → Réseau* : **Carte 1** = NAT ; **Carte 2** = Réseau privé hôte (192.168.56.1).
6. Installer Windows. Choisir *Je n'ai pas de clé de produit*, puis créer un compte **local**
   (par exemple `adminlab`, avec un mot de passe robuste).
7. Répéter pour **PC02**, avec **le même compte local et le même mot de passe** (cela simplifie
   l'authentification en groupe de travail : un seul jeu d'identifiants pour tout le parc).

> Astuce : installez Windows une seule fois, puis clonez la VM (*Clone intégral*, avec la
> *politique d'adresse MAC* « Générer de nouvelles adresses MAC »). Exécutez ensuite
> `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /reboot` dans le clone pour
> obtenir un SID unique.

---

## 2. Configuration réseau et nom des VM

Sur **PC01**, en administrateur :

```powershell
# Identifier la carte "réseau privé hôte" (celle qui n'a pas d'accès Internet)
Get-NetAdapter | Format-Table Name, InterfaceDescription, ifIndex, Status

# Remplacer "Ethernet 2" par le nom de la 2e carte
New-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress 192.168.56.11 -PrefixLength 24
Rename-Computer -NewName PC01 -Restart
```

Sur **PC02**, même chose avec `192.168.56.12` et `-NewName PC02`.

**Question 1 — vérifier la connectivité** (depuis l'hôte, console normale) :

```powershell
Test-Connection -ComputerName 192.168.56.11 -Count 2
Test-NetConnection -ComputerName 192.168.56.11 -Port 5985    # échouera tant que WinRM n'est pas activé
```

Par défaut, le pare-feu Windows **bloque le ping** sur les VM : c'est normal, le script de
préparation l'autorise uniquement depuis le poste d'administration (étape 4).

---

## 3. Récupération du projet sur le poste d'administration

```powershell
cd $HOME\Documents
git clone https://github.com/Pratheep927/securite-systeme-d-exploitation.git
cd securite-systeme-d-exploitation
# Si le projet a été téléchargé en ZIP : retirer la marque « provenant d'Internet »
Get-ChildItem -Recurse -File | Unblock-File
# Autoriser l'exécution des scripts locaux pour l'utilisateur courant
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Modifier `computers.txt` :

```
PC01;192.168.56.11
PC02;192.168.56.12
PC03;192.168.56.13
```

Copier aussi le dossier du projet sur chaque VM (dossier partagé VirtualBox, clé USB ou `git clone`),
car le script de préparation s'exécute **sur** les postes supervisés.

---

## 4. Activation de PowerShell Remoting (Partie 1, questions 4 à 6)

### 4.1 Sur chaque VM (PC01, PC02), en administrateur

```powershell
cd <dossier du projet>
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\setup\Initialize-ManagedNode.ps1 -AdminStationIP 192.168.56.1
```

Le script passe le profil réseau en *Privé*, exécute `Enable-PSRemoting`, limite les règles de
pare-feu WinRM à **192.168.56.1**, autorise le ping depuis cette seule adresse, désactive Basic,
CredSSP et le trafic non chiffré, puis affiche un état final.

Vérifications manuelles :

```powershell
Get-Service WinRM
winrm enumerate winrm/config/listener
Test-WSMan -ComputerName localhost
```

### 4.2 Sur le poste d'administration (hôte), en administrateur

```powershell
.\setup\Initialize-AdminStation.ps1
```

Ce script ajoute **uniquement** les postes de `computers.txt` à `TrustedHosts` (jamais `*`), durcit
le client WinRM, protège les dossiers `Output`, `Logs` et `secrets`, puis lance `Test-WSMan` sur chaque poste.

### 4.3 Premières sessions distantes (console normale)

```powershell
$cred = Get-Credential adminlab            # compte local commun aux VM

Test-WSMan -ComputerName 192.168.56.11

# Session interactive (question 5)
Enter-PSSession -ComputerName 192.168.56.11 -Credential $cred
hostname
whoami
Get-Service wuauserv
Get-HotFix | Select-Object -First 5
Exit-PSSession

# Exécution non interactive (question 6)
Invoke-Command -ComputerName 192.168.56.11, 192.168.56.12 -Credential $cred -ScriptBlock { Get-ComputerInfo -Property CsName, OsName }
.\scripts\Partie1-CommandeDistante.ps1 -Credential $cred
```

### 4.4 Disponibilité des postes (question 3)

```powershell
.\scripts\Partie1-TestParc.ps1 -ExportCsv
```

Résultat attendu : PC01 et PC02 *Accessible*, PC03 *Inaccessible (Hôte injoignable)*.

---

## 5. Inventaires (Parties 2 et 3)

```powershell
.\scripts\Partie2-Inventaire.ps1 -Credential $cred     # -> Output\<date>\Inventory.csv
.\scripts\Partie3-Correctifs.ps1 -Credential $cred     # -> PatchesInventory.csv + synthèse par poste
.\scripts\Rechercher-KB.ps1 -KB KB5034441 -Credential $cred
```

Ouvrir les CSV dans Excel : le séparateur `;` et l'encodage UTF-8 sont reconnus directement.

---

## 6. Politique de conformité (Partie 4)

Pour une démonstration parlante, il faut **un poste conforme et un poste non conforme** :

1. Mettre **PC01** à jour : *Paramètres → Windows Update → Rechercher des mises à jour*, puis redémarrer.
2. Sur **PC02**, ne pas installer les dernières mises à jour (*Suspendre les mises à jour* pendant 1 semaine).
3. Lister les correctifs de PC01 :

   ```powershell
   Invoke-Command -ComputerName 192.168.56.11 -Credential $cred { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn }
   ```

4. Renseigner `required-patches.txt` avec, par exemple :
   - la dernière mise à jour cumulative de sécurité (*Security Update*) installée sur PC01 ;
   - un correctif présent sur les deux postes (ex. une mise à jour de la pile de maintenance).

   Les numéros de KB officiels se trouvent sur <https://msrc.microsoft.com/update-guide> et dans
   l'« historique des mises à jour » de votre version de Windows sur <https://support.microsoft.com>.
   Le 3e champ (`*Windows 11*`, `*Windows 10*`) restreint un correctif aux versions concernées.

5. Lancer le contrôle :

   ```powershell
   .\scripts\Partie4-Conformite.ps1 -Credential $cred
   ```

Résultat attendu : PC01 **CONFORME**, PC02 **NON CONFORME** (KB manquante affichée), PC03
**INACCESSIBLE**, taux de conformité 50 % (calculé sans PC03).

---

## 7. Notification par courriel (Partie 7) avec un serveur SMTP de test

Pour ne pas utiliser de vraie messagerie, installer sur le poste d'administration un serveur
SMTP local qui affiche les messages reçus, **Papercut SMTP** :

```powershell
winget install ChangemakerStudios.Papercut-SMTP
```

(ou le télécharger sur <https://github.com/ChangemakerStudios/Papercut-SMTP/releases>). Le lancer :
il écoute sur `localhost:25`.

La configuration par défaut (`config\PatchManager.config.psd1`) envoie déjà à `localhost:25`. Pour
un vrai serveur avec authentification, enregistrer les identifiants **chiffrés** (jamais en clair) :

```powershell
.\setup\Save-PMSecret.ps1 -Type Smtp      # puis CredentialFile = 'secrets\smtp.cred.xml' dans la configuration
```

---

## 8. Audit complet (Parties 6 et 7)

```powershell
.\Invoke-PatchAudit.ps1 -Credential $cred -OpenReport
```

Vérifier ensuite :
- le rapport HTML qui s'ouvre (synthèse, postes nécessitant une intervention, détail par poste) ;
- `Output\<date>\` : tous les CSV, `Notification.txt` et `SHA256SUMS.txt` ;
- `Logs\PatchManager.log` (début de l'audit, état de chaque poste, rapport généré, notification, fin) ;
- le courriel reçu dans Papercut, avec le rapport en pièce jointe.

Test de l'absence de notification : mettre temporairement dans `computers.txt` uniquement PC01
(poste conforme) → le journal indique « Aucune anomalie détectée - aucune notification envoyée ».

Test d'échec de notification : fermer Papercut puis relancer → `ERREUR ; Notification non envoyée`.

---

## 9. Sécurisation (Partie 8)

### 9.1 Audit de la configuration WinRM

```powershell
.\scripts\Partie8-AuditRemoting.ps1 -Credential $cred
```

Contrôle des utilisateurs autorisés, des modes d'authentification, des écouteurs, des règles de
pare-feu (sources autorisées), de `LocalAccountTokenFilterPolicy`, de la journalisation PowerShell.

Vérification manuelle du mode d'authentification réellement utilisé :

```powershell
Invoke-Command -ComputerName 192.168.56.11 -Credential $cred { [System.Security.Principal.WindowsIdentity]::GetCurrent().AuthenticationType }
# -> NTLM (groupe de travail, connexion par IP). En domaine avec un nom : Kerberos.
```

### 9.2 Compte d'audit non administrateur avec JEA

Sur **chaque VM**, en administrateur :

```powershell
.\jea\Install-PatchAuditJEA.ps1 -CreateServiceAccount
```

Sur le poste d'administration :

```powershell
$audit = Get-Credential svc-patchaudit
# Seules quelques commandes sont visibles :
Invoke-Command -ComputerName 192.168.56.11 -ConfigurationName PatchAudit -Credential $audit { Get-Command }
# Une commande non autorisée est refusée :
Invoke-Command -ComputerName 192.168.56.11 -ConfigurationName PatchAudit -Credential $audit { Stop-Computer }
# Le compte n'a pas accès au point de terminaison standard :
Invoke-Command -ComputerName 192.168.56.11 -Credential $audit { whoami }
```

Puis, dans `config\PatchManager.config.psd1`, mettre `ConfigurationName = 'PatchAudit'` et lancer :

```powershell
.\Invoke-PatchAudit.ps1 -Credential $audit
```

Les transcriptions des sessions JEA sont dans `C:\ProgramData\PatchAuditJEA\Transcripts` sur chaque VM.

### 9.3 Protection des fichiers, secrets, journalisation

```powershell
.\setup\Protect-PMData.ps1                          # ACL sur Output, Logs, secrets
icacls .\Logs                                       # vérifier les droits
.\setup\Save-PMSecret.ps1 -Type WinRM               # identifiants WinRM chiffrés DPAPI
.\Invoke-PatchAudit.ps1 -CredentialFile .\secrets\winrm.cred.xml
.\scripts\Verifier-Integrite.ps1                    # empreintes SHA-256 de tous les audits
```

Sur chaque VM (traçabilité) :

```powershell
.\setup\Enable-PSAuditLogging.ps1 -DisablePowerShellV2
Get-WinEvent -LogName 'Microsoft-Windows-PowerShell/Operational' -MaxEvents 10 | Where-Object Id -eq 4104
```

### 9.4 (Optionnel) WinRM sur HTTPS

```powershell
# Sur chaque VM :
.\setup\Initialize-ManagedNode.ps1 -AdminStationIP 192.168.56.1 -EnableHttps
# Copier PC01-winrm.cer sur l'hôte, puis sur l'hôte (admin) :
Import-Certificate -FilePath .\PC01-winrm.cer -CertStoreLocation Cert:\LocalMachine\Root
# Dans la configuration : UseSSL = $true
```

### 9.5 (Optionnel) Audit planifié quotidien

```powershell
.\setup\Register-PatchAuditTask.ps1 -At 07:00 -RunAs (Get-Credential)
```

---

## 10. Bonus — Remédiation et suivi dans le temps

```powershell
# Simulation : quelles mises à jour de sécurité manquent sur les postes non conformes ?
.\scripts\Bonus-Remediation.ps1 -Credential $cred -ScanOnly
# Correction des KB manquantes (confirmation demandée), puis nouvel audit de contrôle
.\scripts\Bonus-Remediation.ps1 -Credential $cred -AuditAfter
# Simulation sans rien exécuter
.\scripts\Bonus-Remediation.ps1 -Computer PC02 -KB KB5063878 -Credential $cred -WhatIf
```

Le suivi dans le temps est automatique : à partir du 2e audit, le rapport HTML contient la section
« Évolution de la conformité » (régressions, postes corrigés, graphique) et `Output\History.csv`
conserve l'historique.

## 11. Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `WinRM cannot complete the operation` | Port 5985 fermé, VM éteinte, mauvaise IP | `Test-NetConnection IP -Port 5985` ; relancer `Initialize-ManagedNode.ps1` |
| `The WinRM client cannot process the request ... TrustedHosts` | Connexion par IP hors domaine | `.\setup\Initialize-AdminStation.ps1` |
| `Access is denied` | Mauvais identifiants, compte non administrateur sur l'endpoint standard | Vérifier `$cred` ; utiliser JEA pour un compte non admin |
| `Enable-PSRemoting` : réseau public | Profil réseau Public | Le script le passe en Privé ; sinon `Set-NetConnectionProfile -NetworkCategory Private` |
| Ping KO mais WinRM OK | ICMP bloqué par le pare-feu | Normal : le script considère le poste accessible (WinRM fait foi) |
| Caractères accentués illisibles | Script ré-enregistré sans BOM | `.\tools\Set-Utf8Bom.ps1` |
| `n'est pas signé numériquement` | Fichiers téléchargés depuis Internet | `Get-ChildItem -Recurse | Unblock-File` |
