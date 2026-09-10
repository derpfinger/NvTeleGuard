<#
.SYNOPSIS
    NvTeleGuard - NVIDIA telemetry blocker with a WPF GUI. Reversible, logged, local-only.

.DESCRIPTION
    Batch model: flipping a switch only marks an item as pending. "Apply Changes" confirms the
    batch, applies it, and every card then re-reads live system state - a pill only shows
    BLOCKED once Windows confirms it.

.PARAMETER NoElevate
    Skip the UAC self-elevation. The app then runs read-only (state scan, status test) and
    logs a failure for any change it cannot make.
.PARAMETER DryRun
    Start with dry-run mode on: every action is logged as [DryRun] and nothing is changed.
.PARAMETER ScreenshotPath
    Development aid: build the window, run the status test, render to a PNG and exit.
.PARAMETER ScreenshotScene
    With -ScreenshotPath: 'main' (default view) or 'advanced' (Advanced section expanded,
    dry run on, a pending change shown).
.PARAMETER ShowConsole
    Keep the PowerShell console window visible behind the GUI.
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$DryRun,
    [string]$ScreenshotPath,
    [ValidateSet('main', 'advanced')][string]$ScreenshotScene = 'main',
    [switch]$ShowConsole
)

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.0.0'
$script:AppRoot = $PSScriptRoot
if (-not $script:AppRoot) { $script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ScreenshotPath = $ScreenshotPath
$script:ElevationDeclined = $false

# ------------------------------------------------------------------------------------------------
# Elevation + apartment state
# ------------------------------------------------------------------------------------------------
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RelaunchArguments {
    param([switch]$IncludeNoElevate)
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    if ($DryRun) { $list += '-DryRun' }
    if ($ShowConsole) { $list += '-ShowConsole' }
    if ($ScreenshotPath) { $list += @('-ScreenshotPath', ('"{0}"' -f $ScreenshotPath), '-ScreenshotScene', $ScreenshotScene) }
    if ($IncludeNoElevate -or $NoElevate) { $list += '-NoElevate' }
    return $list
}

$script:IsAdmin = Test-IsAdministrator

if (-not $script:IsAdmin -and -not $NoElevate) {
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-RelaunchArguments) -Verb RunAs -WorkingDirectory $script:AppRoot | Out-Null
        exit 0
    } catch {
        $script:ElevationDeclined = $true
    }
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-RelaunchArguments -IncludeNoElevate) -WorkingDirectory $script:AppRoot -Wait -NoNewWindow
    exit 0
}

# ------------------------------------------------------------------------------------------------
# Assemblies + modules
# ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

foreach ($module in 'SnapshotStore', 'ActionLog', 'UpdateCheck', 'TelemetryEngine', 'StatusReport') {
    Import-Module (Join-Path $script:AppRoot "Modules\$module.psm1") -Force
}

function Initialize-DataDirectory {
    # One-time migration from the pre-rename data folder so existing snapshots/logs are kept.
    $legacy = Join-Path $env:ProgramData 'NvGuard'
    $current = Join-Path $env:ProgramData 'NvTeleGuard'
    if ((Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $current)) {
        try { Rename-Item -LiteralPath $legacy -NewName 'NvTeleGuard' -ErrorAction Stop } catch { }
    }
    $candidates = @($current)
    if (Test-Path -LiteralPath $legacy) { $candidates += $legacy }
    $candidates += (Join-Path $env:LOCALAPPDATA 'NvTeleGuard')
    foreach ($dir in $candidates) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $probe = Join-Path $dir '.write-test'
            Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $dir
        } catch { }
    }
    throw 'NvTeleGuard could not find a writable folder for its snapshot and log files.'
}

$script:DataDir = Initialize-DataDirectory
Initialize-SnapshotStore -Directory $script:DataDir -AppVersion $script:AppVersion | Out-Null
Initialize-ActionLog -Directory $script:DataDir -AppVersion $script:AppVersion | Out-Null
Initialize-TelemetryEngine -DataDirectory $script:DataDir

# ------------------------------------------------------------------------------------------------
# Window
# ------------------------------------------------------------------------------------------------
[xml]$xamlDoc = [System.IO.File]::ReadAllText((Join-Path $script:AppRoot 'UI\MainWindow.xaml'))
$W = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))

