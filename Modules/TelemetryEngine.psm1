# Core engine: enumerates NVIDIA telemetry targets, reads their live state, and applies/reverts
# changes. Every mutating function captures the original value in the snapshot store first and
# honours -DryRun. Requires SnapshotStore.psm1 to be imported into the session.

$script:NvRoot        = Join-Path $env:ProgramFiles 'NVIDIA Corporation'
$script:PluginLink    = Join-Path $script:NvRoot 'NvContainer\plugins\LocalSystem\NvTelemetry'
$script:PluginTarget  = Join-Path $script:NvRoot 'NvTelemetry\plugin'
$script:HostsPath     = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:HostsBegin    = '# >>> NvTeleGuard telemetry block BEGIN (managed - do not edit) >>>'
$script:HostsEnd      = '# <<< NvTeleGuard telemetry block END <<<'
# Markers written by the pre-rename build (NvGuard); still recognised so those blocks can be restored.
$script:HostsBeginLegacy = '# >>> NvGuard telemetry block BEGIN (managed - do not edit) >>>'
$script:HostsEndLegacy   = '# <<< NvGuard telemetry block END <<<'
$script:IfeoKey       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\NvTelemetryContainer.exe'
$script:DataDir       = $null

# Upload endpoints confirmed from NvTelemetry64.dll strings, NvTelemetry.log and NvConfig\LocalizedConfig.json
# on driver 616.56 / NVIDIA App 11.0.8, plus the GeForce Experience-era hosts. Deliberately excludes
# gfwsl.geforce.com (driver downloads), login.nvidia.com and activation.gfe.nvidia.com.
$script:TelemetryHosts = @(
    'events.telemetry.data.nvidia.com',
    'feedbacks.telemetry.data.nvidia.com',
    'events.gfe.nvidia.com',
    'telemetry.gfe.nvidia.com',
    'telemetry.nvidia.com',
    'ls.dtrace.nvidia.com'
)

function Initialize-TelemetryEngine {
    param([Parameter(Mandatory)][string]$DataDirectory)
    $script:DataDir = $DataDirectory
}

function Get-TelemetryHostList { return $script:TelemetryHosts }
function Get-HostsFilePath { return $script:HostsPath }

function New-Target {
    param(
        [string]$Id, [string]$Category, [int]$Order, [string]$DisplayName, [string]$Description,
        [string]$Kind, [hashtable]$Params, [switch]$Advanced, [switch]$Recommended
    )
    return [PSCustomObject]@{
        Id          = $Id
        Category    = $Category
        Order       = $Order
        DisplayName = $DisplayName
        Description = $Description
        Kind        = $Kind
        Params      = $Params
        Advanced    = [bool]$Advanced
        Recommended = [bool]$Recommended
    }
}

function New-State {
    param([string]$State, [string]$Detail)
    return [PSCustomObject]@{ State = $State; Detail = $Detail }
}

function New-Result {
    param($Target, [string]$Action, [string]$Result, [string]$Previous = '', [string]$New = '', [string]$Detail = '', [string]$Item = '')
    $name = $Target.DisplayName
    if ($Item) { $name = "$name / $Item" }
    return [PSCustomObject]@{
        Id       = $Target.Id
        Category = $Target.Category
        Target   = $name
        Action   = $Action
        Previous = $Previous
        New      = $New
        Result   = $Result
        Detail   = $Detail
    }
}

# ---------------------------------------------------------------------------------------------
# Target inventory
# ---------------------------------------------------------------------------------------------

function Get-FriendlyTaskName {
    # NVIDIA suffixes most task names with a per-install GUID; show a readable name and keep the raw
    # name in the card's detail line instead.
    param([string]$TaskName)
    $base = $TaskName -replace '_\{[^}]+\}$', ''
    switch -Wildcard ($base) {
        'NVIDIA App SelfUpdate'      { return 'Disable NVIDIA App/Driver auto-update check' }
        'NvDriverUpdateCheckDaily'   { return 'Disable driver auto-update check (daily)' }
        'NvDriverUpdateCheckOnLogon*' { return 'Disable driver auto-update check (at logon)' }
        'NvProfileUpdaterDaily'      { return 'Game profile updater (daily)' }
        'NvProfileUpdaterOnLogon'    { return 'Game profile updater (at logon)' }
        'NvTmMon'                    { return 'Telemetry monitor task (NvTmMon)' }
        'NvTmRepOnLogon'             { return 'Telemetry report task at logon (NvTmRepOnLogon)' }
        'NvTmRep*'                   { return "Telemetry report task ($base)" }
        default                      { return "Scheduled task $base" }
    }
}

