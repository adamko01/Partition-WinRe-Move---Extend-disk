#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Interactive GUI v2.2: extend C: and recreate a standard WinRE partition online.
.DESCRIPTION
Run in elevated 64-bit Windows PowerShell 5.1 on Windows Server Desktop Experience:
  powershell.exe -NoProfile -STA -File .\Extend-C-GUI.ps1
Guided mode separates inspection, WinRE matching, BitLocker, disable/preserve,
extend/rebuild, and enable/validate. Quick mode uses the same steps.
Analyze is read-only apart from local logs. Extend requires a backup acknowledgement
and confirmation. No reboot or service stop is requested. No zero-downtime guarantee.
Scope: current OS on C:, healthy basic GPT disk, EFI + MSR + C: + one standard
WinRE partition, followed by newly added unallocated space. English REAgentC output
is required for fail-closed status parsing. Encrypted/clustered disks are rejected.
WinRE must initially be enabled; incomplete previous attempts require manual review.
Only Winre.wim is preserved; do not use on OEM/custom recovery partitions.
An already expanded disk with no usable tail space is rejected without changes.
Recovery defaults to 1024 MiB; refuses an image leaving less than 250 MiB free.
Logs and a SHA256-verified WIM copy are retained under ProgramData\Extend-C-GUI.
The WIM copy on C: is not a VM backup. No automatic partition rollback is attempted.
After a failure, read the log and inspect the disk before making further changes.
After success, verify application health. A WinRE boot test needs a maintenance window.

