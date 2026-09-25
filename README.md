# Extend C: GUI

A PowerShell GUI for extending the Windows system partition when a Windows Recovery Environment (WinRE) partition sits between C: and newly added unallocated space.

Choose a guided workflow with individual checks and actions, or a quick workflow that runs the complete sequence after confirmation. Both modes use the same validation and partition operations.

> **Partition changes are destructive.** The tool deletes and recreates the verified WinRE partition. Use a current, recoverable VM backup and validate the workflow on a disposable clone before production use. The preserved recovery image is not a system backup.

## What it does

The tool identifies the disk containing the running Windows installation on C:, verifies the active WinRE location, checks BitLocker, and then:

1. Disables WinRE.
2. Copies `Winre.wim` and verifies the copy using SHA-256.
3. Deletes the verified Recovery partition.
4. Extends C:, reserving 1 GiB for Recovery.
5. Creates and formats a new Recovery partition with the required GPT type and attributes.
6. Enables WinRE and validates its location, partition layout, and volume health.

It operates inside running Windows and does not request a reboot or stop application services. This is **not a guarantee of zero downtime** or uninterrupted application performance.

## Features

- Guided and quick modes in separate tabs.
- Partition table showing disk numbers, partition numbers, sizes, and GPT types.
- Comparison of the Recovery candidate with the active WinRE disk and partition.
- BitLocker status checks and instructions when encryption blocks the workflow.
- WinRE and BitLocker summaries with status colors and last-check times.
- Buttons enabled according to the current workflow state.
- Confirmation before destructive changes.
- SHA-256 verification of the preserved recovery image.
- Disk-layout rechecks before modification.
- Detailed command output and persistent activity logs.
- An option to re-enable the original WinRE if preparation is cancelled before partition changes.

Status summaries reflect the last check performed by the tool; they are not continuous monitoring.

## Requirements and supported scope

| Item | Requirement |
|---|---|
| Operating environment | Windows Server with Desktop Experience |
| PowerShell | Elevated, 64-bit **Windows PowerShell 5.1**; PowerShell 7 is rejected |
| Windows installation | Running from C: |
| Disk | Healthy, online, writable, non-clustered GPT disk |
| File system | Healthy NTFS C: volume |
| Partition layout | Exactly EFI System, Microsoft Reserved, C:, and one standard Recovery partition, in that order |
| Added capacity | Sufficient unallocated space after Recovery on the same disk |
| Existing Recovery | 300 MiB–2 GiB, without a drive letter, directly after C: within the script's alignment tolerance |
| WinRE | Initially enabled and registered on the identified Recovery partition |
| Language | English `reagentc /info` output |
| BitLocker | Feature not installed, or C: fully decrypted, 0% encrypted, and unlocked |
| Free space on C: | At least 3 GiB before preserving the recovery image |
| Recovery image | Must fit the fixed 1 GiB replacement partition with the script's free-space margin |

The script uses Windows Forms, Windows Storage cmdlets, `Get-WindowsFeature`, `reagentc.exe`, and `diskpart.exe`. When BitLocker is installed, it also requires `Get-BitLockerVolume`.

Windows client editions, Server Core, non-English REAgentC output, MBR/dynamic disks, clustered disks, nonstandard partition layouts, and OEM/custom recovery partitions are outside the intended scope. There is no version-by-version Windows Server compatibility matrix yet.

## Getting started

1. Download `Extend-C-GUI.ps1` and review its contents.
2. Verify your backup and ensure the additional disk capacity is visible in Windows.
3. Open **Windows PowerShell as Administrator**.
4. Change to the folder containing the script and run:

```powershell
powershell.exe -NoProfile -STA -File .\Extend-C-GUI.ps1
```

If execution policy prevents launch, follow your organization's script-signing and execution-policy process. The tool does not change execution policy automatically.

### Guided mode

| Action | Purpose |
|---|---|
| **1. Inspect partitions** | Display the layout, identify the Recovery candidate, and estimate the new C: size. |
| **2. Verify WinRE match** | Confirm that the candidate is the partition registered for active WinRE. |
| **3. Check BitLocker** | Read protection, encryption, and lock status; show guidance if changes are blocked. |
| **4. Disable + preserve WinRE** | Disable WinRE, verify the image, and preserve a hash-checked copy. |
| **5. Extend C: + rebuild Recovery** | Delete the verified Recovery partition, extend C:, and recreate Recovery. |
| **6. Enable WinRE + validate** | Enable WinRE on the new partition and validate the result. |

Steps 1–3 do not change partitions or WinRE configuration; local logs are written.

After step 4, **Enable WinRE + validate** can restore the original WinRE registration if you decide not to continue. After step 5, step 6 is required to finish the workflow.

Keep the same window open while progressing through the steps. Session state is not restored after closing the application. Incomplete workflows require review before a new session can proceed.

### Quick mode

1. Select **Analyze** to run the read-only checks and review the proposed change.
2. Select **Extend C:** and confirm to run the complete workflow, including WinRE re-enablement and final validation.

Both tabs share the current session state. If you already disabled WinRE in Guided mode, finish the workflow there.

## BitLocker behavior

The tool does **not** suspend, decrypt, or re-encrypt drives automatically. If C: remains encrypted, it blocks the resize and displays instructions.

`ProtectionStatus: Off` does not necessarily mean the disk is decrypted. Suspended protection is insufficient for this tool's checks. Requiring a fully decrypted drive is a limitation of this implementation, not a claim that every Windows partition-extension procedure requires decryption.

If encryption is enabled, use an approved BitLocker-aware procedure or obtain authorization for decryption. Verify recovery-key availability through your organization's approved process. If you decrypt the drive, restore encryption and key escrow afterward according to policy.

The status output deliberately excludes BitLocker recovery passwords and key-protector objects.

## Logs and recovery image

Each run creates a timestamped folder under:

```text
%ProgramData%\Extend-C-GUI\
```

Depending on the steps completed, it contains:

- `activity.log` — commands, results, and errors.
- `partitions-before.xml` — partition metadata captured before preparation.
- `Winre.wim` — the preserved recovery image.
- `diskpart-*.txt` — generated DiskPart command files.

These files are retained automatically. The WIM copy is stored on C: and will not protect against loss of the disk or VM. Only `Winre.wim` is preserved; additional custom recovery content is not backed up by this tool.

## Validation and failure handling

On successful completion, check that the UI reports **Done**, WinRE is enabled on the expected partition, C: has grown, and applications remain healthy.

The script checks the final partition count, unchanged EFI/MSR identities and sizes, WinRE registration, volume health, and at least 250 MiB of free space on Recovery. It does not boot into WinRE or perform application-level tests. Schedule a separate maintenance window if a recovery boot test is required.

If a step fails:

1. Read the failed-stage message and retain the log folder.
2. Do not blindly repeat partition-changing commands.
3. If preparation stopped before deletion, use **Enable WinRE** when available to restore the original registration.
4. If partition modification started, inspect Disk Management and `reagentc /info` before deciding how to recover.

There is no automatic partition rollback. Following a destructive-stage failure, further automated changes are blocked. Do not run other partition-management tools concurrently.

## Microsoft references

- [Extend a basic or dynamic volume](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/extend-a-basic-volume)
- [REAgentC command-line options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options)
- [KB5028997: Manually resize the WinRE partition](https://support.microsoft.com/en-us/topic/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update-400faa27-9343-461c-ada9-24c8229763bf)
- [BitLocker operations guide](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/operations-guide)

This is an independent utility. The references document underlying Windows operations; they do not constitute Microsoft validation or endorsement of this script.
