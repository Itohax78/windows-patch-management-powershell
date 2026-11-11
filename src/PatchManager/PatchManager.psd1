@{
    RootModule        = 'PatchManager.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5d2f7c41-8a3e-4b6f-9c1d-2e7a9b0f4c63'
    Author            = 'Pratheep Parthepan, Antoine Poirier'
    Description       = 'Solution simplifiée de Patch Management Windows : inventaire, collecte des correctifs via PowerShell Remoting, contrôle de conformité, rapport et notification.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Import-PMConfiguration', 'Get-PMConfiguration', 'Write-PMLog', 'New-PMRunFolder', 'Remove-PMExpiredRun',
        'Write-PMIntegrityManifest', 'Test-PMIntegrity',
        'Read-PMComputerList', 'Test-PMComputer', 'Invoke-PMCollection', 'Get-PMInstalledPatch',
        'ConvertTo-PMInventory', 'ConvertTo-PMPatchInventory', 'Get-PMPatchSummary', 'Find-PMPatch',
        'Read-PMRequiredPatch', 'Test-PMCompliance', 'Get-PMComplianceRate',
        'New-PMSecurityReport', 'Get-PMParcSummary', 'Get-PMInterventionList', 'Get-PMAttentionPoint', 'Export-PMHtmlReport',
        'Get-PMAnomaly', 'New-PMNotificationMessage', 'Send-PMNotification',
        'Invoke-PMAudit', 'Get-PatchAuditData', 'Export-PMCsv',
        'Add-PMHistory', 'Get-PMHistory', 'Get-PMTrend', 'ConvertTo-PMTrendSvg',
        'Invoke-PMRemediation'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('PatchManagement', 'Security', 'WinRM', 'Windows') } }
}