$UI = @{}
foreach ($name in 'AdminPill', 'AdminPillText', 'VersionText', 'BtnCheckUpdates', 'UpdateBanner', 'UpdateBannerText',
                  'BtnUpdateLink', 'BtnUpdateClose', 'SummaryText', 'SummarySub', 'BtnTestStatus', 'BtnRefresh',
                  'BtnSelectRecommended', 'BtnApply', 'BtnRestoreAll', 'SectionsPanel', 'BtnUndo', 'BtnOpenLog',
                  'BtnClearLog', 'LogList', 'StatusText', 'DryRunSwitch') {
    $UI[$name] = $W.FindName($name)
}

$script:Targets = @()
$script:Cards = @{}
$script:DryRun = [bool]$DryRun
$script:AdvancedAcknowledged = $false
$script:AdvancedExpanded = $false
$script:AdvancedPanel = $null
$script:AdvancedHeader = $null
$script:UpdateUrl = $null

$script:CategoryNotes = @{
    'Telemetry Client Plugin (modern drivers)' = 'How NVIDIA App-era drivers (2024 and later) run telemetry. On a current install this is the toggle that matters.'
    'Legacy Telemetry Service'                 = 'GeForce Experience-era drivers only. Greyed out means your driver does not ship it.'
    'Legacy Telemetry Tasks'                   = 'Scheduled NvTm* tasks from older drivers. Enumerated live, so they appear automatically if a driver adds them back.'
    'Legacy Registry Opt-Out Flags'            = 'Opt-out registry values that older Control Panel / GeForce Experience builds honour.'
    'Update-Check Tasks (optional)'            = 'Not telemetry - these tasks contact NVIDIA to look for app / driver updates. Switch OFF leaves self-updating alone; switch ON + Apply Changes stops the phoning home. Left alone by Select Recommended.'
    'Advanced / Aggressive'                    = 'Bigger hammers with side effects. Read each description before switching one on. Never part of Select Recommended.'
}

# ------------------------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------------------------
function Get-Brush { param([string]$Key) return $W.FindResource($Key) }

function Update-Ui {
    $W.Dispatcher.Invoke([action] {}, [Windows.Threading.DispatcherPriority]::Render) | Out-Null
}

function Set-Status { param([string]$Text) $UI.StatusText.Text = $Text }

function Add-LogLine {
    param([string]$Text, [string]$Level = 'Info')
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = switch ($Level) {
        'OK'      { Get-Brush 'AccentBrush' }
        'Failed'  { Get-Brush 'RedBrush' }
        'Warn'    { Get-Brush 'AmberBrush' }
        'DryRun'  { Get-Brush 'AmberBrush' }
        'Skipped' { Get-Brush 'DimBrush' }
        default   { Get-Brush 'MutedBrush' }
    }
    [void]$UI.LogList.Items.Add($tb)
    $UI.LogList.ScrollIntoView($tb)
}

function Write-Log {
    param([string]$Category, [string]$Message, [string]$Result = 'Info', [string]$Detail = '')
    Write-ActionEntry -Category $Category -Message $Message -Result $Result -Detail $Detail | Out-Null
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'HH:mm:ss'), $Category, $Message
    if ($Detail) { $line += "  - $Detail" }
    $line += "  [$Result]"
    Add-LogLine -Text $line -Level $Result
}

function Write-EngineResults {
    param($Results)
    foreach ($r in $Results) {
        $msg = '{0}: {1}' -f $r.Action, $r.Target
        if ($r.Previous -or $r.New) { $msg += ' ({0} -> {1})' -f $r.Previous, $r.New }
        Write-Log -Category $r.Category -Message $msg -Result $r.Result -Detail $r.Detail
    }
}

function Confirm-Action {
    param([string]$Message, [string]$Title = 'NvTeleGuard')
    $answer = [Windows.MessageBox]::Show($W, $Message, $Title, [Windows.MessageBoxButton]::OKCancel, [Windows.MessageBoxImage]::Warning)
    return ($answer -eq [Windows.MessageBoxResult]::OK)
}

function Show-Info {
    param([string]$Message, [string]$Title = 'NvTeleGuard')
    [void][Windows.MessageBox]::Show($W, $Message, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
}

function Invoke-UiAction {
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        $where = ''
        if ($_.ScriptStackTrace) { $where = ($_.ScriptStackTrace -split "`n")[0] }
        try { Write-Log -Category 'Error' -Message $msg -Result 'Failed' -Detail $where } catch { }
        Set-Status "Error: $msg"
    }
}

