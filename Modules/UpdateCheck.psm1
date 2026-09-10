# Update check against GitHub Releases. Set RepoOwner/RepoName once the repository exists;
# until then (or if the owner is still the placeholder) a mock "latest" version is returned so
# the UI path can be exercised offline.

$script:RepoOwner = 'derpfinger'
$script:RepoName  = 'NvTeleGuard'

function Get-ReleasesPageUrl {
    return "https://github.com/$($script:RepoOwner)/$($script:RepoName)/releases/latest"
}

function Get-LatestReleaseInfo {
    if ($script:RepoOwner -like '<*') {
        return [PSCustomObject]@{ Version = '1.0.0'; Url = (Get-ReleasesPageUrl); Source = 'placeholder'; NoReleases = $false }
    }

    # Windows PowerShell 5.1 defaults to TLS 1.0/1.1, which GitHub rejects.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $uri = "https://api.github.com/repos/$($script:RepoOwner)/$($script:RepoName)/releases/latest"
    try {
        $r = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'NvTeleGuard'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 15 -ErrorAction Stop
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) {
            return [PSCustomObject]@{ Version = $null; Url = (Get-ReleasesPageUrl); Source = 'github'; NoReleases = $true }
        }
        throw
    }
    return [PSCustomObject]@{
        Version    = ([string]$r.tag_name -replace '^[vV]', '')
        Url        = [string]$r.html_url
        Source     = 'github'
        NoReleases = $false
    }
}

function ConvertTo-VersionSafe {
    param([string]$Text)
    $clean = ($Text -replace '^[vV]', '').Trim()
    if ($clean -notmatch '\.') { $clean = "$clean.0" }
    try { return [version]$clean } catch { return $null }
}

function Test-ForUpdates {
    param([Parameter(Mandatory)][string]$CurrentVersion)
    try {
        $latest = Get-LatestReleaseInfo
    } catch {
        return [PSCustomObject]@{
            CurrentVersion = $CurrentVersion; LatestVersion = $null; IsUpToDate = $null
            Url = (Get-ReleasesPageUrl); Status = 'Error'
            Message = "Could not reach GitHub to check for updates: $($_.Exception.Message)"
        }
    }

    if ($latest.NoReleases) {
        return [PSCustomObject]@{
            CurrentVersion = $CurrentVersion; LatestVersion = $null; IsUpToDate = $true
            Url = $latest.Url; Status = 'UpToDate'
            Message = "No releases have been published on GitHub yet - you're on $CurrentVersion."
        }
    }

    $cur = ConvertTo-VersionSafe $CurrentVersion
    $new = ConvertTo-VersionSafe $latest.Version
    if ($null -eq $cur -or $null -eq $new) {
        return [PSCustomObject]@{
            CurrentVersion = $CurrentVersion; LatestVersion = $latest.Version; IsUpToDate = $null
            Url = $latest.Url; Status = 'Error'
            Message = "Could not compare versions ('$CurrentVersion' vs '$($latest.Version)')."
        }
    }

    if ($new -gt $cur) {
        $msg = "Update available: $CurrentVersion -> $($latest.Version)"
        $status = 'UpdateAvailable'; $upToDate = $false
    } else {
        $msg = "You're already on the latest version ($CurrentVersion)."
        $status = 'UpToDate'; $upToDate = $true
    }
    if ($latest.Source -eq 'placeholder') { $msg += '  [placeholder update source - GitHub integration pending]' }

    return [PSCustomObject]@{
        CurrentVersion = $CurrentVersion; LatestVersion = $latest.Version; IsUpToDate = $upToDate
        Url = $latest.Url; Status = $status; Message = $msg
    }
}

Export-ModuleMember -Function Get-LatestReleaseInfo, Test-ForUpdates
