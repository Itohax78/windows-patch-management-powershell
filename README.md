# Patch Management — Audit de conformité d'un parc Windows (PowerShell)

Module PowerShell d'audit centralisé des correctifs de sécurité d'un parc
Windows, réalisé dans le cadre du module Sécurité des systèmes d'exploitation
à l'EFREI Paris. Projet en binôme.

## Objectif
Garantir de façon vérifiable que chaque poste d'un parc dispose des correctifs
exigés par la politique de sécurité — la faille qu'a exploitée WannaCry en 2017
(MS17-010 publié deux mois plus tôt).

## Chaîne de traitement
Inventaire des postes → connexion distante (WinRM) → collecte des correctifs →
contrôle de conformité → détection des anomalies → rapport (CSV / HTML) →
notification.

## Points forts
- **Module PowerShell structuré** (fonctions publiques/privées, orchestration)
- **Moindre privilège** : collecte via un point de terminaison JEA avec un
  compte non administrateur (svc-patchaudit)
- **Durcissement WinRM** : chiffrement, TrustedHosts restreint, pare-feu limité
  au seul poste d'administration
- **Traçabilité** : journal horodaté et empreintes SHA-256 des rapports
- **Secrets chiffrés** via DPAPI
- **Bonus** : remédiation automatique (installation des KB manquantes) et suivi
  de la conformité dans le temps
- **Qualité** : 50 tests Pester et intégration continue GitHub Actions (Windows)

## Stack
PowerShell 5.1 · WinRM / PowerShell Remoting · JEA · Pester · GitHub Actions · DPAPI

## Démo
Vidéo de démonstration : 