# ------------------------------------------------------------------------------------------------
# Cards
# ------------------------------------------------------------------------------------------------
function New-TextBlock {
    param([string]$Text, [double]$Size = 12, [string]$BrushKey = 'MutedBrush', [switch]$Bold, [switch]$Italic, [double]$Top = 0)
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = Get-Brush $BrushKey
    $tb.TextWrapping = [Windows.TextWrapping]::Wrap
    $tb.Margin = New-Object Windows.Thickness(0, $Top, 0, 0)
    if ($Bold) { $tb.FontWeight = [Windows.FontWeights]::SemiBold }
    if ($Italic) { $tb.FontStyle = [Windows.FontStyles]::Italic }
    return $tb
}

function New-TargetCard {
    param($Target)
    $card = New-Object Windows.Controls.Border
    $card.Style = $W.FindResource('CardStyle')

    $grid = New-Object Windows.Controls.Grid
    foreach ($i in 0..3) {
        $col = New-Object Windows.Controls.ColumnDefinition
        $col.Width = if ($i -eq 0) { New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star) } else { [Windows.GridLength]::Auto }
        $grid.ColumnDefinitions.Add($col)
    }

    $stack = New-Object Windows.Controls.StackPanel
    $stack.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $stack.Margin = New-Object Windows.Thickness(0, 0, 12, 0)
    $title = New-TextBlock -Text $Target.DisplayName -Size 14 -BrushKey 'TextBrush' -Bold
    $desc = New-TextBlock -Text $Target.Description -Size 12 -BrushKey 'MutedBrush' -Top 2
    $detail = New-TextBlock -Text '' -Size 11 -BrushKey 'DimBrush' -Italic -Top 4
    [void]$stack.Children.Add($title)
    [void]$stack.Children.Add($desc)
    [void]$stack.Children.Add($detail)

    $pill = New-Object Windows.Controls.Border
    $pill.Style = $W.FindResource('Pill')
    $pillText = New-Object Windows.Controls.TextBlock
    $pillText.FontSize = 11
    $pillText.FontWeight = [Windows.FontWeights]::SemiBold
    $pillText.Foreground = [Windows.Media.Brushes]::White
    $pill.Child = $pillText

    $pending = New-TextBlock -Text 'pending' -Size 11 -BrushKey 'AmberBrush' -Italic
    $pending.VerticalAlignment = [Windows.VerticalAlignment]::Center
    $pending.Margin = New-Object Windows.Thickness(4, 0, 4, 0)
    $pending.Visibility = [Windows.Visibility]::Collapsed

    $switch = New-Object Windows.Controls.CheckBox
    $switch.Style = $W.FindResource('Switch')
    $switch.Tag = $Target.Id
    $switch.Margin = New-Object Windows.Thickness(6, 0, 0, 0)
    $switch.Add_Click({ param($sender, $e) Invoke-UiAction { Invoke-SwitchToggle -Id $sender.Tag -Checked ([bool]$sender.IsChecked) } })

    [Windows.Controls.Grid]::SetColumn($stack, 0)
    [Windows.Controls.Grid]::SetColumn($pill, 1)
    [Windows.Controls.Grid]::SetColumn($pending, 2)
    [Windows.Controls.Grid]::SetColumn($switch, 3)
    [void]$grid.Children.Add($stack)
    [void]$grid.Children.Add($pill)
    [void]$grid.Children.Add($pending)
    [void]$grid.Children.Add($switch)
    $card.Child = $grid

    $script:Cards[$Target.Id] = @{
        Card = $card; Pill = $pill; PillText = $pillText; Detail = $detail; PendingText = $pending
        Switch = $switch; Target = $Target; State = 'NotPresent'; Pending = $null
    }
    return $card
}

