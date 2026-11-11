# Fonctions communes aux tests : fabrication de faux résultats de collecte.

# Fabrique un faux résultat de collecte (poste accessible ou non) pour les tests
function New-FakeHostResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fabrique des objets de test en mémoire')]
    param(
        [string] $Name = 'PC01',
        [string] $IPAddress = '192.168.10.11',
        [string[]] $HotFix = @(),
        [object[]] $History = @(),
        [switch] $Inaccessible,
        [string] $Caption = 'Microsoft Windows 11 Professionnel',
        [string] $Build = '26100',
        [string] $WUStatus = 'Running',
        [string] $WUStartType = 'Manual',
        [bool] $RebootPending = $false,
        [double] $FreeGB = 80,
        [string] $Detail = 'Hôte injoignable'
    )
    $errors = New-Object System.Collections.Generic.List[string]
    if ($Inaccessible) {
        $errors.Add($Detail)
        return [pscustomobject]@{
            Name = $Name; IPAddress = $IPAddress; Target = $IPAddress; IsLocal = $false; Ping = $false
            Accessible = $false; Status = 'Inaccessible'; Detail = $Detail
            System = $null; HotFixes = @(); UpdateHistory = @(); Errors = $errors; CheckedAt = (Get-Date)
        }
    }
    $i = 0
    $hf = foreach ($kb in $HotFix) {
        $i++
        [pscustomobject]@{
            RecordType = 'HotFix'; HotFixID = $kb; Description = 'Security Update'
            InstalledOn = (Get-Date '2026-09-01').AddDays($i); InstalledBy = 'NT AUTHORITY\SYSTEM'
        }
    }
    [pscustomobject]@{
        Name = $Name; IPAddress = $IPAddress; Target = $IPAddress; IsLocal = $false; Ping = $true
        Accessible = $true; Status = 'Accessible'; Detail = 'OK'
        System = [pscustomobject]@{
            RecordType = 'System'; ComputerName = $Name; Domain = 'WORKGROUP'; Manufacturer = 'innotek GmbH'
            Model = 'VirtualBox'; BiosVersion = 'VirtualBox'; BiosManufacturer = 'innotek GmbH'; SerialNumber = '0'
            OSCaption = $Caption; OSVersion = "10.0.$Build"; OSBuild = $Build; OSDisplayVersion = '24H2'; OSUBR = 4652
            OSArchitecture = '64 bits'; LastBootUpTime = (Get-Date).AddDays(-2); TotalMemoryGB = 4
            SystemDrive = 'C:'; SystemDriveSizeGB = 100; SystemDriveFreeGB = $FreeGB
            WUServiceStatus = $WUStatus; WUServiceStartType = $WUStartType; RebootPending = $RebootPending
            HotFixCount = @($hf).Count; CollectedAt = (Get-Date); PSVersion = '5.1'; Errors = ''
        }
        HotFixes = @($hf); UpdateHistory = @($History); Errors = $errors; CheckedAt = (Get-Date)
    }
}

# Fabrique une fausse entrée d'historique Windows Update
function New-FakeHistory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Fabrique des objets de test en mémoire')]
    param([string] $KB, [datetime] $Date, [int] $Operation = 1, [int] $ResultCode = 2)
    [pscustomobject]@{ RecordType = 'UpdateHistory'; KB = $KB; Title = "Update ($KB)"; Date = $Date; Operation = $Operation; ResultCode = $ResultCode }
}