Validation: PowerShell parser plus 22 mocked gate/security cases passed.
Vendor command references reviewed; NOT execution-tested on Windows.
Validate on a disposable clone before production use. Do not run concurrent disk tools.
References:
https://learn.microsoft.com/en-us/windows-server/storage/disk-management/extend-a-basic-volume
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options
https://support.microsoft.com/en-us/topic/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update-400faa27-9343-461c-ada9-24c8229763bf
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Use 64-bit Windows PowerShell 5.1.'
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:RecoveryType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$script:BasicType = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
$script:Reserve = [uint64]1GB
$script:Busy = $false
$script:Phase = 'Start'
$script:NewRecovery = $null
$script:ImageHash = $null
$script:DestructiveStarted = $false
$script:Plan = $null
$script:RunDir = Join-Path $env:ProgramData ('Extend-C-GUI\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
$script:Log = Join-Path $script:RunDir 'activity.log'
function Write-Log {
    param([Parameter(ValueFromPipeline=$true)][string]$Message)
    process {
    $line = '{0}  {1}' -f (Get-Date -Format 's'), $Message
    Add-Content -LiteralPath $script:Log -Value $line -Encoding UTF8
    $outputBox.AppendText($line + "`r`n")
    $outputBox.Refresh()
    }
}
function Invoke-Native([string]$File, [string[]]$Arguments) {
    Write-Log ('> ' + [IO.Path]::GetFileName($File) + ' ' + ($Arguments -join ' '))
    $result = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    $value = ($result | Out-String).Trim()
    Write-Log $value
    if ($code -ne 0) { throw "$File failed (exit $code)." }
    return $value
}
function Set-Summary([string]$Name, [string]$Text, [string]$Tone = 'Gray') {
    if (-not (Get-Variable Summary -Scope Script -ErrorAction SilentlyContinue)) { $script:Summary = @{} }
    $script:Summary[$Name] = [pscustomobject]@{Text=$Text; Tone=$Tone}
    if (Get-Variable SummaryLabels -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:SummaryLabels.ContainsKey($Name)) {
            $label = $script:SummaryLabels[$Name]
            $label.Text = $Text
            $label.ForeColor = [Drawing.Color]::FromName($Tone)
            $label.Refresh()
        }
    }
}
function Get-ReInfo {
    Set-Summary 'WinRE' 'WinRE: Unknown / checking - see log if this check fails.' 'DarkOrange'
    $raw = Invoke-Native "$env:windir\System32\reagentc.exe" @('/info')
    if ($raw -notmatch 'Windows RE status:\s*(Enabled|Disabled)') {
        throw 'Cannot reliably parse WinRE status. This version requires English REAgentC output.'
    }
    $enabled = $Matches[1] -eq 'Enabled'
    $diskNumber = -1; $partitionNumber = -1
    if ($enabled) {
        if ($raw -notmatch 'Windows RE location:\s*.*?harddisk(\d+)\\partition(\d+)\\Recovery\\WindowsRE') {
            throw 'Cannot identify the active standard WinRE location.'
        }
        $diskNumber = [int]$Matches[1]; $partitionNumber = [int]$Matches[2]
    }
    if ($enabled) {
        Set-Summary 'WinRE' "WinRE: Enabled | Disk $diskNumber, partition $partitionNumber | Match not yet checked | Checked $(Get-Date -Format HH:mm:ss)" 'DarkSlateBlue'
    } else {
        Set-Summary 'WinRE' "WinRE: Disabled | Recovery environment unavailable until re-enabled | Checked $(Get-Date -Format HH:mm:ss)" 'DarkOrange'
    }
    [pscustomobject]@{ Enabled=$enabled; Disk=$diskNumber; Partition=$partitionNumber }
}
function Get-Layout {
    if ($env:SystemDrive -ne 'C:') { throw 'The running Windows installation must be on C:.' }
    $c = Get-Partition -DriveLetter C
    $d = Get-Disk -Number $c.DiskNumber
    $v = Get-Volume -DriveLetter C
    if ($d.PartitionStyle -ne 'GPT' -or $d.IsOffline -or $d.IsReadOnly -or $d.IsClustered -or
        $d.HealthStatus -ne 'Healthy' -or $v.HealthStatus -ne 'Healthy' -or $v.FileSystem -ne 'NTFS') {
        throw 'Requires a healthy, online, writable, non-clustered GPT disk and healthy NTFS C:.'
    }
    $parts = @(Get-Partition -DiskNumber $d.Number | Sort-Object Offset)
    if ($parts.Count -ne 4 -or
        ([string]$parts[0].GptType).Trim('{}') -ne 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' -or
        ([string]$parts[1].GptType).Trim('{}') -ne 'e3c9e316-0b5c-4db8-817d-f92df00215ae' -or
        $parts[2].PartitionNumber -ne $c.PartitionNumber -or
        ([string]$c.GptType).Trim('{}') -ne $script:BasicType -or
        ([string]$parts[3].GptType).Trim('{}') -ne $script:RecoveryType) {
        throw 'Supported layout: EFI | MSR | C: | one Recovery partition | unallocated space.'
    }
    $r = $parts[3]
    if ($r.IsBoot -or $r.IsSystem -or $r.DriveLetter -or $r.Size -gt 2GB -or $r.Size -lt 300MB) {
        throw 'Recovery partition does not match a standard, unmounted WinRE partition.'
    }
    if ([math]::Abs([double]$r.Offset - ($c.Offset + $c.Size)) -gt 1MB) {
        throw 'Unexpected gap between C: and Recovery.'
    }
    $tail = [double]$d.Size - ($r.Offset + $r.Size)
    $gain = [math]::Floor(($tail + $r.Size - $script:Reserve - 2MB) / 1MB) * 1MB
    if ($tail -lt 16MB -or $gain -lt 16MB) { throw 'No sufficient new trailing space. No resize is needed or possible.' }
    $fingerprint = "$($d.UniqueId)|$($d.Size)|" + (($parts | ForEach-Object {
        "$($_.Guid):$($_.PartitionNumber):$($_.Offset):$($_.Size)"
    }) -join '|')
    [pscustomobject]@{ Disk=$d; C=$c; Recovery=$r; Parts=$parts; Gain=$gain; Fingerprint=$fingerprint }
}
function Invoke-DiskPart([int]$DiskNumber, [int]$PartitionNumber, [string]$Command) {
    $path = Join-Path $script:RunDir ('diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    Write-Log ("DiskPart commands:`r`nselect disk $DiskNumber`r`nselect partition $PartitionNumber`r`n$Command`r`nexit")
    @("select disk $DiskNumber", "select partition $PartitionNumber", $Command, 'exit') |
        Set-Content -LiteralPath $path -Encoding ASCII
    Invoke-Native "$env:windir\System32\diskpart.exe" @('/s', $path)
}

function Get-EncryptionState {
    Set-Summary 'BitLocker' 'BitLocker C: Unknown / checking - see log if this check fails.' 'DarkOrange'
    Write-Log '> Get-WindowsFeature BitLocker; Get-BitLockerVolume -MountPoint C:'
    $feature = Get-WindowsFeature -Name BitLocker
    if ($null -eq $feature) { throw 'BitLocker feature state is unknown; changes remain blocked.' }
    if (-not $feature.Installed) {
        Set-Summary 'BitLocker' "BitLocker: Feature not installed | Checked $(Get-Date -Format HH:mm:ss)" 'DarkGreen'
        Write-Log 'BitLocker feature is not installed. No BitLocker handling required for this supported server configuration.'
        return
    }
    # Do not print KeyProtector objects or recovery passwords into logs.
    $b = Get-BitLockerVolume -MountPoint 'C:'
    if ($null -eq $b) { throw 'Cannot read BitLocker state. Changes remain blocked.' }
    Set-Summary 'BitLocker' "BitLocker C: $($b.VolumeStatus) ($($b.EncryptionPercentage)%) | Protection: $($b.ProtectionStatus) | $($b.LockStatus) | Checked $(Get-Date -Format HH:mm:ss)" 'DarkOrange'
    $b | Select-Object MountPoint,VolumeStatus,ProtectionStatus,EncryptionPercentage,LockStatus | Format-List | Out-String | Write-Log
    if ([string]$b.VolumeStatus -ne 'FullyDecrypted' -or $b.EncryptionPercentage -ne 0 -or [string]$b.LockStatus -ne 'Unlocked') {
        Write-Log @'
BITLOCKER GUIDANCE
This tool only permits fully decrypted C:. That is a limitation of this tool,
not a general claim that Windows always requires decryption for extension.
ProtectionStatus Off can mean suspended protection; the data may still be encrypted.
1. Verify the recovery key is escrowed and retrievable through your approved process.
2. Choose an approved BitLocker-aware procedure, or obtain approval to decrypt C:.
3. ONLY if decryption is approved, run manually in elevated PowerShell:
   Disable-BitLocker -MountPoint 'C:'
4. Monitor without displaying keys:
   Get-BitLockerVolume -MountPoint 'C:' | Select MountPoint,VolumeStatus,ProtectionStatus,EncryptionPercentage
5. Wait for FullyDecrypted / 0%, then repeat the BitLocker check in this tool.
6. If decrypted, re-enable BitLocker afterward using your organization's policy and
   escrow process. This GUI neither decrypts nor re-encrypts the disk automatically.
Decryption can take time, increase disk I/O, and removes data-at-rest protection.
Reference: https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/operations-guide
'@
        throw 'BitLocker requires attention. See the guidance in the log; no partition changes were made by this check.'
    }
    Set-Summary 'BitLocker' "BitLocker C: Fully decrypted (0%) | Protection: $($b.ProtectionStatus) | Unlocked | Checked $(Get-Date -Format HH:mm:ss)" 'DarkGreen'
    Write-Log 'BitLocker check passed: fully decrypted, 0%, unlocked.'
}
function Assert-Phase([string[]]$Allowed) {
    if ($script:Phase -notin $Allowed) { throw "Action is not allowed in state $script:Phase." }
}
function Assert-OriginalLayout {
    if ($null -eq $script:Plan) { throw 'Inspect the partitions first.' }
    $current = Get-Layout
    if ($current.Fingerprint -ne $script:Plan.Fingerprint) {
        throw 'The disk layout changed. Do not continue from a stale plan; inspect the current layout.'
    }
    return $current
}
function Show-Partitions {
    $c = Get-Partition -DriveLetter C
    $rows = @(Get-Partition -DiskNumber $c.DiskNumber | Sort-Object Offset)
    $grid.Rows.Clear()
    foreach ($p in $rows) {
        [void]$grid.Rows.Add($c.DiskNumber,$p.PartitionNumber,[string]$p.DriveLetter,[string]$p.Type,
            ('{0:N3}' -f ($p.Size/1GB)),[string]$p.GptType)
    }
    $d = Get-Disk -Number $c.DiskNumber
    # Force the Double overload: an untyped 0 can select Int32 and overflow above 2 GiB.
    $tail = [math]::Max([double]0, ([double]$d.Size - [double]$rows[-1].Offset - [double]$rows[-1].Size - [double]1MB))
    [void]$grid.Rows.Add($d.Number,'-','','Trailing free (approx.)',('{0:N3}' -f ($tail/1GB)),'')
    $rows | Select-Object PartitionNumber,DriveLetter,Type,Size,Offset,GptType | Format-Table -AutoSize | Out-String | Write-Log
}
function Step-Inspect {
    Assert-Phase @('Start','Inspected','Matched','Ready')
    $script:Phase = 'Start'; $script:Plan = $null
    Set-Summary 'WinRE' 'WinRE: Not checked - run step 2 or Quick Analyze.'
    Set-Summary 'BitLocker' 'BitLocker: Not checked - run step 3 or Quick Analyze.'
    Write-Log '> Get-Partition -DriveLetter C; Get-Disk; Get-Partition; Get-Volume'
    Show-Partitions
    $script:Plan = Get-Layout
    $script:Phase = 'Inspected'
    Write-Log ('Layout accepted. Disk {0}, C: partition {1}, Recovery candidate {2}.' -f $script:Plan.Disk.Number,$script:Plan.C.PartitionNumber,$script:Plan.Recovery.PartitionNumber)
    Write-Log ('Proposed C: {0:N2} -> approximately {1:N2} GiB; Recovery: 1 GiB.' -f ($script:Plan.C.Size/1GB),(($script:Plan.C.Size+$script:Plan.Gain)/1GB))
    Write-Log 'Next: compare the candidate with the active WinRE location. A Recovery type alone is insufficient.'
}
function Step-Match {
    Assert-Phase @('Inspected','Matched','Ready')
    $script:Phase = 'Inspected'
    $fresh = Assert-OriginalLayout
    $re = Get-ReInfo
    if (-not $re.Enabled) { throw 'WinRE is already disabled. This session cannot prove its former location. Restore/verify WinRE manually before starting this workflow.' }
    if ($re.Disk -ne $fresh.Disk.Number -or $re.Partition -ne $fresh.Recovery.PartitionNumber) {
        Set-Summary 'WinRE' "WinRE: Enabled | Disk $($re.Disk), partition $($re.Partition) | MISMATCH - deletion blocked" 'DarkRed'
        throw 'MISMATCH: the partition blocking C: is not the active WinRE partition. Deletion is blocked.'
    }
    Set-Summary 'WinRE' "WinRE: Enabled | Disk $($re.Disk), partition $($re.Partition) | Recovery match verified | Checked $(Get-Date -Format HH:mm:ss)" 'DarkGreen'
    Write-Log "MATCH: active WinRE is disk $($re.Disk), partition $($re.Partition); GPT recovery type also matches."
    $script:Phase = 'Matched'
}
function Step-BitLocker {
    Assert-Phase @('Matched','Ready')
    $script:Phase = 'Matched'
    Assert-OriginalLayout | Out-Null
    Get-EncryptionState
    $script:Phase = 'Ready'
}
function Confirm-Change([string]$Message) {
    $text = "$Message`r`n`r`nHost: $env:COMPUTERNAME`r`nBy choosing Yes, you confirm a current recoverable VM backup and that this is standard WinRE without custom recovery data."
    return ([System.Windows.Forms.MessageBox]::Show($form,$text,'Confirm operation','YesNo','Warning','Button2') -eq 'Yes')
}
function Step-Disable {
    Assert-Phase @('Ready')
    # Recheck all prerequisites immediately before changing the system.
    Step-Match
    Step-BitLocker
    $fresh = Assert-OriginalLayout
    $fresh.Parts | Select-Object * | Export-Clixml (Join-Path $script:RunDir 'partitions-before.xml')
    if ((Get-Volume -DriveLetter C).SizeRemaining -lt 3GB) { throw 'At least 3 GiB free on C: is required before preserving the recovery image.' }
    $script:Phase = 'DisableUncertain'
    Invoke-Native "$env:windir\System32\reagentc.exe" @('/disable') | Out-Null
    if ((Get-ReInfo).Enabled) { throw 'WinRE is still enabled. No partition was deleted.' }
    $wim = Join-Path $env:windir 'System32\Recovery\Winre.wim'
    $item = Get-Item -LiteralPath $wim -Force
    if ($item.Length -lt 1MB -or $item.Length -gt ($script:Reserve - 300MB)) {
        throw 'Winre.wim is missing or too large for the reserved partition. Use Enable WinRE to undo the disable; no partition was deleted.'
    }
    $backup = Join-Path $script:RunDir 'Winre.wim'
    Write-Log " > Copy-Item: $wim -> $backup; compare both SHA256 hashes"
    Copy-Item -LiteralPath $wim -Destination $backup -Force
    $script:ImageHash = (Get-FileHash $wim -Algorithm SHA256).Hash
    if ($script:ImageHash -ne (Get-FileHash $backup -Algorithm SHA256).Hash) { throw 'WIM backup hash mismatch. No partition was deleted.' }
    Write-Log "WinRE disabled; SHA256-verified image copy: $backup"
    Write-Log 'Next: Extend C: + rebuild Recovery. Enable WinRE can instead cancel preparation and restore the original registration.'
    $script:Phase = 'Disabled'
}
function Step-Extend {
    Assert-Phase @('Disabled')
    $fresh = Assert-OriginalLayout
    Get-EncryptionState
    if ((Get-ReInfo).Enabled) { throw 'WinRE was re-enabled externally. Stop and review.' }
    $wim = Join-Path $env:windir 'System32\Recovery\Winre.wim'
    $backup = Join-Path $script:RunDir 'Winre.wim'
    if ($null -eq $script:ImageHash -or (Get-FileHash $wim -Algorithm SHA256).Hash -ne $script:ImageHash -or
        (Get-FileHash $backup -Algorithm SHA256).Hash -ne $script:ImageHash) {
        throw 'The preserved recovery image changed or is missing. Deletion is blocked.'
    }
    $stage = 'Recovery identity verification'
    try {
        $r = Get-Partition -DiskNumber $fresh.Disk.Number -PartitionNumber $fresh.Recovery.PartitionNumber
        if ($r.Guid -ne $fresh.Recovery.Guid -or $r.Offset -ne $fresh.Recovery.Offset -or $r.Size -ne $fresh.Recovery.Size) {
            throw 'Recovery partition changed before deletion.'
        }
        $stage = 'Delete original Recovery partition'
        $script:DestructiveStarted = $true
        $script:Phase = 'Blocked'
        Invoke-DiskPart $fresh.Disk.Number $r.PartitionNumber 'delete partition override' | Out-Null
        $remaining = @(Get-Partition -DiskNumber $fresh.Disk.Number)
        if ($remaining.Count -ne 3 -or @($remaining | Where-Object Guid -eq $r.Guid).Count -ne 0) {
            throw 'Recovery deletion was not verified; refusing to resize.'
        }
        $stage = 'Extend C:'
        $limit = Get-PartitionSupportedSize -DriveLetter C
        $target = [uint64]([math]::Floor(($limit.SizeMax - $script:Reserve) / 1MB) * 1MB)
        if ($target -le $fresh.C.Size) { throw 'No supported growth while reserving Recovery space.' }
        Write-Log " > Resize-Partition -DriveLetter C -Size $target"
        Resize-Partition -DriveLetter C -Size $target
        $cNow = Get-Partition -DriveLetter C
        if ($cNow.Size -ne $target -or $cNow.Guid -ne $fresh.C.Guid) { throw 'C: resize verification failed.' }
        $stage = 'Create and format new Recovery partition'
        Write-Log " > New-Partition -DiskNumber $($fresh.Disk.Number) -Offset $($cNow.Offset + $cNow.Size) -Size $script:Reserve -GptType {$script:RecoveryType}"
        $new = New-Partition -DiskNumber $fresh.Disk.Number -Offset ($cNow.Offset + $cNow.Size) -Size $script:Reserve -GptType "{$script:RecoveryType}"
        if ($null -eq $new -or $new.Size -ne $script:Reserve -or $new.Offset -ne ($cNow.Offset + $cNow.Size) -or
            $new.IsBoot -or $new.IsSystem -or ([string]$new.GptType).Trim('{}') -ne $script:RecoveryType) {
            throw 'New partition identity check failed; no format performed.'
        }
        Write-Log " > Format-Volume: ONLY newly created disk $($fresh.Disk.Number), partition $($new.PartitionNumber), GUID $($new.Guid); NTFS; Windows RE tools"
        Format-Volume -Partition $new -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Confirm:$false | Out-Null
        Invoke-DiskPart $fresh.Disk.Number $new.PartitionNumber 'gpt attributes=0x8000000000000001' | Out-Null
        $details = Invoke-DiskPart $fresh.Disk.Number $new.PartitionNumber 'detail partition'
        if ($details -notmatch '8000000000000001') { throw 'Required Recovery attributes were not verified.' }
        $script:NewRecovery = $new
        $script:Phase = 'Rebuilt'
        Show-Partitions
        Write-Log 'C: extended and Recovery recreated. WinRE is still DISABLED. Next: Enable WinRE + validate.'
    } catch {
        Write-Log "Stopped during: $stage"
        if ($script:DestructiveStarted) {
            $script:Phase = 'Blocked'
            Write-Log 'Partial partition changes may exist. Preserve the log/WIM copy. Inspect Disk Management and reagentc /info before recovery. Automatic rerun and rollback are blocked.'
        }
        throw
    }
}
function Step-Enable {
    Assert-Phase @('Disabled','DisableUncertain','Rebuilt','Done')
    if ($script:Phase -eq 'Done') { Test-Final; return }
    $rebuilt = $script:Phase -eq 'Rebuilt'
    if ($rebuilt) {
        $new = Get-Partition -DiskNumber $script:Plan.Disk.Number -PartitionNumber $script:NewRecovery.PartitionNumber
        if ($new.Guid -ne $script:NewRecovery.Guid -or $new.Offset -ne $script:NewRecovery.Offset -or $new.Size -ne $script:Reserve) {
            throw 'New Recovery identity changed. Enable is blocked pending manual review.'
        }
        $expectedNumber = $new.PartitionNumber
    } else {
        Assert-OriginalLayout | Out-Null
        $expectedNumber = $script:Plan.Recovery.PartitionNumber
    }
    Invoke-Native "$env:windir\System32\reagentc.exe" @('/enable') | Out-Null
    $re = Get-ReInfo
    if (-not $re.Enabled -or $re.Disk -ne $script:Plan.Disk.Number -or $re.Partition -ne $expectedNumber) {
        throw 'WinRE is not enabled on the expected partition. Review the log and registration.'
    }
    Set-Summary 'WinRE' "WinRE: Enabled | Disk $($re.Disk), partition $($re.Partition) | Expected location verified | Checked $(Get-Date -Format HH:mm:ss)" 'DarkGreen'
    if ($rebuilt) {
        Test-Final
        $script:Phase = 'Done'
    } else {
        $script:Phase = 'Matched'; $script:ImageHash = $null
        Write-Log 'Original WinRE restored. No partition changes were made. Repeat BitLocker check before preparing again.'
    }
}
function Test-Final {
    $fresh = $script:Plan
    $new = $script:NewRecovery
    $re = Get-ReInfo
    if (-not $re.Enabled -or $re.Disk -ne $fresh.Disk.Number -or $re.Partition -ne $new.PartitionNumber) {
        throw 'WinRE registration validation failed.'
    }
    Set-Summary 'WinRE' "WinRE: Enabled | Disk $($re.Disk), partition $($re.Partition) | Expected location verified | Checked $(Get-Date -Format HH:mm:ss)" 'DarkGreen'
        $rv = Get-Partition -DiskNumber $fresh.Disk.Number -PartitionNumber $new.PartitionNumber | Get-Volume
        if ($rv.FileSystem -ne 'NTFS' -or $rv.HealthStatus -ne 'Healthy' -or $rv.SizeRemaining -lt 250MB) {
            throw 'Recovery volume health/free-space validation failed.'
        }
        $after = @(Get-Partition -DiskNumber $fresh.Disk.Number | Sort-Object Offset)
        if ($after.Count -ne 4) { throw 'Unexpected final partition count.' }
        foreach ($original in $fresh.Parts[0..1]) {
            $same = @($after | Where-Object Guid -eq $original.Guid)
            if ($same.Count -ne 1 -or $same[0].Offset -ne $original.Offset -or $same[0].Size -ne $original.Size) {
                throw 'EFI/MSR identity validation failed.'
            }
        }
        $cv = Get-Volume -DriveLetter C
        if ($cv.HealthStatus -ne 'Healthy') { throw 'C: health validation failed.' }
        $after | Select-Object PartitionNumber,DriveLetter,Type,Size | Out-String | Write-Log
        Write-Log ('SUCCESS: C: {0:N2} GiB; free {1:N2} GiB. WinRE enabled. No reboot requested.' -f ($cv.Size/1GB), ($cv.SizeRemaining/1GB))
    Show-Partitions
}
function Step-Analyze {
    Step-Inspect
    Step-Match
    Step-BitLocker
    Write-Log 'Quick analysis passed. Extend C: performs disable, preserve, extend, rebuild, enable and validation.'
}
function Get-ActionAvailability([string]$Phase, [bool]$Busy) {
    $idle = -not $Busy
    return @{
        Inspect = $idle -and $Phase -in @('Start','Inspected','Matched','Ready')
        Match = $idle -and $Phase -in @('Inspected','Matched','Ready')
        BitLocker = $idle -and $Phase -in @('Matched','Ready')
        Disable = $idle -and $Phase -eq 'Ready'
        Extend = $idle -and $Phase -eq 'Disabled'
        Enable = $idle -and $Phase -in @('Disabled','DisableUncertain','Rebuilt','Done')
        Analyze = $idle -and $Phase -in @('Start','Inspected','Matched','Ready')
        QuickExtend = $idle -and $Phase -eq 'Ready'
    }
}
function Update-Controls {
    $allowed = Get-ActionAvailability $script:Phase $script:Busy
    foreach ($key in $script:Buttons.Keys) { $script:Buttons[$key].Enabled = $allowed[$key] }
    $status.Text = 'State: ' + $script:Phase + '  |  ' + $script:StateHelp[$script:Phase]
    $status.ForeColor = if ($script:Phase -eq 'Done') { [Drawing.Color]::DarkGreen } elseif ($script:Phase -in @('Disabled','DisableUncertain','Rebuilt','Blocked')) { [Drawing.Color]::DarkRed } else { [Drawing.Color]::DarkSlateBlue }
    $status.Refresh()
}
function Run-Action([scriptblock]$Action) {
    if ($script:Busy) { return }
    $script:Busy = $true
    $form.UseWaitCursor = $true
    Update-Controls
    try { & $Action }
    catch {
        Write-Log ('ERROR: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($form,$_.Exception.Message + "`r`n`r`nRead the activity log below.",'Action stopped','OK','Error') | Out-Null
    } finally {
        $script:Busy = $false
        $form.UseWaitCursor = $false
        Update-Controls
    }
}
$script:StateHelp = @{
    Start='Inspect partitions to begin.'
    Inspected='Compare the Recovery candidate with the active WinRE location.'
    Matched='WinRE matches. Check BitLocker next.'
    Ready='Checks passed. Ready to disable WinRE or run Quick Extend.'
    DisableUncertain='Preparation incomplete. Original layout retained; use Enable WinRE or inspect the error.'
    Disabled='Image preserved. Extend C:, or enable WinRE to cancel preparation.'
    Rebuilt='C: extended. Enable WinRE and validate to finish.'
    Done='Completed. WinRE enabled and final checks passed.'
    Blocked='Partial changes possible. Manual recovery review required; automatic changes blocked.'
}
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Extend C: - guided and quick workflows'
$form.Size = New-Object System.Drawing.Size(1080,900)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)
$intro = New-Object System.Windows.Forms.Label
$intro.SetBounds(18,12,1020,45)
$intro.Text = "Extend C: while keeping a 1 GiB Windows Recovery partition. No reboot is requested.`r`nUse a recoverable VM backup. Standard GPT / NTFS / WinRE only. Test on a clone before production."
$grid = New-Object System.Windows.Forms.DataGridView
$grid.SetBounds(18,62,1020,162)
$grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'; $grid.BackgroundColor=[Drawing.Color]::White
$grid.Anchor='Top,Left,Right'
foreach ($name in @('Disk','Partition','Letter','Type','GiB','GPT type GUID')) { [void]$grid.Columns.Add($name,$name) }
$grid.Columns[5].FillWeight=280
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.SetBounds(18,233,1020,312); $tabs.Anchor='Top,Left,Right'
$guided = New-Object System.Windows.Forms.TabPage
$guided.Text='Guided - step by step'
$quick = New-Object System.Windows.Forms.TabPage
$quick.Text='Quick - analyze and extend'
$tabs.TabPages.AddRange(@($guided,$quick))
$script:Buttons=@{}
$steps=@(
    @('Inspect','1. Inspect partitions','Get-Partition / Get-Disk - identify C:, Recovery candidate and trailing free space.'),
    @('Match','2. Verify WinRE match','reagentc /info - compare the active disk and partition with the candidate.'),
    @('BitLocker','3. Check BitLocker','Show protection, encryption and lock status; display guidance if blocked.'),
    @('Disable','4. Disable + preserve WinRE','reagentc /disable - verify Winre.wim and save a SHA256-checked copy.'),
    @('Extend','5. Extend C: + rebuild Recovery','Delete verified Recovery, resize C:, create/format a 1 GiB Recovery partition.'),
    @('Enable','6. Enable WinRE + validate','reagentc /enable - finish after extension, or undo preparation before extension.')
)
$y=12
foreach ($step in $steps) {
    $button=New-Object System.Windows.Forms.Button
    $button.Text=$step[1]; $button.SetBounds(12,$y,260,36)
    $label=New-Object System.Windows.Forms.Label
    $label.Text=$step[2]; $label.SetBounds(284,($y+6),710,32)
    $guided.Controls.AddRange(@($button,$label))
    $script:Buttons[$step[0]]=$button
    $y+=43
}
$quickText=New-Object System.Windows.Forms.Label
$quickText.SetBounds(18,18,950,90)
$quickText.Text="Analyze runs all read-only checks and previews the result.`r`nExtend C: runs the complete workflow after confirmation, including re-enabling WinRE.`r`nBoth modes share the same checks and current state. If you already disabled WinRE in Guided mode, finish there."
$qa=New-Object System.Windows.Forms.Button
$qa.Text='Analyze'; $qa.SetBounds(18,126,200,48)
$qe=New-Object System.Windows.Forms.Button
$qe.Text='Extend C:'; $qe.SetBounds(236,126,200,48)
$quick.Controls.AddRange(@($quickText,$qa,$qe))
$script:Buttons['Analyze']=$qa; $script:Buttons['QuickExtend']=$qe
$status=New-Object System.Windows.Forms.Label
$status.SetBounds(18,553,1020,26); $status.Anchor='Top,Left,Right'
$winreSummary=New-Object System.Windows.Forms.Label
$winreSummary.SetBounds(18,580,1020,24); $winreSummary.Anchor='Top,Left,Right'
$bitlockerSummary=New-Object System.Windows.Forms.Label
$bitlockerSummary.SetBounds(18,606,1020,24); $bitlockerSummary.Anchor='Top,Left,Right'
$script:SummaryLabels=@{ WinRE=$winreSummary; BitLocker=$bitlockerSummary }
Set-Summary 'WinRE' 'WinRE: Not checked - run step 2 or Quick Analyze.'
Set-Summary 'BitLocker' 'BitLocker: Not checked - run step 3 or Quick Analyze.'
$outputBox=New-Object System.Windows.Forms.TextBox
$outputBox.SetBounds(18,638,1020,172); $outputBox.Anchor='Top,Bottom,Left,Right'
$outputBox.Multiline=$true; $outputBox.ReadOnly=$true; $outputBox.ScrollBars='Both'; $outputBox.WordWrap=$false
$outputBox.Font=New-Object System.Drawing.Font('Consolas',9)
$footer=New-Object System.Windows.Forms.Label
$footer.SetBounds(18,819,1020,35); $footer.Anchor='Bottom,Left,Right'
$footer.Text='Log / WIM backup: '+$script:RunDir
$form.Controls.AddRange(@($intro,$grid,$tabs,$status,$winreSummary,$bitlockerSummary,$outputBox,$footer))
$script:Buttons['Inspect'].Add_Click({ Run-Action { Step-Inspect } })
$script:Buttons['Match'].Add_Click({ Run-Action { Step-Match } })
$script:Buttons['BitLocker'].Add_Click({ Run-Action { Step-BitLocker } })
$script:Buttons['Disable'].Add_Click({
    if (Confirm-Change 'Disable WinRE and preserve its image? Partitions are not changed in this step.') {
        Run-Action { Step-Disable }
    }
})
$script:Buttons['Extend'].Add_Click({
    if (Confirm-Change "DELETE Recovery partition $($script:Plan.Recovery.PartitionNumber) on disk $($script:Plan.Disk.Number), extend C:, and recreate Recovery? WinRE must then be enabled with step 6.") {
        Run-Action { Step-Extend }
    }
})
$script:Buttons['Enable'].Add_Click({ Run-Action { Step-Enable } })
$qa.Add_Click({ Run-Action { Step-Analyze } })
$qe.Add_Click({
    if (Confirm-Change 'Run the COMPLETE workflow: disable WinRE, preserve image, DELETE its partition, extend C:, recreate Recovery, enable WinRE, and validate?') {
        Run-Action {
            Step-Analyze
            Step-Disable
            Step-Extend
            Step-Enable
        }
    }
})
$form.Add_FormClosing({
    if ($script:Busy) { $_.Cancel=$true; return }
    if ($script:Phase -in @('Disabled','DisableUncertain','Rebuilt','Blocked')) {
        if ([System.Windows.Forms.MessageBox]::Show($form,"WinRE preparation or partition changes are incomplete. State: $script:Phase.`r`nClosing loses the guided session; logs and the image copy remain on disk.`r`nClose anyway?",'Incomplete workflow','YesNo','Warning','Button2') -ne 'Yes') { $_.Cancel=$true }
    }
})
Write-Log 'Ready. Choose Guided or Quick mode. No partition changes occur during Analyze.'
Update-Controls
[void]$form.ShowDialog()
$form.Dispose()