function Update-Card {
    # Pill and detail always reflect live system state; the switch reflects the pending choice if there is one.
    param([string]$Id)
    $c = $script:Cards[$Id]
    if (-not $c) { return }
    $state = Get-TargetState -Target $c.Target
    $c.State = $state.State
    $detail = $state.Detail
    if ($null -ne (Get-OriginalState -Id $Id)) { $detail += '   (changed by NvTeleGuard - original kept in snapshot)' }
    $c.Detail.Text = $detail
    switch ($state.State) {
        'Disabled' {
            $c.PillText.Text = 'BLOCKED'
            $c.Pill.Background = Get-Brush 'AccentBrush'
            $c.Switch.IsEnabled = $true
            $c.Card.Opacity = 1
        }
        'Enabled' {
            $c.PillText.Text = 'ACTIVE'
            $c.Pill.Background = Get-Brush 'AmberBrush'
            $c.Switch.IsEnabled = $true
            $c.Card.Opacity = 1
        }
        default {
            $c.PillText.Text = 'NOT ON THIS DRIVER'
            $c.Pill.Background = Get-Brush 'GreyPillBrush'
            $c.Switch.IsEnabled = $false
            $c.Card.Opacity = 0.55
            $c.Pending = $null
        }
    }
    if ($c.Pending) {
        $c.Switch.IsChecked = ($c.Pending -eq 'Disable')
        $c.PendingText.Visibility = [Windows.Visibility]::Visible
    } else {
        $c.Switch.IsChecked = ($state.State -eq 'Disabled')
        $c.PendingText.Visibility = [Windows.Visibility]::Collapsed
    }
}

function Get-PendingCards {
    return @($script:Cards.Values | Where-Object { $_.Pending } | Sort-Object { $_.Target.Order }, { $_.Target.DisplayName })
}

function Update-Summary {
    $applicable = 0; $blocked = 0; $absent = 0
    foreach ($c in $script:Cards.Values) {
        switch ($c.State) {
            'Disabled' { $applicable++; $blocked++ }
            'Enabled'  { $applicable++ }
            default    { $absent++ }
        }
    }
    $pendingCount = @(Get-PendingCards).Count
    $UI.SummaryText.Text = "$blocked of $applicable protections active"
    $sub = "$absent item(s) not applicable on this driver"
    if ($pendingCount -gt 0) { $sub += "   |   $pendingCount change(s) pending - click Apply Changes" }
    if ($script:DryRun) { $sub += '   |   DRY RUN - nothing will be changed' }
    if (-not $script:IsAdmin) { $sub += '   |   not elevated - read-only' }
    $UI.SummarySub.Text = $sub
    $UI.BtnApply.IsEnabled = ($pendingCount -gt 0)
    $UI.BtnApply.Content = if ($pendingCount -gt 0) { "Apply $pendingCount Change$(if ($pendingCount -ne 1) { 's' })" } else { 'Apply Changes' }
    $UI.BtnUndo.IsEnabled = ((Get-UndoCount) -gt 0)
}

function Update-AllCards {
    foreach ($id in @($script:Cards.Keys)) { Update-Card -Id $id }
    Update-Summary
}

function Switch-AdvancedSection {
    if (-not $script:AdvancedExpanded -and -not $script:AdvancedAcknowledged) {
        $ok = Confirm-Action ("The Advanced section contains changes with side effects:`n`n" +
            " - Disabling the whole LocalSystem container also stops the NVIDIA App Control Panel, ShadowPlay and message-bus plugins.`n" +
            " - The IFEO hard-block uses a technique antivirus products sometimes flag.`n" +
            " - Hosts-file edits are occasionally flagged by Windows Defender.`n`n" +
            "Everything here is reversible with Undo / Restore All Original. Expand the section?")
        if (-not $ok) { return }
        $script:AdvancedAcknowledged = $true
    }
    $script:AdvancedExpanded = -not $script:AdvancedExpanded
    if ($script:AdvancedPanel) {
        $script:AdvancedPanel.Visibility = if ($script:AdvancedExpanded) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    }
    if ($script:AdvancedHeader) {
        $arrow = if ($script:AdvancedExpanded) { 'v' } else { '>' }
        $script:AdvancedHeader.Content = "$arrow  Advanced / Aggressive  (click to " + $(if ($script:AdvancedExpanded) { 'collapse' } else { 'expand' }) + ')'
    }
}

