@{
    RootModule        = 'PatchAuditJEA.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3c8e5d2-4f1a-4c7e-9a62-7d0e1f3b8a55'
    Author            = 'Pratheep Parthepan, Antoine Poirier'
    Description       = 'Module JEA : expose uniquement la fonction de collecte en lecture seule Get-PatchAuditData.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-PatchAuditData')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
