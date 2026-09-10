$script:LogPath = $null
$script:UndoStack = New-Object System.Collections.Generic.Stack[object]

function Initialize-ActionLog {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$AppVersion = '0.0.0'
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $script:LogPath = Join-Path $Directory 'actions.log'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $script:LogPath -Value "==== NvTeleGuard $AppVersion session started $stamp ====" -Encoding UTF8
    return $script:LogPath
}

function Get-ActionLogPath { return $script:LogPath }

function Write-ActionEntry {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('OK', 'Failed', 'Skipped', 'DryRun', 'Info', 'Warn')][string]$Result = 'Info',
        [string]$Detail = ''
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "{0}  [{1}]  {2}  [{3}]" -f $ts, $Category, $Message, $Result
    if ($Detail) { $line += "  - $Detail" }
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
    return [PSCustomObject]@{
        Timestamp = $ts
        Category  = $Category
        Message   = $Message
        Result    = $Result
        Detail    = $Detail
        Line      = $line
    }
}

function Push-UndoAction {
    param([Parameter(Mandatory)][hashtable]$Entry)
    $Entry['pushedAt'] = Get-Date
    $script:UndoStack.Push($Entry)
}

function Pop-UndoAction {
    if ($script:UndoStack.Count -gt 0) { return $script:UndoStack.Pop() }
    return $null
}

function Get-UndoCount { return $script:UndoStack.Count }

function Get-UndoTop {
    if ($script:UndoStack.Count -gt 0) { return $script:UndoStack.Peek() }
    return $null
}

Export-ModuleMember -Function Initialize-ActionLog, Get-ActionLogPath, Write-ActionEntry, Push-UndoAction, Pop-UndoAction, Get-UndoCount, Get-UndoTop