function Build-Sections {
    $UI.SectionsPanel.Children.Clear()
    $script:Cards = @{}
    $script:AdvancedPanel = $null
    $script:AdvancedHeader = $null
    $script:Targets = @(Get-TelemetryTargets)

    $categories = @($script:Targets | Sort-Object Order | Select-Object -ExpandProperty Category -Unique)
    foreach ($cat in $categories) {
        $isAdvanced = ($cat -eq 'Advanced / Aggressive')
        if ($isAdvanced) {
            $header = New-Object Windows.Controls.Button
            $header.Style = $W.FindResource('LinkButton')
            $header.FontSize = 15
            $header.FontWeight = [Windows.FontWeights]::SemiBold
            $header.Foreground = Get-Brush 'AmberBrush'
            $header.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
            $header.Margin = New-Object Windows.Thickness(0, 14, 0, 2)
            $header.Padding = New-Object Windows.Thickness(0)
            $header.Content = '>  Advanced / Aggressive  (click to expand)'
            $header.Add_Click({ Invoke-UiAction { Switch-AdvancedSection } })
            $script:AdvancedHeader = $header
            [void]$UI.SectionsPanel.Children.Add($header)
        } else {
            $header = New-Object Windows.Controls.TextBlock
            $header.Style = $W.FindResource('SectionHeader')
            $header.Text = $cat
            [void]$UI.SectionsPanel.Children.Add($header)
        }

        if ($script:CategoryNotes.ContainsKey($cat)) {
            $sub = New-Object Windows.Controls.TextBlock
            $sub.Style = $W.FindResource('SectionSub')
            $sub.Text = $script:CategoryNotes[$cat]
            [void]$UI.SectionsPanel.Children.Add($sub)
        }

        $panel = New-Object Windows.Controls.StackPanel
        foreach ($t in ($script:Targets | Where-Object { $_.Category -eq $cat })) {
            [void]$panel.Children.Add((New-TargetCard -Target $t))
        }
        if ($isAdvanced) {
            $panel.Visibility = if ($script:AdvancedExpanded) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            $script:AdvancedPanel = $panel
        }
        [void]$UI.SectionsPanel.Children.Add($panel)
    }
    Update-AllCards
}

# ------------------------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------------------------
function Invoke-SwitchToggle {
    # Only records intent. Nothing changes until Apply Changes.
    param([string]$Id, [bool]$Checked)
    $c = $script:Cards[$Id]
    if (-not $c) { return }
    $t = $c.Target
    $liveBlocked = ($c.State -eq 'Disabled')

    if ($Checked -eq $liveBlocked) {
        if ($c.Pending) { Write-Log -Category 'Select' -Message "Cleared pending change for '$($t.DisplayName)'" -Result 'Info' }
        $c.Pending = $null
    } elseif ($Checked) {
        $c.Pending = 'Disable'
        Write-Log -Category 'Select' -Message "Marked '$($t.DisplayName)' to be blocked (pending Apply Changes)" -Result 'Info'
    } else {
        if ($null -eq (Get-OriginalState -Id $Id)) {
            Write-Log -Category 'Select' -Message "'$($t.DisplayName)' was not changed by NvTeleGuard, so there is nothing to restore" -Result 'Skipped' -Detail 'It was already blocked before NvTeleGuard ran - re-enable it in Windows if you need to'
            $c.Pending = $null
            $c.Switch.IsChecked = $true
            Update-Summary
            return
        }
        $c.Pending = 'Restore'
        Write-Log -Category 'Select' -Message "Marked '$($t.DisplayName)' to be restored (pending Apply Changes)" -Result 'Info'
    }
    Update-Card -Id $Id
    Update-Summary
}

function Invoke-ChangeTarget {
    # Runs one engine action and logs it. Returns the engine results (empty on a permissions refusal).
    param([string]$Id, [ValidateSet('Disable', 'Restore')][string]$Action)
    $c = $script:Cards[$Id]
    if (-not $c) { return @() }
    $t = $c.Target
    if (-not $script:IsAdmin -and -not $script:DryRun) {
        Write-Log -Category $t.Category -Message "Cannot change '$($t.DisplayName)'" -Result 'Failed' -Detail 'Not running as administrator - restart NvTeleGuard and accept the UAC prompt'
        return @()
    }
    Set-Status "$(if ($Action -eq 'Disable') { 'Blocking' } else { 'Restoring' }): $($t.DisplayName)..."
    Update-Ui
    $results = if ($Action -eq 'Disable') { @(Disable-Target -Target $t -DryRun:$script:DryRun) } else { @(Restore-Target -Target $t -DryRun:$script:DryRun) }
    Write-EngineResults $results
    return $results
}

