# Sécurité des systèmes d'exploitation — Système de gestion des mises à jour en PowerShell

Solution simplifiée de **Patch Management Windows** : à partir d'un poste d'administration
central, elle inventorie un parc de postes Windows, collecte les correctifs installés via
**PowerShell Remoting / WinRM**, contrôle leur conformité à une politique de correctifs
obligatoires, produit des rapports CSV/HTML, journalise chaque étape et notifie
l'administrateur en cas d'anomalie.

```
 computers.txt ─► Test des postes ─► Connexion WinRM ─► Collecte (Get-HotFix + historique WU)
                  (ICMP, port,        (sessions           │
                   Test-WSMan)         parallèles)        ▼
 required-patches.txt ───────────────────────────► Contrôle de conformité
                                                          │
            PatchManager.log ◄── Rapports CSV / HTML ◄── Détection des anomalies ──► Notification
                                 + SHA256SUMS.txt                                   (si anomalie)
```

## Démarrage rapide

Sur le **poste d'administration** (Windows PowerShell 5.1 ou PowerShell 7) :

```powershell
# 1. Adapter l'inventaire et la politique
notepad .\computers.txt            # NOM;IP
notepad .\required-patches.txt     # KB;Description;Cible

# 2. Lancer l'audit complet
.\Invoke-PatchAudit.ps1 -Credential (Get-Credential) -OpenReport
```

**Vidéo de démonstration :** <https://www.youtube.com/watch?v=ZuLn_roc-14>

Les résultats sont écrits dans `Output\<AAAAMMJJ-HHmmss>\` et le journal dans `Logs\PatchManager.log`.

La préparation complète du laboratoire (machines virtuelles, WinRM, pare-feu…) est décrite pas à pas
dans **[docs/GUIDE-INSTALLATION.md](docs/GUIDE-INSTALLATION.md)**.

## Correspondance avec l'énoncé

| Partie | Script | Fichiers produits |
|---|---|---|
| 1 — Préparation de l'environnement | `setup/Initialize-ManagedNode.ps1`, `setup/Initialize-AdminStation.ps1`, `scripts/Partie1-TestParc.ps1`, `scripts/Partie1-CommandeDistante.ps1` | `Disponibilite.csv` |
| 2 — Inventaire du parc | `scripts/Partie2-Inventaire.ps1` | `Inventory.csv` |
| 3 — Inventaire des correctifs | `scripts/Partie3-Correctifs.ps1`, `scripts/Rechercher-KB.ps1` | `PatchesInventory.csv`, `PatchesSummary.csv` |
| 4 — Contrôle de conformité | `scripts/Partie4-Conformite.ps1` | `ComplianceReport.csv` |
| 6 — Rapport de sécurité | `Invoke-PatchAudit.ps1` | `SecurityReport.csv/.html`, `Interventions.csv`, `ParcSummary.csv`, `PatchManager.log` |
| 7 — Notification | `Invoke-PatchAudit.ps1` (+ `config/PatchManager.config.psd1`) | `Notification.txt`, courriel / webhook |
| **Bonus** — Remédiation (« partie 5 ») | `scripts/Bonus-Remediation.ps1` | `Remediation.csv` |
| **Bonus** — Historique et tendance | `Invoke-PatchAudit.ps1` (automatique) | `History.csv`, `Evolution.csv`, section « Évolution » du HTML |
| 8 — Sécurisation | `scripts/Partie8-AuditRemoting.ps1`, `jea/`, `setup/Protect-PMData.ps1`, `setup/Save-PMSecret.ps1`, `setup/Enable-PSAuditLogging.ps1`, `scripts/Verifier-Integrite.ps1` | `RemotingSecurityAudit.csv/.html`, `SHA256SUMS.txt` |

Les réponses aux questions de l'énoncé, l'architecture, les choix techniques et les tests sont
détaillés dans le **[rapport](docs/RAPPORT.md)**.

## Arborescence

```
Invoke-PatchAudit.ps1            Point d'entrée : chaîne complète (parties 1 à 7)
computers.txt                    Inventaire du parc (NOM;IP)
required-patches.txt             Politique : correctifs obligatoires (KB;Description;Cible)
config/PatchManager.config.psd1  Configuration (aucun secret)
src/PatchManager/                Module PowerShell
  Shared/Get-PatchAuditData.ps1    Collecteur exécuté sur chaque poste (lecture seule)
  Public/                          Inventaire, conformité, rapport, notification, audit
  Private/                         Fonctions internes (réseau, CSV, HTML)
scripts/                         Scripts de démonstration, un par partie de l'énoncé
setup/                           Préparation des postes et sécurisation
jea/                             Point de terminaison Just Enough Administration "PatchAudit"
tests/                           Tests Pester (50 tests, exécutables sans laboratoire)
examples/                        Exemples de rapports générés (données fictives)
docs/                            Guide d'installation détaillé, rapport et captures du laboratoire
.github/workflows/ci.yml         Intégration continue sur Windows (tests + audit réel WinRM/JEA)
```

## Points forts

- **Robuste** : un poste éteint, un WinRM fermé, un accès refusé ou une commande distante en échec
  n'interrompent jamais l'audit ; l'erreur est enregistrée dans l'inventaire et le journal.
- **Rapide et extensible** : test TCP du port WinRM avec délai court avant toute connexion, puis
  collecte **en parallèle** sur toutes les sessions (`Invoke-Command -Session … -ThrottleLimit`).
- **Fiable** : correctifs issus de `Get-HotFix` **et** de l'historique de l'agent Windows Update
  (désinstallations prises en compte) ; politique ciblable par version de Windows.
- **Sécurisé** : pare-feu WinRM restreint au poste d'administration, compte d'audit **non
  administrateur** via **JEA** (testé en CI), secrets chiffrés DPAPI, ACL sur les rapports, journal en
  ajout seul, empreintes SHA-256, rapports protégés contre l'injection HTML et CSV.
- **Bonus** : remédiation automatique des postes non conformes (tâche SYSTEM temporaire, confirmation,
  `-WhatIf`) et suivi de la conformité dans le temps (régressions, graphique d'évolution).
- **Testé** : 50 tests Pester et analyse PSScriptAnalyzer ; en CI sur Windows, un audit réel via
  WinRM et via JEA, et la remédiation, sous Windows PowerShell 5.1 et PowerShell 7.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

## Prérequis

- Windows 10/11 (ou Windows Server) avec Windows PowerShell 5.1 (inclus) ou PowerShell 7 ;
- postes du parc sur le même réseau que le poste d'administration, WinRM activé ;
- droits administrateur pour la préparation (`setup/`) et pour la collecte avec le point de
  terminaison standard (aucun droit administrateur avec le point de terminaison JEA).

---
Projet réalisé par **Pratheep Parthepan et Antoine Poirier** — module *Sécurité des systèmes d'exploitation*.
