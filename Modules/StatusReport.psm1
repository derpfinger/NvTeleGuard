# "Test Telemetry Status": a read-only diagnostic pass. Produces log lines describing what NVIDIA
# telemetry machinery is installed, whether it is currently wired up, and what NvTeleGuard has blocked.
# Makes no changes and no network calls.

function New-StatusLine {
    param([ValidateSet('OK', 'Warn', 'Info', 'Failed')][string]$Level, [string]$Message)
    return [PSCustomObject]@{ Level = $Level; Message = $Message }
}

function Get-InstalledNvidiaProduct {
    param([string]$NameLike)
    $paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    return Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $NameLike } | Select-Object -First 1
}

function Get-ConsentFileSummary {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        $device = @()
        if ($json.GDPRDevice) { foreach ($prop in $json.GDPRDevice.PSObject.Properties) { $device += "client $($prop.Name)=$($prop.Value)" } }
        $user = @()
        if ($json.GDPRUser) { foreach ($prop in $json.GDPRUser.PSObject.Properties) { $user += "user $($prop.Name)=$($prop.Value)" } }
        $consented = @($json.GDPRDevice.PSObject.Properties | Where-Object { [int]$_.Value -ne 0 }).Count
        return [PSCustomObject]@{ Device = $device; User = $user; ConsentedCount = $consented; Total = @($json.GDPRDevice.PSObject.Properties).Count }
    } catch {
        return [PSCustomObject]@{ Device = @("unreadable: $($_.Exception.Message)"); User = @(); ConsentedCount = -1; Total = 0 }
    }
}