function Invoke-ApplyPending {
    $pending = @(Get-PendingCards)
    if ($pending.Count -eq 0) { Show-Info 'No pending changes. Flip a switch first, then click Apply Changes.'; return }

    $toBlock = @($pending | Where-Object { $_.Pending -eq 'Disable' -and -not $_.Target.Advanced })
    $toRestore = @($pending | Where-Object { $_.Pending -eq 'Restore' })
    $advanced = @($pending | Where-Object { $_.Pending -eq 'Disable' -and $_.Target.Advanced })
    $text = "Apply $($pending.Count) change$(if ($pending.Count -ne 1) { 's' })?`n"
    if ($toBlock.Count)   { $text += "`nBlock:`n"   + (($toBlock   | ForEach-Object { ' - ' + $_.Target.DisplayName }) -join "`n") + "`n" }
    if ($toRestore.Count) { $text += "`nRestore to original:`n" + (($toRestore | ForEach-Object { ' - ' + $_.Target.DisplayName }) -join "`n") + "`n" }
    if ($advanced.Count)  { $text += "`nADVANCED - has side effects, read the card descriptions:`n" + (($advanced | ForEach-Object { ' - ' + $_.Target.DisplayName }) -join "`n") + "`n" }
    $text += "`nEach card will re-check live system state afterwards. Everything is reversible with Undo Last Action / Restore All Original."
    if ($script:DryRun) { $text += "`n`nDRY RUN is on: this will only log what would happen." }
    if (-not (Confirm-Action $text)) { return }

    Write-Log -Category 'Apply' -Message "Applying $($pending.Count) change(s)" -Result 'Info' -Detail $(if ($script:DryRun) { 'dry run' } else { '' })
    $batch = New-Object System.Collections.Generic.List[object]
    $ok = 0; $failed = 0
    foreach ($c in $pending) {
        $action = $c.Pending
        $results = @(Invoke-ChangeTarget -Id $c.Target.Id -Action $action)
        $succeeded = @($results | Where-Object { $_.Result -eq 'OK' }).Count -gt 0
        $anyFailed = @($results | Where-Object { $_.Result -eq 'Failed' }).Count -gt 0 -or $results.Count -eq 0
        if ($succeeded) { $ok++; $batch.Add(@{ Id = $c.Target.Id; Action = $action; Name = $c.Target.DisplayName }) }
        elseif ($anyFailed) { $failed++ }
        # Dry run keeps the selection so it can be applied for real after switching dry run off.
        if (-not $script:DryRun) { $c.Pending = $null }
    }
    if ($batch.Count -gt 0) { Push-UndoAction -Entry @{ Items = $batch.ToArray(); Label = "$($batch.Count) change(s)" } }

    Update-AllCards
    $summary = "Applied $ok change(s), $failed failed"
    if ($script:DryRun) { $summary = "Dry run finished for $($pending.Count) change(s) - nothing was changed" }
    Write-Log -Category 'Apply' -Message $summary -Result $(if ($failed -gt 0) { 'Warn' } elseif ($script:DryRun) { 'DryRun' } else { 'OK' })
    Set-Status $summary
}

function Invoke-SelectRecommended {
    $todo = @($script:Cards.Values | Where-Object { $_.Target.Recommended -and $_.State -eq 'Enabled' -and -not $_.Pending })
    if ($todo.Count -eq 0) {
        Show-Info 'All recommended protections are already blocked, already selected, or not applicable on this driver.'
        return
    }
    foreach ($c in $todo) { $c.Pending = 'Disable'; Update-Card -Id $c.Target.Id }
    Write-Log -Category 'Select' -Message "Selected $($todo.Count) recommended item(s) - click Apply Changes to block them" -Result 'Info'
    Update-Summary
}

function Invoke-UndoLast {
    $entry = Pop-UndoAction
    if (-not $entry) { Update-Summary; return }
    $items = @($entry.Items)
    Write-Log -Category 'Undo' -Message "Undoing last batch ($($entry.Label))" -Result 'Info'
    [array]::Reverse($items)
    foreach ($item in $items) {
        $c = $script:Cards[$item.Id]
        if ($c) { $c.Pending = $null }
        $inverse = if ($item.Action -eq 'Disable') { 'Restore' } else { 'Disable' }
        Invoke-ChangeTarget -Id $item.Id -Action $inverse | Out-Null
    }
    Update-AllCards
    Set-Status "Undid $($items.Count) change(s)"
}

