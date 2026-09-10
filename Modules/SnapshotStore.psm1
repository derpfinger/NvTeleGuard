$script:SnapshotPath = $null
$script:AppVersion = '0.0.0'

function Initialize-SnapshotStore {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$AppVersion = '0.0.0'
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $script:SnapshotPath = Join-Path $Directory 'snapshot.json'
    $script:AppVersion = $AppVersion
    return $script:SnapshotPath
}

function Get-SnapshotPath { return $script:SnapshotPath }

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = ConvertTo-Hashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $arr = @()
        foreach ($item in $InputObject) { $arr += ,(ConvertTo-Hashtable $item) }
        return ,$arr
    }
    return $InputObject
}

function New-EmptySnapshot {
    return @{
        createdUtc = [DateTime]::UtcNow.ToString('o')
        appVersion = $script:AppVersion
        items      = @{}
    }
}

function Read-Snapshot {
    if ($script:SnapshotPath -and (Test-Path -LiteralPath $script:SnapshotPath)) {
        try {
            $raw = Get-Content -LiteralPath $script:SnapshotPath -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $snap = ConvertTo-Hashtable ($raw | ConvertFrom-Json)
                if (-not $snap.ContainsKey('items') -or $null -eq $snap['items']) { $snap['items'] = @{} }
                return $snap
            }
        } catch {
            Write-Warning "Snapshot file is unreadable and will be recreated: $($_.Exception.Message)"
        }
    }
    return New-EmptySnapshot
}

function Write-Snapshot {
    param([hashtable]$Snapshot)
    $json = $Snapshot | ConvertTo-Json -Depth 12
    Set-Content -LiteralPath $script:SnapshotPath -Value $json -Encoding UTF8
}

function Get-OriginalState {
    param([Parameter(Mandatory)][string]$Id)
    $snap = Read-Snapshot
    if ($snap.items.ContainsKey($Id)) { return $snap.items[$Id] }
    return $null
}

function Save-OriginalState {
    # Writes only on first touch: a later call for the same Id never overwrites the true original.
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Original
    )
    $snap = Read-Snapshot
    if ($snap.items.ContainsKey($Id)) { return $false }
    $Original['capturedUtc'] = [DateTime]::UtcNow.ToString('o')
    $snap.items[$Id] = $Original
    Write-Snapshot $snap
    return $true
}

function Remove-OriginalState {
    param([Parameter(Mandatory)][string]$Id)
    $snap = Read-Snapshot
    if ($snap.items.ContainsKey($Id)) {
        $snap.items.Remove($Id)
        Write-Snapshot $snap
        return $true
    }
    return $false
}

function Get-AllOriginalStates {
    return (Read-Snapshot).items
}

Export-ModuleMember -Function Initialize-SnapshotStore, Get-SnapshotPath, Get-OriginalState, Save-OriginalState, Remove-OriginalState, Get-AllOriginalStates, ConvertTo-Hashtable
