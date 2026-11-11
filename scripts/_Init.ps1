# Initialisation commune aux scripts de démonstration (dot-sourcé par chaque script).
# Charge le module PatchManager et la configuration, avec les éventuelles surcharges.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variable utilisée par les scripts qui dot-sourcent ce fichier')]
param(
    [string] $ConfigPath,
    [hashtable] $Override = @{}
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
# Le module contient toute la logique ; les scripts de démonstration ne font qu'appeler ses fonctions
Import-Module -Name (Join-Path -Path $projectRoot -ChildPath 'src\PatchManager\PatchManager.psd1') -Force
$cfgParams = @{ Override = $Override }
if ($ConfigPath) { $cfgParams.Path = $ConfigPath }
$PMConfig = Import-PMConfiguration @cfgParams