function Invoke-RestoreAll {
    $items = Get-AllOriginalStates
    if (-not $items -or $items.Count -eq 0) {
        Show-Info 'Nothing to restore - NvTeleGuard has not changed anything on this system.'
        return
    }
    if (-not (Confirm-Action "Restore all $($items.Count) item(s) NvTeleGuard has changed back to their original settings?")) { return }
    Write-Log -Category 'Restore' -Message "Restore All Original requested for $($items.Count) item(s)" -Result 'Info'
    foreach ($id in @($items.Keys)) {
        if ($script:Cards.ContainsKey($id)) {
            $script:Cards[$id].Pending = $null
            Invoke-ChangeTarget -Id $id -Action 'Restore' | Out-Null
        } else {
            Write-Log -Category 'Restore' -Message "Snapshot entry '$id' no longer matches anything on this system" -Result 'Skipped' -Detail 'Left in snapshot.json for reference'
        }
    }
    Update-AllCards
    Set-Status 'Restore All Original finished'
}

function Invoke-StatusTest {
    Set-Status 'Running telemetry status test...'
    Update-Ui
    Write-Log -Category 'Status' -Message '----- Telemetry status test -----' -Result 'Info'
    $lines = @(Get-TelemetryStatusReport -Targets $script:Targets -AppVersion $script:AppVersion -IsElevated $script:IsAdmin)
    foreach ($l in $lines) { Write-Log -Category 'Status' -Message $l.Message -Result $l.Level }
    Update-AllCards
    Set-Status "Status test complete - $($lines.Count) finding(s) logged"
}

function Invoke-CheckUpdates {
    Set-Status 'Checking for updates...'
    Update-Ui
    $r = Test-ForUpdates -CurrentVersion $script:AppVersion
    $script:UpdateUrl = $r.Url
    $UI.UpdateBannerText.Text = $r.Message
    switch ($r.Status) {
        'UpToDate' {
            $UI.UpdateBanner.Background = Get-Brush 'AccentSoftBrush'; $UI.UpdateBanner.BorderBrush = Get-Brush 'AccentBrush'
            $UI.BtnUpdateLink.Visibility = [Windows.Visibility]::Collapsed
            $level = 'OK'
        }
        'UpdateAvailable' {
            $UI.UpdateBanner.Background = Get-Brush 'AmberSoftBrush'; $UI.UpdateBanner.BorderBrush = Get-Brush 'AmberBrush'
            $UI.BtnUpdateLink.Visibility = [Windows.Visibility]::Visible
            $level = 'Warn'
        }
        default {
            $UI.UpdateBanner.Background = Get-Brush 'PanelBrush'; $UI.UpdateBanner.BorderBrush = Get-Brush 'RedBrush'
            $UI.BtnUpdateLink.Visibility = [Windows.Visibility]::Collapsed
            $level = 'Failed'
        }
    }
    $UI.UpdateBanner.Visibility = [Windows.Visibility]::Visible
    Write-Log -Category 'Update' -Message $r.Message -Result $level
    Set-Status 'Ready'
}

function Invoke-Refresh {
    $pendingCount = @(Get-PendingCards).Count
    Set-Status 'Rescanning...'
    Update-Ui
    Build-Sections
    Write-Log -Category 'Scan' -Message "Rescanned $($script:Targets.Count) target(s)" -Result 'Info' -Detail $(if ($pendingCount -gt 0) { "$pendingCount pending selection(s) discarded" } else { '' })
    Set-Status 'Ready'
}

