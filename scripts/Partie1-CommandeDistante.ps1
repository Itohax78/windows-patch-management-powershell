<#
.SYNOPSIS
    Partie 1 (questions 5-6) - Exécution distante NON interactive avec Invoke-Command sur
    tous les postes accessibles : nom, utilisateur distant, version de PowerShell, état
    des services WinRM et Windows Update.
.DESCRIPTION
    La session interactive (Enter-PSSession) se teste à la main :
        Enter-PSSession -ComputerName 192.168.10.12 -Credential (Get-Credential)
        hostname ; whoami ; Get-Service WinRM ; exit
.EXAMPLE
    .\scripts\Partie1-CommandeDistante.ps1 -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [System.Management.Automation.PSCredential] [System.Management.Automation.Credential()] $Credential = [System.Management.Automation.PSCredential]::Empty
)
. (Join-Path $PSScriptRoot '_Init.ps1') -ConfigPath $ConfigPath

# On ne vise que les postes distants dont WinRM répond (évite les longs délais d'attente)
$targets = @(Test-PMComputer -Computer @(Read-PMComputerList) | Where-Object { $_.Accessible -and -not $_.IsLocal })
if (-not $targets) { Write-Warning 'Aucun poste distant accessible via WinRM.'; return }

# Exécution NON interactive : le même bloc de code est lancé en parallèle sur tous les postes
$params = @{
    ComputerName = $targets.Target
    ErrorAction  = 'SilentlyContinue'
    ErrorVariable = 'errs'
    ScriptBlock  = {
        [pscustomobject]@{
            NomDistant    = $env:COMPUTERNAME
            Utilisateur   = whoami.exe
            PowerShell    = $PSVersionTable.PSVersion.ToString()
            ServiceWinRM  = (Get-Service WinRM).Status.ToString()
            WindowsUpdate = (Get-Service wuauserv).Status.ToString()
        }
    }
}
if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $params.Credential = $Credential }
if ($PMConfig.UseSSL) { $params.UseSSL = $true }

Write-Host "`n=== Invoke-Command sur $($targets.Count) poste(s) ===`n" -ForegroundColor Cyan
Invoke-Command @params | Select-Object PSComputerName, NomDistant, Utilisateur, PowerShell, ServiceWinRM, WindowsUpdate | Format-Table -AutoSize | Out-Host
# Les erreurs d'un poste n'arrêtent pas les autres : on les affiche à la fin
foreach ($e in $errs) { Write-Warning "$($e.OriginInfo.PSComputerName) : $($e.Exception.Message)" }
