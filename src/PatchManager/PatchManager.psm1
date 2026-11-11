# Module PatchManager - solution simplifiée de Patch Management Windows en PowerShell
# Compatible Windows PowerShell 5.1 et PowerShell 7.

# Racine du projet (deux niveaux au-dessus du dossier du module : src\PatchManager)
$script:PMProjectRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$script:PMConfig = $null

foreach ($folder in 'Shared', 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in (Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name)) {
        . $file.FullName
    }
}