function Save-Screenshot {
    param([string]$Path)
    $root = $W.Content
    $root.Background = $W.Background
    Update-Ui
    $width = [int][Math]::Ceiling($root.ActualWidth)
    $height = [int][Math]::Ceiling($root.ActualHeight)
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $stream = [System.IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# Wire up
# ------------------------------------------------------------------------------------------------
$UI.VersionText.Text = "v$($script:AppVersion)"
if ($script:IsAdmin) {
    $UI.AdminPillText.Text = 'Administrator'
    $UI.AdminPill.Background = Get-Brush 'AccentBrush'
} else {
    $UI.AdminPillText.Text = 'Not elevated - read-only'
    $UI.AdminPill.Background = Get-Brush 'AmberBrush'
}
$UI.DryRunSwitch.IsChecked = $script:DryRun

$UI.BtnCheckUpdates.Add_Click({ Invoke-UiAction { Invoke-CheckUpdates } })
$UI.BtnUpdateClose.Add_Click({ Invoke-UiAction { $UI.UpdateBanner.Visibility = [Windows.Visibility]::Collapsed } })
$UI.BtnUpdateLink.Add_Click({ Invoke-UiAction { if ($script:UpdateUrl) { Start-Process $script:UpdateUrl } } })
$UI.BtnTestStatus.Add_Click({ Invoke-UiAction { Invoke-StatusTest } })
$UI.BtnRefresh.Add_Click({ Invoke-UiAction { Invoke-Refresh } })
$UI.BtnSelectRecommended.Add_Click({ Invoke-UiAction { Invoke-SelectRecommended } })
$UI.BtnApply.Add_Click({ Invoke-UiAction { Invoke-ApplyPending } })
$UI.BtnRestoreAll.Add_Click({ Invoke-UiAction { Invoke-RestoreAll } })
$UI.BtnUndo.Add_Click({ Invoke-UiAction { Invoke-UndoLast } })
$UI.BtnOpenLog.Add_Click({ Invoke-UiAction { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f (Get-ActionLogPath)) } })
$UI.BtnClearLog.Add_Click({ Invoke-UiAction { $UI.LogList.Items.Clear() } })
$UI.DryRunSwitch.Add_Click({ Invoke-UiAction {
    $script:DryRun = [bool]$UI.DryRunSwitch.IsChecked
    Write-Log -Category 'Mode' -Message $(if ($script:DryRun) { 'Dry run ON - Apply Changes will only log what would happen' } else { 'Dry run OFF - Apply Changes will change the system' }) -Result 'Info'
    Update-Summary
} })

$W.Add_ContentRendered({
    Invoke-UiAction {
        if ($script:ScreenshotPath) {
            Invoke-StatusTest
            Invoke-CheckUpdates
            if ($ScreenshotScene -eq 'advanced') {
                $script:AdvancedAcknowledged = $true
                Switch-AdvancedSection
                $UI.DryRunSwitch.IsChecked = $true
                $script:DryRun = $true
                Write-Log -Category 'Mode' -Message 'Dry run ON - Apply Changes will only log what would happen' -Result 'Info'
                # Show a pending change on the first advanced card that can take one (opposite of its live state).
                foreach ($id in 'hosts:telemetry', 'service:NvContainerLocalSystem', 'ifeo:NvTelemetryContainer.exe') {
                    $c = $script:Cards[$id]
                    if ($c -and $c.State -ne 'NotPresent') { Invoke-SwitchToggle -Id $id -Checked ($c.State -ne 'Disabled'); break }
                }
                Update-Summary
                # Taller window so the whole Advanced section fits, scrolled so its header is at the top.
                $W.Height = 960
                Update-Ui
                $UI.SectionsPanel.UpdateLayout()
                $scroller = $UI.SectionsPanel.Parent
                if ($scroller -is [Windows.Controls.ScrollViewer] -and $script:AdvancedHeader) {
                    $offset = $script:AdvancedHeader.TranslatePoint((New-Object Windows.Point(0, 0)), $UI.SectionsPanel).Y
                    $scroller.ScrollToVerticalOffset([Math]::Max(0, $offset - 8))
                }
            }
            Update-Ui
            Update-Ui
            Save-Screenshot -Path $script:ScreenshotPath
            $W.Close()
        }
    }
})

if (-not $ShowConsole) {
    try {
        Add-Type -Namespace NvTeleGuardNative -Name ConsoleWin -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $hwnd = [NvTeleGuardNative.ConsoleWin]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { [void][NvTeleGuardNative.ConsoleWin]::ShowWindow($hwnd, 0) }
    } catch { }
}

Set-Status "Scanning NVIDIA telemetry targets...   snapshot: $(Get-SnapshotPath)   log: $(Get-ActionLogPath)"
Build-Sections
Write-Log -Category 'Start' -Message "NvTeleGuard $($script:AppVersion) started - $($script:Targets.Count) target(s) scanned" -Result 'Info' -Detail $(if ($script:IsAdmin) { 'administrator' } else { 'not elevated' })
if ($script:ElevationDeclined) {
    Write-Log -Category 'Start' -Message 'Elevation was declined - running read-only. Restart NvTeleGuard and accept the UAC prompt to make changes.' -Result 'Warn'
}
if ($script:DryRun) { Write-Log -Category 'Mode' -Message 'Dry run ON - Apply Changes will only log what would happen' -Result 'Info' }
Set-Status "Ready   |   snapshot: $(Get-SnapshotPath)   |   log: $(Get-ActionLogPath)"

[void]$W.ShowDialog()
