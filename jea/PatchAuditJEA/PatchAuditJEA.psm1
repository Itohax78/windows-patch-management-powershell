# Module chargé dans le point de terminaison JEA "PatchAudit".
# Get-PatchAuditData.ps1 est copié ici par Install-PatchAuditJEA.ps1 depuis
# src\PatchManager\Shared\ : le collecteur a donc une source unique.

# Dans une session JEA, le chargement automatique des modules est restreint : CimCmdlets
# (Get-CimInstance) doit être importé explicitement. Il est importé dans la portée de ce
# module uniquement : ses cmdlets ne deviennent PAS visibles pour le compte connecté.
Import-Module -Name CimCmdlets -ErrorAction Stop

. (Join-Path -Path $PSScriptRoot -ChildPath 'Get-PatchAuditData.ps1')
Export-ModuleMember -Function 'Get-PatchAuditData'