function Get-TelemetryStatusReport {
    param(
        [Parameter(Mandatory)]$Targets,
        [string]$AppVersion = '0.0.0',
        [bool]$IsElevated = $false
    )
    $lines = New-Object System.Collections.Generic.List[object]
    $lines.Add((New-StatusLine 'Info' ("Status test started - NvTeleGuard $AppVersion, " + $(if ($IsElevated) { 'running as administrator' } else { 'NOT elevated (some checks limited)' }))))

    # --- Environment ---------------------------------------------------------------------------
    try {
        $gpu = Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -like '*NVIDIA*' } | Select-Object -First 1
        if ($gpu) { $lines.Add((New-StatusLine 'Info' "GPU: $($gpu.Name), driver $($gpu.DriverVersion)")) }
        else { $lines.Add((New-StatusLine 'Warn' 'No NVIDIA GPU reported by Windows - is the NVIDIA driver installed?')) }
    } catch { $lines.Add((New-StatusLine 'Info' "Could not query GPU info: $($_.Exception.Message)")) }

    $nvApp = Get-InstalledNvidiaProduct 'NVIDIA App*'
    $gfe   = Get-InstalledNvidiaProduct 'NVIDIA GeForce Experience*'
    $tc    = Get-InstalledNvidiaProduct 'NVIDIA Telemetry Client*'
    if ($nvApp) { $lines.Add((New-StatusLine 'Info' "NVIDIA App installed: v$($nvApp.DisplayVersion)")) }
    if ($gfe)   { $lines.Add((New-StatusLine 'Info' "GeForce Experience installed: v$($gfe.DisplayVersion) (legacy)")) }
    if (-not $nvApp -and -not $gfe) { $lines.Add((New-StatusLine 'Info' 'Neither NVIDIA App nor GeForce Experience is installed')) }
    if ($tc) { $lines.Add((New-StatusLine 'Info' "NVIDIA Telemetry Client component installed: v$($tc.DisplayVersion)")) }
    else { $lines.Add((New-StatusLine 'OK' 'NVIDIA Telemetry Client component is not installed')) }

    # --- Per-target live state -----------------------------------------------------------------
    $active = 0; $blocked = 0; $absent = 0
    foreach ($t in $Targets) {
        $s = Get-TargetState -Target $t
        switch ($s.State) {
            'Enabled'    { $active++;  $lines.Add((New-StatusLine 'Warn' "ACTIVE   $($t.DisplayName) - $($s.Detail)")) }
            'Disabled'   { $blocked++; $lines.Add((New-StatusLine 'OK'   "BLOCKED  $($t.DisplayName) - $($s.Detail)")) }
            default      { $absent++;  $lines.Add((New-StatusLine 'Info' "n/a      $($t.DisplayName) - $($s.Detail)")) }
        }
    }

    # --- Is the telemetry DLL actually loaded right now? -----------------------------------------
    try {
        $hits = @()
        foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                foreach ($m in $proc.Modules) {
                    if ($m.ModuleName -match '^NvTelemetry(64|32|API64|API32)?\.dll$') { $hits += "$($proc.ProcessName) (PID $($proc.Id): $($m.ModuleName))"; break }
                }
            } catch { }
        }
        $hits = $hits | Sort-Object -Unique
        if ($hits.Count -gt 0) { $lines.Add((New-StatusLine 'Warn' ("Telemetry DLL currently loaded in: " + ($hits -join '; ')))) }
        elseif ($IsElevated) { $lines.Add((New-StatusLine 'OK' 'NvTelemetry DLL is not loaded in any running process')) }
        else { $lines.Add((New-StatusLine 'Info' 'NvTelemetry DLL not seen in processes visible to this user (run as administrator to inspect services)')) }
    } catch { $lines.Add((New-StatusLine 'Info' "Process inspection failed: $($_.Exception.Message)")) }

    # --- Container services --------------------------------------------------------------------
    foreach ($svcName in 'NvContainerLocalSystem', 'NVDisplay.ContainerLocalSystem') {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        $note = if ($svcName -eq 'NVDisplay.ContainerLocalSystem') { ' - display driver container; hosts DisplayDriverRAS and GameSessionTelemetry plugins (informational, not controlled by NvTeleGuard)' } else { ' - hosts the NvTelemetry plugin when the junction is present' }
        $lines.Add((New-StatusLine 'Info' "Service $svcName is $($svc.Status) (startup $($svc.StartType))$note"))
    }

    # --- Consent / queue files written by the telemetry client -----------------------------------
    $stores = @(
        @{ Label = 'Display driver RAS telemetry'; Dir = (Join-Path $env:ProgramData 'NVIDIA Corporation\DisplayDriverRAS\NvTelemetry') },
        @{ Label = 'NVIDIA App telemetry client';  Dir = (Join-Path $env:ProgramData 'NVIDIA Corporation\NvTelemetry') }
    )
    foreach ($store in $stores) {
        $ini = Join-Path $store.Dir 'telemetry_switch.ini'
        $dat = Join-Path $store.Dir 'events.dat'
        $summary = Get-ConsentFileSummary $ini
        if ($summary) {
            if ($summary.ConsentedCount -gt 0) { $lines.Add((New-StatusLine 'Warn' "$($store.Label): consent file says $($summary.ConsentedCount) of $($summary.Total) client IDs opted in ($($summary.Device -join ', '))")) }
            elseif ($summary.ConsentedCount -eq 0) { $lines.Add((New-StatusLine 'OK' "$($store.Label): consent file shows no opted-in client IDs")) }
            else { $lines.Add((New-StatusLine 'Info' "$($store.Label): $($summary.Device -join ', ')")) }
        } else {
            $lines.Add((New-StatusLine 'Info' "$($store.Label): no telemetry_switch.ini present ($($store.Dir))"))
        }
        try {
            $f = Get-Item -LiteralPath $dat -ErrorAction Stop
            $lines.Add((New-StatusLine 'Info' ("$($store.Label): events.dat queue is {0:N0} KB, last written {1}" -f ($f.Length / 1KB), $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))))
        } catch [System.UnauthorizedAccessException] {
            $lines.Add((New-StatusLine 'Info' "$($store.Label): events.dat exists but is not readable without administrator rights"))
        } catch { }
    }

    # --- Hosts file ------------------------------------------------------------------------------
    $hostsPath = Get-HostsFilePath
    $hostsText = ''
    if (Test-Path -LiteralPath $hostsPath) { $hostsText = [System.IO.File]::ReadAllText($hostsPath) }
    $blockedHosts = @(); $openHosts = @()
    foreach ($h in (Get-TelemetryHostList)) {
        if ($hostsText -match ('(?m)^\s*(0\.0\.0\.0|127\.0\.0\.1)\s+' + [regex]::Escape($h) + '\s*$')) { $blockedHosts += $h } else { $openHosts += $h }
    }
    if ($blockedHosts.Count -gt 0) { $lines.Add((New-StatusLine 'OK' ("Hosts file blocks: " + ($blockedHosts -join ', ')))) }
    if ($openHosts.Count -gt 0)    { $lines.Add((New-StatusLine 'Info' ("Endpoints not blocked in hosts file: " + ($openHosts -join ', ')))) }

    # --- Summary ---------------------------------------------------------------------------------
    $verdictLevel = if ($active -eq 0) { 'OK' } else { 'Warn' }
    $lines.Add((New-StatusLine $verdictLevel "Summary: $blocked blocked, $active still active, $absent not applicable on this driver"))
    return $lines.ToArray()
}

Export-ModuleMember -Function Get-TelemetryStatusReport