function Get-UpdateTaskDescription {
    param([string]$TaskName)
    $base = $TaskName -replace '_\{[^}]+\}$', ''
    switch -Wildcard ($base) {
        'NVIDIA App SelfUpdate' { return 'This task phones home to NVIDIA to send you notifications of updates to the NVIDIA App itself and when new driver updates are available. Enable to stop these notifications.' }
        'NvDriverUpdateCheck*'  { return 'This task phones home to NVIDIA to send you notifications when new driver updates are available. Enable to stop these notifications.' }
        'NvProfileUpdater*'     { return 'This task phones home to NVIDIA to download updated game profiles (optimal settings). Enable to stop it.' }
        default                 { return 'This task phones home to NVIDIA to check for updates. Enable to stop it.' }
    }
}

function Get-TelemetryTargets {
    $list = New-Object System.Collections.Generic.List[object]

    $list.Add((New-Target -Id 'plugin:NvTelemetry' -Category 'Telemetry Client Plugin (modern drivers)' -Order 1 `
        -DisplayName 'NVIDIA Telemetry Client plugin (NvTelemetry64.dll)' `
        -Description "On current drivers the telemetry client is a plugin the NVIDIA LocalSystem Container loads through the 'NvTelemetry' junction. Removing that junction unplugs it while leaving Control Panel, ShadowPlay and the other container plugins intact." `
        -Kind 'PluginJunction' -Recommended `
        -Params @{ LinkPath = $script:PluginLink; TargetPath = $script:PluginTarget; ServiceName = 'NvContainerLocalSystem' }))

    $list.Add((New-Target -Id 'service:NvTelemetryContainer' -Category 'Legacy Telemetry Service' -Order 2 `
        -DisplayName 'NVIDIA Telemetry Container service' `
        -Description 'Standalone telemetry service shipped with GeForce Experience-era drivers. Stopped and set to Disabled. Not present on modern driver installs.' `
        -Kind 'Service' -Recommended -Params @{ Name = 'NvTelemetryContainer' }))

    $allTasks = @()
    try { $allTasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { $allTasks = @() }

    $tmTasks = @($allTasks | Where-Object { $_.TaskName -like 'NvTm*' })
    if ($tmTasks.Count -gt 0) {
        foreach ($t in $tmTasks) {
            $list.Add((New-Target -Id "task:$($t.TaskPath)$($t.TaskName)" -Category 'Legacy Telemetry Tasks' -Order 3 `
                -DisplayName (Get-FriendlyTaskName $t.TaskName) `
                -Description "Telemetry monitor/report task under $($t.TaskPath)." `
                -Kind 'ScheduledTask' -Recommended -Params @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName }))
        }
    } else {
        $list.Add((New-Target -Id 'task:NvTm:none' -Category 'Legacy Telemetry Tasks' -Order 3 `
            -DisplayName 'NvTm* telemetry tasks (NvTmMon / NvTmRep / NvTmRepOnLogon)' `
            -Description 'Scheduled telemetry tasks from GeForce Experience-era drivers. None exist on this system.' `
            -Kind 'Absent' -Params @{ Reason = 'No NvTm* scheduled tasks found' }))
    }

    $list.Add((New-Target -Id 'registry:OptInOrOutPreference' -Category 'Legacy Registry Opt-Out Flags' -Order 4 `
        -DisplayName 'Control Panel telemetry opt-in (OptInOrOutPreference)' `
        -Description 'HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client -> OptInOrOutPreference = 0. Only exists on older Control Panel / GeForce Experience installs.' `
        -Kind 'RegistryValues' -Recommended `
        -Params @{ Path = 'HKLM:\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client'; Values = @(@{ Name = 'OptInOrOutPreference'; DisabledData = 0 }) }))

    $list.Add((New-Target -Id 'registry:FTS-EnableRID' -Category 'Legacy Registry Opt-Out Flags' -Order 4 `
        -DisplayName 'Gameplay session telemetry flags (Global\FTS EnableRID*)' `
        -Description 'HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS -> EnableRID44231 / EnableRID64640 / EnableRID66610 = 0. Only exists on older drivers.' `
        -Kind 'RegistryValues' -Recommended `
        -Params @{ Path = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\FTS'; Values = @(
            @{ Name = 'EnableRID44231'; DisabledData = 0 },
            @{ Name = 'EnableRID64640'; DisabledData = 0 },
            @{ Name = 'EnableRID66610'; DisabledData = 0 }) }))

    $updateTasks = @($allTasks | Where-Object {
        $_.TaskName -like 'NVIDIA App SelfUpdate*' -or $_.TaskName -like 'NvDriverUpdateCheck*' -or $_.TaskName -like 'NvProfileUpdater*'
    })
    if ($updateTasks.Count -gt 0) {
        foreach ($t in $updateTasks) {
            $list.Add((New-Target -Id "task:$($t.TaskPath)$($t.TaskName)" -Category 'Update-Check Tasks (optional)' -Order 5 `
                -DisplayName (Get-FriendlyTaskName $t.TaskName) `
                -Description (Get-UpdateTaskDescription $t.TaskName) `
                -Kind 'ScheduledTask' -Params @{ TaskPath = $t.TaskPath; TaskName = $t.TaskName }))
        }
    } else {
        $list.Add((New-Target -Id 'task:update:none' -Category 'Update-Check Tasks (optional)' -Order 5 `
            -DisplayName 'NVIDIA update-check tasks' `
            -Description 'NVIDIA App SelfUpdate / NvDriverUpdateCheck / NvProfileUpdater tasks that phone home for update checks. None exist on this system, so there is nothing to switch.' `
            -Kind 'Absent' -Params @{ Reason = 'No update-check scheduled tasks found' }))
    }

    $list.Add((New-Target -Id 'service:NvContainerLocalSystem' -Category 'Advanced / Aggressive' -Order 6 `
        -DisplayName 'NVIDIA LocalSystem Container service (whole container)' `
        -Description 'Disables the entire NvContainerLocalSystem service. Also hosts the NVIDIA App Control Panel, ShadowPlay and message-bus plugins, so expect those to stop working. Prefer the plugin toggle above.' `
        -Kind 'Service' -Advanced -Params @{ Name = 'NvContainerLocalSystem' }))

    $list.Add((New-Target -Id 'service:NvContainerNetworkService' -Category 'Advanced / Aggressive' -Order 6 `
        -DisplayName 'NVIDIA NetworkService Container service' `
        -Description 'Older-driver network-service container (GameStream and friends). Not present on modern installs.' `
        -Kind 'Service' -Advanced -Params @{ Name = 'NvContainerNetworkService' }))

    $list.Add((New-Target -Id 'ifeo:NvTelemetryContainer.exe' -Category 'Advanced / Aggressive' -Order 6 `
        -DisplayName 'Hard-block NvTelemetryContainer.exe (IFEO)' `
        -Description 'Adds an Image File Execution Options "Debugger" entry so the legacy telemetry executable can never launch. Effective but the same technique is used by malware, so some antivirus products flag it. Legacy drivers only.' `
        -Kind 'IFEOBlock' -Advanced -Params @{ KeyPath = $script:IfeoKey; Image = 'NvTelemetryContainer.exe' }))

    $list.Add((New-Target -Id 'hosts:telemetry' -Category 'Advanced / Aggressive' -Order 6 `
        -DisplayName 'Block telemetry upload endpoints (hosts file)' `
        -Description ("Points these hosts at 0.0.0.0 in the Windows hosts file: " + ($script:TelemetryHosts -join ', ') + ". Driver downloads and NVIDIA login are not touched. Windows Defender occasionally flags hosts-file edits.") `
        -Kind 'HostsBlock' -Advanced -Params @{ Hosts = $script:TelemetryHosts }))

    return $list.ToArray()
}

# ---------------------------------------------------------------------------------------------
# Live state
# ---------------------------------------------------------------------------------------------

function Get-HostsContent {
    if (Test-Path -LiteralPath $script:HostsPath) {
        return [System.IO.File]::ReadAllText($script:HostsPath)
    }
    return ''
}

function Test-HostsBlockPresent {
    $content = Get-HostsContent
    return (($content -like "*$($script:HostsBegin)*") -or ($content -like "*$($script:HostsBeginLegacy)*"))
}

function Get-TargetState {
    param([Parameter(Mandatory)]$Target)
    $p = $Target.Params
    try {
        switch ($Target.Kind) {
            'Absent' { return New-State 'NotPresent' $p.Reason }

            'Service' {
                $svc = Get-Service -Name $p.Name -ErrorAction SilentlyContinue
                if (-not $svc) { return New-State 'NotPresent' 'Service is not installed on this system' }
                $detail = "Status: $($svc.Status), Startup type: $($svc.StartType)"
                if ($svc.StartType -eq 'Disabled') { return New-State 'Disabled' $detail }
                return New-State 'Enabled' $detail
            }

            'ScheduledTask' {
                $t = Get-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -ErrorAction SilentlyContinue
                $where = "Task Scheduler: $($p.TaskPath)$($p.TaskName)"
                if (-not $t) { return New-State 'NotPresent' "Task no longer exists ($where)" }
                if ($t.State -eq 'Disabled') { return New-State 'Disabled' "Task state: Disabled - $where" }
                return New-State 'Enabled' "Task state: $($t.State) - $where"
            }

            'RegistryValues' {
                if (-not (Test-Path -LiteralPath $p.Path)) { return New-State 'NotPresent' "Key does not exist on this driver: $($p.Path -replace '^HKLM:\\', 'HKLM\')" }
                $key = Get-Item -LiteralPath $p.Path
                $allOff = $true
                $parts = @()
                foreach ($v in $p.Values) {
                    $cur = $key.GetValue($v.Name, $null)
                    if ($null -eq $cur) { $parts += "$($v.Name)=<absent>"; $allOff = $false }
                    else {
                        $parts += "$($v.Name)=$cur"
                        if ([int64]$cur -ne [int64]$v.DisabledData) { $allOff = $false }
                    }
                }
                if ($allOff) { return New-State 'Disabled' ($parts -join ', ') }
                return New-State 'Enabled' ($parts -join ', ')
            }

            'PluginJunction' {
                $link = Get-Item -LiteralPath $p.LinkPath -Force -ErrorAction SilentlyContinue
                if ($link) {
                    if ($link.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        return New-State 'Enabled' "Junction present -> $($p.TargetPath)"
                    }
                    return New-State 'Enabled' 'Plugin folder present (real directory, not a junction)'
                }
                if (Test-Path -LiteralPath (Join-Path $p.TargetPath 'NvTelemetry64.dll')) {
                    return New-State 'Disabled' 'Junction removed - NvTelemetry64.dll is installed but no longer loaded by the container'
                }
                return New-State 'NotPresent' 'NVIDIA Telemetry Client component is not installed'
            }

            'IFEOBlock' {
                $dbg = $null
                if (Test-Path -LiteralPath $p.KeyPath) { $dbg = (Get-Item -LiteralPath $p.KeyPath).GetValue('Debugger', $null) }
                if ($dbg) { return New-State 'Disabled' "IFEO Debugger = $dbg" }
                $svc = Get-Service -Name 'NvTelemetryContainer' -ErrorAction SilentlyContinue
                if ($svc) { return New-State 'Enabled' 'No IFEO block set' }
                return New-State 'NotPresent' 'Legacy NvTelemetryContainer.exe is not installed on this system'
            }

            'HostsBlock' {
                if (Test-HostsBlockPresent) { return New-State 'Disabled' "$($p.Hosts.Count) telemetry hosts blocked via $($script:HostsPath)" }
                return New-State 'Enabled' 'No NvTeleGuard block present in the hosts file'
            }
        }
        return New-State 'NotPresent' "Unknown target kind '$($Target.Kind)'"
    } catch {
        return New-State 'NotPresent' "Could not read state: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------------------------
# Disable (apply protection)
# ---------------------------------------------------------------------------------------------

function Get-BlockDebuggerPath {
    $systray = Join-Path $env:SystemRoot 'System32\systray.exe'
    if (Test-Path -LiteralPath $systray) { return $systray }
    return (Join-Path $script:DataDir 'block\NvTeleGuard-block-stub.exe')
}

function Disable-Target {
    param([Parameter(Mandatory)]$Target, [switch]$DryRun)
    $p = $Target.Params
    $results = New-Object System.Collections.Generic.List[object]
    $mode = if ($DryRun) { 'DryRun' } else { 'OK' }

    try {
        switch ($Target.Kind) {
            'Absent' { $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail $p.Reason)) }

            'Service' {
                $svc = Get-Service -Name $p.Name -ErrorAction SilentlyContinue
                if (-not $svc) { $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail 'Service not installed')); break }
                $prev = "$($svc.StartType)/$($svc.Status)"
                if ($svc.StartType -eq 'Disabled' -and $svc.Status -ne 'Running') {
                    $results.Add((New-Result $Target 'Disable' 'Skipped' -Previous $prev -Detail 'Already disabled and stopped')); break
                }
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original @{ Kind = 'Service'; Name = $p.Name; StartType = [string]$svc.StartType; WasRunning = ($svc.Status -eq 'Running') } | Out-Null }
                if (-not $DryRun) {
                    if ($svc.Status -eq 'Running') { Stop-Service -Name $p.Name -Force -ErrorAction Stop }
                    Set-Service -Name $p.Name -StartupType Disabled -ErrorAction Stop
                }
                $results.Add((New-Result $Target 'Disabled service' $mode -Previous $prev -New 'Disabled/Stopped'))
            }

            'ScheduledTask' {
                $t = Get-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -ErrorAction SilentlyContinue
                if (-not $t) { $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail 'Task no longer exists')); break }
                if ($t.State -eq 'Disabled') { $results.Add((New-Result $Target 'Disable' 'Skipped' -Previous 'Disabled' -Detail 'Already disabled')); break }
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original @{ Kind = 'ScheduledTask'; TaskPath = $p.TaskPath; TaskName = $p.TaskName; WasEnabled = $true } | Out-Null }
                if (-not $DryRun) { Disable-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -ErrorAction Stop | Out-Null }
                $results.Add((New-Result $Target 'Disabled scheduled task' $mode -Previous ([string]$t.State) -New 'Disabled'))
            }

            'RegistryValues' {
                if (-not (Test-Path -LiteralPath $p.Path)) { $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail 'Registry key does not exist on this driver')); break }
                $key = Get-Item -LiteralPath $p.Path
                $orig = @{ Kind = 'RegistryValues'; Path = $p.Path; Values = @{} }
                foreach ($v in $p.Values) {
                    $cur = $key.GetValue($v.Name, $null)
                    $entry = @{ Existed = ($null -ne $cur) }
                    if ($null -ne $cur) { $entry['Data'] = $cur; $entry['Kind'] = [string]$key.GetValueKind($v.Name) }
                    $orig.Values[$v.Name] = $entry
                }
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original $orig | Out-Null }
                foreach ($v in $p.Values) {
                    $cur = $key.GetValue($v.Name, $null)
                    $prev = if ($null -eq $cur) { '<absent>' } else { [string]$cur }
                    if ($null -ne $cur -and [int64]$cur -eq [int64]$v.DisabledData) {
                        $results.Add((New-Result $Target 'Set value' 'Skipped' -Item $v.Name -Previous $prev -Detail 'Already set')); continue
                    }
                    if (-not $DryRun) { Set-ItemProperty -LiteralPath $p.Path -Name $v.Name -Value ([int]$v.DisabledData) -Type DWord -Force -ErrorAction Stop }
                    $results.Add((New-Result $Target 'Set value' $mode -Item $v.Name -Previous $prev -New ([string]$v.DisabledData)))
                }
            }

            'PluginJunction' {
                $link = Get-Item -LiteralPath $p.LinkPath -Force -ErrorAction SilentlyContinue
                if (-not $link) {
                    $why = if (Test-Path -LiteralPath (Join-Path $p.TargetPath 'NvTelemetry64.dll')) { 'Junction already removed' } else { 'Telemetry client component not installed' }
                    $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail $why)); break
                }
                if (-not ($link.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $results.Add((New-Result $Target 'Disable' 'Failed' -Detail 'Refusing to touch it: path is a real directory, not a junction')); break
                }
                $linkTarget = $null
                try { $linkTarget = @($link.Target)[0] } catch { }
                if (-not $linkTarget) { $linkTarget = $p.TargetPath }
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original @{ Kind = 'PluginJunction'; LinkPath = $p.LinkPath; Target = [string]$linkTarget } | Out-Null }
                $detail = ''
                if (-not $DryRun) {
                    # Directory.Delete on a reparse point removes only the link, never the target contents.
                    [System.IO.Directory]::Delete($p.LinkPath)
                    if (-not (Test-Path -LiteralPath (Join-Path $linkTarget 'NvTelemetry64.dll'))) { $detail = 'WARNING: target plugin folder looks incomplete after unlink' }
                    $svc = Get-Service -Name $p.ServiceName -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        try { Restart-Service -Name $p.ServiceName -Force -ErrorAction Stop; $detail = 'Restarted NvContainerLocalSystem so the plugin unloads' }
                        catch { $detail = "Junction removed; could not restart NvContainerLocalSystem ($($_.Exception.Message)) - takes effect after reboot" }
                    } else { $detail = 'Container service not running; takes effect next time it starts' }
                }
                $results.Add((New-Result $Target 'Removed plugin junction' $mode -Previous 'Junction present' -New 'Junction removed' -Detail $detail))
            }

            'IFEOBlock' {
                $keyExisted = Test-Path -LiteralPath $p.KeyPath
                $dbg = $null
                if ($keyExisted) { $dbg = (Get-Item -LiteralPath $p.KeyPath).GetValue('Debugger', $null) }
                if ($dbg) { $results.Add((New-Result $Target 'Disable' 'Skipped' -Previous ([string]$dbg) -Detail 'IFEO block already present')); break }
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original @{ Kind = 'IFEOBlock'; KeyPath = $p.KeyPath; KeyExisted = $keyExisted; DebuggerExisted = $false } | Out-Null }
                $blocker = Get-BlockDebuggerPath
                if (-not $DryRun) {
                    if (-not $keyExisted) { New-Item -Path $p.KeyPath -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -LiteralPath $p.KeyPath -Name 'Debugger' -Value $blocker -Type String -Force -ErrorAction Stop
                }
                $results.Add((New-Result $Target 'Added IFEO block' $mode -Previous '<none>' -New "Debugger=$blocker"))
            }

            'HostsBlock' {
                if (Test-HostsBlockPresent) { $results.Add((New-Result $Target 'Disable' 'Skipped' -Detail 'Block already present')); break }
                $backup = Join-Path $script:DataDir ("hosts.backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                if (-not $DryRun) { Save-OriginalState -Id $Target.Id -Original @{ Kind = 'HostsBlock'; BackupPath = $backup } | Out-Null }
                if (-not $DryRun) {
                    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
                    Copy-Item -LiteralPath $script:HostsPath -Destination $backup -Force -ErrorAction Stop
                    $existing = Get-HostsContent
                    $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`r`n" } else { '' }
                    $block = $script:HostsBegin + "`r`n" + (($p.Hosts | ForEach-Object { "0.0.0.0 $_" }) -join "`r`n") + "`r`n" + $script:HostsEnd + "`r`n"
                    [System.IO.File]::AppendAllText($script:HostsPath, $prefix + $block, [System.Text.Encoding]::ASCII)
                    try { & ipconfig.exe /flushdns | Out-Null } catch { }
                }
                $results.Add((New-Result $Target 'Blocked telemetry hosts' $mode -Previous '0 blocked' -New "$($p.Hosts.Count) blocked" -Detail "Backup: $backup"))
            }

            default { $results.Add((New-Result $Target 'Disable' 'Failed' -Detail "Unknown target kind '$($Target.Kind)'")) }
        }
    } catch {
        $results.Add((New-Result $Target 'Disable' 'Failed' -Detail $_.Exception.Message))
    }
    return $results.ToArray()
}

# ---------------------------------------------------------------------------------------------
# Restore (undo protection, back to snapshotted original)
# ---------------------------------------------------------------------------------------------

function ConvertTo-StartupType {
    param([string]$Text)
    switch -Regex ($Text) {
        '^Auto'     { return 'Automatic' }
        '^Manual'   { return 'Manual' }
        '^Disabled' { return 'Disabled' }
        '^Boot'     { return 'Boot' }
        '^System'   { return 'System' }
        default     { return 'Manual' }
    }
}

function Restore-Target {
    param([Parameter(Mandatory)]$Target, [switch]$DryRun)
    $p = $Target.Params
    $results = New-Object System.Collections.Generic.List[object]
    $mode = if ($DryRun) { 'DryRun' } else { 'OK' }

    $orig = Get-OriginalState -Id $Target.Id
    if (-not $orig) {
        $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'No snapshot for this item - NvTeleGuard never changed it'))
        return $results.ToArray()
    }

    try {
        switch ($Target.Kind) {
            'Service' {
                $svc = Get-Service -Name $p.Name -ErrorAction SilentlyContinue
                if (-not $svc) { $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'Service no longer installed')); break }
                $startType = ConvertTo-StartupType $orig.StartType
                $prev = "$($svc.StartType)/$($svc.Status)"
                if (-not $DryRun) {
                    Set-Service -Name $p.Name -StartupType $startType -ErrorAction Stop
                    if ($orig.WasRunning -and $svc.Status -ne 'Running') { try { Start-Service -Name $p.Name -ErrorAction Stop } catch { } }
                    Remove-OriginalState -Id $Target.Id | Out-Null
                }
                $new = "$startType/" + $(if ($orig.WasRunning) { 'Running' } else { 'Stopped' })
                $results.Add((New-Result $Target 'Restored service' $mode -Previous $prev -New $new))
            }

            'ScheduledTask' {
                $t = Get-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -ErrorAction SilentlyContinue
                if (-not $t) { $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'Task no longer exists')); break }
                if (-not $DryRun) {
                    if ($orig.WasEnabled) { Enable-ScheduledTask -TaskPath $p.TaskPath -TaskName $p.TaskName -ErrorAction Stop | Out-Null }
                    Remove-OriginalState -Id $Target.Id | Out-Null
                }
                $results.Add((New-Result $Target 'Restored scheduled task' $mode -Previous ([string]$t.State) -New $(if ($orig.WasEnabled) { 'Ready' } else { 'Disabled' })))
            }

            'RegistryValues' {
                if (-not (Test-Path -LiteralPath $p.Path)) { $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'Registry key no longer exists')); break }
                $key = Get-Item -LiteralPath $p.Path
                foreach ($name in @($orig.Values.Keys)) {
                    $entry = $orig.Values[$name]
                    $cur = $key.GetValue($name, $null)
                    $prev = if ($null -eq $cur) { '<absent>' } else { [string]$cur }
                    if ($entry.Existed) {
                        $kind = if ($entry.Kind) { $entry.Kind } else { 'DWord' }
                        if (-not $DryRun) { Set-ItemProperty -LiteralPath $p.Path -Name $name -Value $entry.Data -Type $kind -Force -ErrorAction Stop }
                        $results.Add((New-Result $Target 'Restored value' $mode -Item $name -Previous $prev -New ([string]$entry.Data)))
                    } else {
                        if (-not $DryRun -and $null -ne $cur) { Remove-ItemProperty -LiteralPath $p.Path -Name $name -Force -ErrorAction Stop }
                        $results.Add((New-Result $Target 'Removed value' $mode -Item $name -Previous $prev -New '<absent>'))
                    }
                }
                if (-not $DryRun) { Remove-OriginalState -Id $Target.Id | Out-Null }
            }

            'PluginJunction' {
                if (Test-Path -LiteralPath $p.LinkPath) { $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'Junction already present')); if (-not $DryRun) { Remove-OriginalState -Id $Target.Id | Out-Null }; break }
                $linkTarget = if ($orig.Target) { [string]$orig.Target } else { $p.TargetPath }
                if (-not (Test-Path -LiteralPath $linkTarget)) { $results.Add((New-Result $Target 'Restore' 'Failed' -Detail "Plugin target folder is missing: $linkTarget")); break }
                $detail = ''
                if (-not $DryRun) {
                    New-Item -ItemType Junction -Path $p.LinkPath -Value $linkTarget -ErrorAction Stop | Out-Null
                    $svc = Get-Service -Name $p.ServiceName -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Running') {
                        try { Restart-Service -Name $p.ServiceName -Force -ErrorAction Stop; $detail = 'Restarted NvContainerLocalSystem so the plugin reloads' } catch { $detail = 'Junction restored; container restart failed - reloads after reboot' }
                    }
                    Remove-OriginalState -Id $Target.Id | Out-Null
                }
                $results.Add((New-Result $Target 'Recreated plugin junction' $mode -Previous 'Junction removed' -New "Junction -> $linkTarget" -Detail $detail))
            }

            'IFEOBlock' {
                $exists = Test-Path -LiteralPath $p.KeyPath
                $dbg = $null
                if ($exists) { $dbg = (Get-Item -LiteralPath $p.KeyPath).GetValue('Debugger', $null) }
                if (-not $DryRun) {
                    if ($orig.DebuggerExisted -and $orig.Debugger) { Set-ItemProperty -LiteralPath $p.KeyPath -Name 'Debugger' -Value $orig.Debugger -Type String -Force -ErrorAction Stop }
                    elseif ($exists -and $null -ne $dbg) { Remove-ItemProperty -LiteralPath $p.KeyPath -Name 'Debugger' -Force -ErrorAction Stop }
                    if ($exists -and -not $orig.KeyExisted) { Remove-Item -LiteralPath $p.KeyPath -Force -ErrorAction SilentlyContinue }
                    Remove-OriginalState -Id $Target.Id | Out-Null
                }
                $results.Add((New-Result $Target 'Removed IFEO block' $mode -Previous ([string]$dbg) -New $(if ($orig.DebuggerExisted) { [string]$orig.Debugger } else { '<none>' })))
            }

            'HostsBlock' {
                if (-not (Test-HostsBlockPresent)) { $results.Add((New-Result $Target 'Restore' 'Skipped' -Detail 'No NvTeleGuard block in hosts file')); if (-not $DryRun) { Remove-OriginalState -Id $Target.Id | Out-Null }; break }
                if (-not $DryRun) {
                    $lines = [System.IO.File]::ReadAllLines($script:HostsPath)
                    $kept = New-Object System.Collections.Generic.List[string]
                    $inBlock = $false
                    foreach ($line in $lines) {
                        $trimmed = $line.Trim()
                        if ($trimmed -eq $script:HostsBegin -or $trimmed -eq $script:HostsBeginLegacy) { $inBlock = $true; continue }
                        if ($trimmed -eq $script:HostsEnd -or $trimmed -eq $script:HostsEndLegacy) { $inBlock = $false; continue }
                        if (-not $inBlock) { $kept.Add($line) }
                    }
                    [System.IO.File]::WriteAllLines($script:HostsPath, $kept.ToArray(), [System.Text.Encoding]::ASCII)
                    try { & ipconfig.exe /flushdns | Out-Null } catch { }
                    Remove-OriginalState -Id $Target.Id | Out-Null
                }
                $results.Add((New-Result $Target 'Unblocked telemetry hosts' $mode -Previous "$($p.Hosts.Count) blocked" -New '0 blocked'))
            }

            default { $results.Add((New-Result $Target 'Restore' 'Failed' -Detail "Unknown target kind '$($Target.Kind)'")) }
        }
    } catch {
        $results.Add((New-Result $Target 'Restore' 'Failed' -Detail $_.Exception.Message))
    }
    return $results.ToArray()
}

Export-ModuleMember -Function Initialize-TelemetryEngine, Get-TelemetryTargets, Get-TargetState, Disable-Target, Restore-Target, Get-TelemetryHostList, Get-HostsFilePath, Test-HostsBlockPresent
