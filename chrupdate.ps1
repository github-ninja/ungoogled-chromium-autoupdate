#Requires -Version 5.1
<#
.SYNOPSIS
    Ungoogled Chromium Portable - Installation and Update Manager.

.DESCRIPTION
    Automates the installation, update, and portabilization of Ungoogled Chromium
    via a junction point in %LOCALAPPDATA%\Chromium\User Data.

    Updated Version (2.1):
      - Atomic profile migration.
      - SHA256 / Authenticode verification of the downloaded build.
      - Robocopy with correct parsing and multithreading.
      - File mutex protection against parallel execution.
      - Enhanced process termination with WaitForExit.
      - Logging to a file in parallel with the console.
      - Native New-Item -ItemType Junction.

.PARAMETER SkipUpdate
    Skip checking for updates on GitHub.

.PARAMETER SkipCacheClean
    Do not clear the browser cache before operations.

.PARAMETER Force
    Ignore version check and reinstall.

.PARAMETER DryRun
    Do not perform destructive operations, only show the plan.

.PARAMETER GitHubToken
    Optional PAT to increase GitHub API rate limit.

.NOTES
    Version : 2.1
    Requires: PowerShell 5.1+, Windows 10 1607+ (for reliable junctions).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipUpdate,
    [switch]$SkipCacheClean,
    [switch]$Force,
    [switch]$DryRun,
    [string]$GitHubToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = [pscustomobject]@{
    AppDir            = $PSScriptRoot
    ChromeExe         = [IO.Path]::Combine($PSScriptRoot, 'chrome.exe')
    SysChromiumDir    = [IO.Path]::Combine($env:LOCALAPPDATA, 'Chromium')
    SysUserData       = [IO.Path]::Combine($env:LOCALAPPDATA, 'Chromium', 'User Data')
    PortableUserData  = [IO.Path]::Combine($PSScriptRoot, 'User Data')
    GitHubApiUrl      = 'https://api.github.com/repos/ungoogled-software/ungoogled-chromium-windows/releases/latest'
    GitHubReleasesUrl = 'https://github.com/ungoogled-software/ungoogled-chromium-windows/releases/latest'
    HttpTimeoutSec    = 30
    DownloadTimeoutSec = 600
    ProcessKillWaitMs = 10000
    TempUpdateDir     = [IO.Path]::Combine($PSScriptRoot, '.tmp_update')
    TempBackupDir     = [IO.Path]::Combine($PSScriptRoot, '.tmp_backup')
    UpdateZip         = [IO.Path]::Combine($PSScriptRoot, '.update.zip')
    LogFile           = [IO.Path]::Combine($PSScriptRoot, 'chrupdate.log')
    MutexName         = 'Global\UngoogledChromiumUpdater_v2_1'
    # Files and directories in the distribution root that should NOT be overwritten by an update
    # (contain user settings specific to the portable installation)
    ProtectedFiles    = @(
        'initial_preferences'
        'master_preferences'
        'First Run'
        'First Run Dev'
        'chromium.config'
    )
    CacheFolders      = @(
        'Cache', 'Code Cache', 'Media Cache', 'GPUCache', 'ShaderCache'
        'GrShaderCache', 'Blob Storage', 'DawnCache', 'GraphiteDawnCache'
    )
    # All Chromium family process names that may hold a lock on files
    ChromiumProcessNames = @(
        'chrome', 'chromium', 'chrome_proxy', 'crashpad_handler'
        'nacl64', 'nacl_helper'
    )
    # Minimum allowed version components (Major.Minor.Build.Revision)
    UserAgent         = 'UngoogledChromiumUpdater/2.1 (PowerShell)'
}

# Mutex to prevent parallel executions
$Script:Mutex = $null
$Script:MutexAcquired = $false

# ============================================================================
# LOGGING
# ============================================================================

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Info',

        [switch]$NoConsole
    )

    $timestamp = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$timestamp] [$Level] $Message"

    # Always to file
    try {
        Add-Content -LiteralPath $Script:Config.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # If log file is unavailable (read-only media, etc.) -- continue without it
    }

    if ($NoConsole) { return }

    $colors = @{
        Info    = 'Cyan'
        Success = 'Green'
        Warning = 'Yellow'
        Error   = 'Red'
        Debug   = 'DarkGray'
    }

    Write-Host $Message -ForegroundColor $colors[$Level]
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Test-IsElevated {
    [OutputType([bool])]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Acquire-SingleInstanceMutex {
    [OutputType([bool])]
    param()

    try {
        # Local (not Global) mutex -- for current user
        $name = $Script:Config.MutexName -replace '^Global\\', 'Local\'
        $createdNew = $false
        $Script:Mutex = [System.Threading.Mutex]::new($true, $name, [ref]$createdNew)

        if (-not $createdNew) {
            $acquired = $Script:Mutex.WaitOne(0)
            if (-not $acquired) {
                return $false
            }
        }

        $Script:MutexAcquired = $true
        return $true
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous owner crashed -- now the mutex is ours
        $Script:MutexAcquired = $true
        return $true
    }
    catch {
        Write-Log "Failed to create mutex: $($_.Exception.Message)" -Level Warning
        return $true  # Do not block execution due to mutex API issues
    }
}

function Release-SingleInstanceMutex {
    if ($null -ne $Script:Mutex) {
        try {
            if ($Script:MutexAcquired) {
                $Script:Mutex.ReleaseMutex()
            }
        }
        catch { }
        finally {
            $Script:Mutex.Dispose()
            $Script:Mutex = $null
        }
    }
}

function Get-ChromiumVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [version]'0.0.0.0'
    }

    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ([string]::IsNullOrWhiteSpace($info.FileVersion)) {
            return [version]'0.0.0.0'
        }
        # FileVersion may contain spaces or comments: '120.0.6099.224 (a1b2c3)'
        $clean = ($info.FileVersion -split '[\s\(]', 2)[0]
        return [version]$clean
    }
    catch {
        Write-Log "Failed to determine version of '$Path': $($_.Exception.Message)" -Level Debug
        return [version]'0.0.0.0'
    }
}

function ConvertTo-NormalizedVersion {
    <#
    .SYNOPSIS
        Parses a tag like '120.0.6099.224-1.1' into [version] '120.0.6099.224'.
    #>
    [OutputType([version])]
    param([Parameter(Mandatory)][string]$Tag)

    # Take the first group of 4 numeric components
    if ($Tag -match '(\d+)\.(\d+)\.(\d+)\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
    }
    if ($Tag -match '(\d+)\.(\d+)\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    }
    throw "Failed to parse version from tag: '$Tag'"
}

function Stop-ChromiumProcesses {
    [CmdletBinding()]
    param(
        [int]$WaitTimeoutMs = $Script:Config.ProcessKillWaitMs
    )

    Write-Log "`n--- Terminating Chromium Processes ---" -Level Warning

    $allProcs = @()
    foreach ($name in $Script:Config.ChromiumProcessNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) { $allProcs += $procs }
    }

    # Filter only processes from our directory (important: do not kill another Chrome)
    $appDirNorm = (Resolve-Path -LiteralPath $Script:Config.AppDir).Path.TrimEnd('\').ToLowerInvariant()
    $relevant = foreach ($p in $allProcs) {
        try {
            $procPath = $p.MainModule.FileName
            if ($procPath -and $procPath.ToLowerInvariant().StartsWith($appDirNorm)) {
                $p
            }
            elseif (-not $procPath) {
                # If path cannot be read (Access Denied) -- include just in case,
                # but only for specific Chromium processes, not for general 'chrome'
                if ($p.ProcessName -in 'chromium', 'chrome_proxy', 'crashpad_handler') {
                    $p
                }
            }
        }
        catch {
            # Access Denied on MainModule -- skip
            Write-Log "Failed to check process path PID=$($p.Id): $($_.Exception.Message)" -Level Debug
        }
    }

    if (-not $relevant) {
        Write-Log "Chromium processes are not running." -Level Info
        return
    }

    Write-Log "Found processes: $($relevant.Count). Terminating..." -Level Info

    foreach ($p in $relevant) {
        try {
            if ($DryRun) {
                Write-Log "[DryRun] Stop-Process $($p.ProcessName) (PID=$($p.Id))" -Level Debug
                continue
            }
            $p.Kill()
        }
        catch {
            Write-Log "Failed to terminate $($p.ProcessName) PID=$($p.Id): $($_.Exception.Message)" -Level Warning
        }
    }

    if ($DryRun) { return }

    # Wait for actual exit
    $deadline = [DateTime]::Now.AddMilliseconds($WaitTimeoutMs)
    foreach ($p in $relevant) {
        $remaining = [int]([Math]::Max(0, ($deadline - [DateTime]::Now).TotalMilliseconds))
        try {
            if (-not $p.HasExited) {
                [void]$p.WaitForExit($remaining)
            }
        }
        catch { }
    }

    # Final check
    Start-Sleep -Milliseconds 250
    $stillAlive = foreach ($name in $Script:Config.ChromiumProcessNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.MainModule.FileName.ToLowerInvariant().StartsWith($appDirNorm) }
                catch { $false }
            }
    }

    if ($stillAlive) {
        throw "Failed to terminate Chromium processes: $($stillAlive.ProcessName -join ', '). Close the browser manually and retry."
    }
}

function Test-ReparsePoint {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        $attrs = [IO.File]::GetAttributes($Path)
        return ($attrs -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
    }
    catch {
        return $false
    }
}

function Get-JunctionTarget {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $target = $item.Target
        if ($null -eq $target) { return $null }
        if ($target -is [array]) {
            if ($target.Count -eq 0) { return $null }
            $target = $target[0]
        }
        return $target.TrimEnd('\')
    }
    catch {
        return $null
    }
}

function New-DirectoryJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    if ($DryRun) {
        Write-Log "[DryRun] Create junction: $Path -> $Target" -Level Debug
        return
    }

    # Native API without cmd.exe
    try {
        $null = New-Item -ItemType Junction -Path $Path -Value $Target -Force -ErrorAction Stop
    }
    catch {
        # Fallback to mklink -- some systems (Win10 LTSC) have restrictions
        Write-Log "New-Item -ItemType Junction failed: $($_.Exception.Message). Trying mklink..." -Level Debug
        $output = & cmd.exe /c "mklink /J `"$Path`" `"$Target`"" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-ReparsePoint -Path $Path)) {
            throw "Failed to create junction point '$Path' -> '$Target'. Output: $output"
        }
    }

    Write-Log "Junction created: '$Path' -> '$Target'" -Level Success
}

function Remove-Junction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-ReparsePoint -Path $Path)) { return }
    if ($DryRun) {
        Write-Log "[DryRun] Remove junction: $Path" -Level Debug
        return
    }

    try {
        # For junction -- recursive=false: reparse-point is removed, target is not touched
        [IO.Directory]::Delete($Path, $false)
    }
    catch {
        # Sometimes fallback is needed
        $output = & cmd.exe /c "rmdir `"$Path`"" 2>&1
        if (Test-ReparsePoint -Path $Path) {
            throw "Failed to remove junction '$Path'. $output"
        }
    }
}

function Get-DirectoryFreshness {
    <#
    .SYNOPSIS
        Returns the maximum LastWriteTime among all files in the directory
        (not the directory itself, which is incorrect for profile activity assessment).
    #>
    [OutputType([DateTime])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [DateTime]::MinValue
    }

    try {
        $maxTime = [DateTime]::MinValue
        # Iterate through key profile activity markers
        $markers = @('Local State', 'Default\Preferences', 'Default\History', 'Default\Cookies')
        foreach ($m in $markers) {
            $f = [IO.Path]::Combine($Path, $m)
            if (Test-Path -LiteralPath $f -PathType Leaf) {
                $t = [IO.File]::GetLastWriteTime($f)
                if ($t -gt $maxTime) { $maxTime = $t }
            }
        }

        if ($maxTime -eq [DateTime]::MinValue) {
            # Fallback: recursive search for the freshest file (limited)
            $files = [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::TopDirectoryOnly)
            foreach ($f in $files) {
                try {
                    $t = [IO.File]::GetLastWriteTime($f)
                    if ($t -gt $maxTime) { $maxTime = $t }
                }
                catch { }
            }
        }
        return $maxTime
    }
    catch {
        return [DateTime]::MinValue
    }
}

function Test-DirectoryHasContent {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $en = [IO.Directory]::EnumerateFileSystemEntries($Path)
        return @($en).Count -gt 0
    }
    catch {
        return $false
    }
}

function Remove-ChromiumCache {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    Write-Log "`n--- Clearing Cache in '$(Split-Path $Path -Leaf)' ---" -Level Warning

    $targets = [System.Collections.Generic.List[string]]::new()

    foreach ($folder in $Script:Config.CacheFolders) {
        $targets.Add([IO.Path]::Combine($Path, $folder))
    }

    try {
        $profileDirs = [IO.Directory]::EnumerateDirectories($Path)
        foreach ($profileDir in $profileDirs) {
            $profileName = [IO.Path]::GetFileName($profileDir)
            if ($profileName -in $Script:Config.CacheFolders) { continue }

            foreach ($folder in $Script:Config.CacheFolders) {
                $targets.Add([IO.Path]::Combine($profileDir, $folder))
            }
            # NOTE: Service Worker/CacheStorage and Service Worker/ScriptCache are intentionally
            # excluded here. Despite the name, these directories are NOT expendable browser cache --
            # they are persistent storage for extension Service Workers (e.g. Bitwarden) and PWAs.
            # Deleting them causes extensions to lose their registered Service Worker state,
            # requiring a manual disable/enable cycle to recover. The browser regenerates true
            # cache (HTTP cache, shader cache, etc.) automatically; Service Worker storage does not
            # recover on its own and contains user-session-critical data.
        }
    }
    catch [UnauthorizedAccessException] {
        Write-Log "Access denied to profile enumeration in '$Path'" -Level Warning
    }
    catch {
        Write-Log "Profile enumeration error: $($_.Exception.Message)" -Level Warning
    }

    $cleaned = 0
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if ($DryRun) {
            Write-Log "[DryRun] Delete: $target" -Level Debug
            $cleaned++
            continue
        }
        try {
            [IO.Directory]::Delete($target, $true)
            $cleaned++
        }
        catch {
            Write-Log "Failed to clear: $target -- $($_.Exception.Message)" -Level Debug
        }
    }

    Write-Log "Directories cleared: $cleaned" -Level Success
}

# ============================================================================
# PROFILE MIGRATION
# ============================================================================

function Initialize-UserDataStructure {
    [CmdletBinding()]
    param()

    Write-Log "`n--- Setting Up Portable Profile ---" -Level Info

    $sysDir       = $Script:Config.SysChromiumDir
    $sysData      = $Script:Config.SysUserData
    $portableData = $Script:Config.PortableUserData
    $portableDataNorm = $portableData.TrimEnd('\')

    if (-not (Test-Path -LiteralPath $sysDir)) {
        if (-not $DryRun) {
            [void][IO.Directory]::CreateDirectory($sysDir)
        }
    }

    $needsJunction = $false
    $migrationStarted = $false

    if (Test-Path -LiteralPath $sysData) {

        if (Test-ReparsePoint -Path $sysData) {
            $target = Get-JunctionTarget -Path $sysData

            if ($null -ne $target -and $target.TrimEnd('\') -ieq $portableDataNorm) {
                Write-Log "Junction already configured correctly." -Level Success

                if (-not (Test-Path -LiteralPath $portableData)) {
                    Write-Log "WARNING: target missing, creating..." -Level Warning
                    if (-not $DryRun) {
                        [void][IO.Directory]::CreateDirectory($portableData)
                    }
                }
                return
            }

            Write-Log "External junction found: $target" -Level Warning

            # Any change to structure -- stop browser first
            if (-not $migrationStarted) {
                Stop-ChromiumProcesses
                $migrationStarted = $true
            }

            if ($null -ne $target -and (Test-DirectoryHasContent -Path $target)) {
                $shouldMigrate = $true
                if (Test-DirectoryHasContent -Path $portableData) {
                    $targetFresh   = Get-DirectoryFreshness -Path $target
                    $portableFresh = Get-DirectoryFreshness -Path $portableData
                    Write-Log "Freshness target='$targetFresh', portable='$portableFresh'" -Level Debug

                    if ($targetFresh -le $portableFresh) {
                        Write-Log "Portable profile is newer. External folder will not be migrated." -Level Info
                        $shouldMigrate = $false
                    }
                }

                if ($shouldMigrate) {
                    Backup-AndReplace -Source $target -Destination $portableData
                }
            }

            Remove-Junction -Path $sysData
            $needsJunction = $true
        }
        else {
            # Real directory in system location
            Write-Log "System User Data folder with data detected." -Level Warning

            if (-not $migrationStarted) {
                Stop-ChromiumProcesses
                $migrationStarted = $true
            }

            if (Test-DirectoryHasContent -Path $portableData) {
                $sysFresh      = Get-DirectoryFreshness -Path $sysData
                $portableFresh = Get-DirectoryFreshness -Path $portableData
                Write-Log "Freshness system='$sysFresh', portable='$portableFresh'" -Level Debug

                if ($sysFresh -gt $portableFresh) {
                    Write-Log "System profile is newer. Replacing portable..." -Level Warning
                    Backup-AndReplace -Source $sysData -Destination $portableData
                }
                else {
                    Write-Log "Portable profile is newer. Deleting system folder." -Level Info
                    if (-not $DryRun) {
                        [IO.Directory]::Delete($sysData, $true)
                    }
                }
            }
            else {
                Write-Log "Moving system profile to portable..." -Level Info
                if (-not $DryRun) {
                    if (Test-Path -LiteralPath $portableData) {
                        [IO.Directory]::Delete($portableData, $true)
                    }
                    # Move only works within the same volume; if not -- fallback
                    try {
                        [IO.Directory]::Move($sysData, $portableData)
                    }
                    catch [IOException] {
                        Copy-Item -LiteralPath $sysData -Destination $portableData -Recurse -Force
                        [IO.Directory]::Delete($sysData, $true)
                    }
                }
            }

            $needsJunction = $true
        }
    }
    else {
        # System folder missing -- first launch or clean system
        $needsJunction = $true
    }

    if (-not (Test-Path -LiteralPath $portableData)) {
        Write-Log "Creating portable User Data folder..." -Level Info
        if (-not $DryRun) {
            [void][IO.Directory]::CreateDirectory($portableData)
        }
    }

    if ($needsJunction) {
        # If processes were not stopped yet (case: first installation,
        # sysData missing) -- browser cannot be running, nothing to stop.
        # If sysData existed, migration already stopped processes above.
        New-DirectoryJunction -Path $sysData -Target $portableData
    }
}

function Backup-AndReplace {
    <#
    .SYNOPSIS
        Atomic replacement of destination with source with a backup of destination.
        If copying is interrupted -- destination remains untouched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if ($DryRun) {
        Write-Log "[DryRun] Migrate: $Source -> $Destination" -Level Debug
        return
    }

    $backupPath = "$Destination.migrate-backup-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"

    if (Test-Path -LiteralPath $Destination) {
        Write-Log "Saving existing '$Destination' to '$backupPath'..." -Level Info
        # Rename-then-overwrite: atomic
        try {
            [IO.Directory]::Move($Destination, $backupPath)
        }
        catch {
            throw "Failed to create backup of '$Destination': $($_.Exception.Message)"
        }
    }

    try {
        # Copy (do not move -- source might be a junction target elsewhere)
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
        Write-Log "Migration complete. Old profile saved in '$backupPath'." -Level Success
    }
    catch {
        # Rollback
        Write-Log "Migration error: $($_.Exception.Message). Rolling back..." -Level Error
        if (Test-Path -LiteralPath $Destination) {
            [IO.Directory]::Delete($Destination, $true)
        }
        if (Test-Path -LiteralPath $backupPath) {
            [IO.Directory]::Move($backupPath, $Destination)
        }
        throw
    }
}

# ============================================================================
# CONFIG BACKUP / RESTORE
# ============================================================================

function Backup-ChromiumConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    Write-Log "Creating configuration files backup..." -Level Info
    if ($DryRun) { return }

    if (Test-Path -LiteralPath $BackupPath) {
        [IO.Directory]::Delete($BackupPath, $true)
    }
    [void][IO.Directory]::CreateDirectory($BackupPath)

    foreach ($file in $Script:Config.ProtectedFiles) {
        $source = [IO.Path]::Combine($Script:Config.AppDir, $file)
        if (Test-Path -LiteralPath $source) {
            $dest = [IO.Path]::Combine($BackupPath, $file)
            Copy-Item -LiteralPath $source -Destination $dest -Force
            Write-Log "Backup: $file" -Level Debug
        }
    }
}

function Restore-ChromiumConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    if (-not (Test-Path -LiteralPath $BackupPath)) { return }
    if ($DryRun) { return }

    Write-Log "Restoring configs..." -Level Info

    # Restore ONLY files from the approved list
    foreach ($file in $Script:Config.ProtectedFiles) {
        $source = [IO.Path]::Combine($BackupPath, $file)
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $dest = [IO.Path]::Combine($Script:Config.AppDir, $file)
            Copy-Item -LiteralPath $source -Destination $dest -Force
            Write-Log "Restore: $file" -Level Debug
        }
    }
}

# ============================================================================
# UPDATE CHECK AND VERIFICATION
# ============================================================================

function Get-LatestRelease {
    [CmdletBinding()]
    param()

    $headers = @{
        'User-Agent' = $Script:Config.UserAgent
        'Accept'     = 'application/vnd.github+json'
    }
    if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
        $headers['Authorization'] = "Bearer $GitHubToken"
    }

    try {
        return Invoke-RestMethod `
            -Uri $Script:Config.GitHubApiUrl `
            -Headers $headers `
            -TimeoutSec $Script:Config.HttpTimeoutSec `
            -UseBasicParsing
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        Write-Log "GitHub API unavailable (HTTP $statusCode): $($_.Exception.Message)" -Level Warning
        throw
    }
}

function Test-DownloadIntegrity {
    <#
    .SYNOPSIS
        Verifies SHA256 of the downloaded file if a hashes file is present in the release.
        Returns $true if verification passed or hash is unavailable (best-effort).
        Returns $false if hash is found and does NOT match.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$AssetName
    )

    # Search for asset with .sha256 extension or _hashes.txt
    $hashAsset = $Release.assets | Where-Object {
        $_.name -match '\.sha256$' -or $_.name -match 'hashes' -or $_.name -match 'sha256'
    } | Select-Object -First 1

    if (-not $hashAsset) {
        Write-Log "SHA256 hashes file not published in release. Skipping verification." -Level Warning
        return $true
    }

    try {
        $hashContent = (Invoke-WebRequest `
            -Uri $hashAsset.browser_download_url `
            -UseBasicParsing `
            -TimeoutSec $Script:Config.HttpTimeoutSec).Content

        # Format: <hex> *<filename> or <hex>  <filename>
        $expectedHash = $null
        foreach ($line in $hashContent -split "`r?`n") {
            if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') {
                if ($Matches[2].Trim() -ieq $AssetName) {
                    $expectedHash = $Matches[1].ToLowerInvariant()
                    break
                }
            }
        }

        if (-not $expectedHash) {
            Write-Log "SHA256 for '$AssetName' not found in hash file." -Level Warning
            return $true
        }

        $actualHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            Write-Log "SHA256 MISMATCH! Expected: $expectedHash, Got: $actualHash" -Level Error
            return $false
        }

        Write-Log "SHA256 verified: $actualHash" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to verify SHA256: $($_.Exception.Message)" -Level Warning
        return $true  # Do not block update if hash data is missing
    }
}

function Test-AuthenticodeSignature {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid') {
            Write-Log "Authenticode: $($sig.SignerCertificate.Subject)" -Level Debug
            return $true
        }
        # StatusMessage from .NET API contains misleading text
        # regarding execution policies (intended for .ps1, not .exe).
        # For NotSigned we only output status -- this is sufficient.
        Write-Log "Authenticode: $($sig.Status)" -Level Warning
        return $false
    }
    catch {
        Write-Log "Authenticode check unavailable: $($_.Exception.Message)" -Level Debug
        return $false
    }
}

function Expand-UpdateArchive {
    <#
    .SYNOPSIS
        Extracts ZIP with Zip-Slip protection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    # In Windows PowerShell 5.1 (.NET Framework) assembly is not loaded by default.
    # In PowerShell Core (7+) on .NET Core/5+ -- already loaded. Add-Type is idempotent.
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        [IO.Directory]::Delete($DestinationPath, $true)
    }
    [void][IO.Directory]::CreateDirectory($DestinationPath)

    $destFull = [IO.Path]::GetFullPath($DestinationPath).TrimEnd('\') + '\'

    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $targetPath = [IO.Path]::GetFullPath([IO.Path]::Combine($DestinationPath, $entry.FullName))

            # Zip-Slip protection
            if (-not $targetPath.StartsWith($destFull, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Zip-Slip attack detected! Entry attempts to write outside the directory: $($entry.FullName)"
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                # This is a directory
                [void][IO.Directory]::CreateDirectory($targetPath)
                continue
            }

            $parentDir = [IO.Path]::GetDirectoryName($targetPath)
            if (-not [IO.Directory]::Exists($parentDir)) {
                [void][IO.Directory]::CreateDirectory($parentDir)
            }

            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Invoke-RobocopyDeploy {
    <#
    .SYNOPSIS
        Correct deployment via robocopy with proper exit code interpretation.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @()
    )

    $roboArgs = [System.Collections.Generic.List[string]]::new()
    $roboArgs.Add($Source)
    $roboArgs.Add($Destination)
    $roboArgs.AddRange([string[]]@(
        '/E'                      # All subdirectories, including empty ones
        '/COPY:DAT'               # Data, Attributes, Timestamps (no ACL/Owner -- not our use case)
        '/DCOPY:DAT'              # Same attributes for directories
        '/MT:8'                   # 8 parallel threads
        '/R:2'                    # 2 retries
        '/W:1'                    # 1 second between retries
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP'  # Quiet mode
    ))
    if ($ExcludeDirs.Count -gt 0) {
        $roboArgs.Add('/XD')
        $roboArgs.AddRange([string[]]$ExcludeDirs)
    }
    if ($ExcludeFiles.Count -gt 0) {
        $roboArgs.Add('/XF')
        $roboArgs.AddRange([string[]]$ExcludeFiles)
    }

    Write-Log "Robocopy: $Source -> $Destination" -Level Debug

    if ($DryRun) {
        Write-Log "[DryRun] robocopy $($roboArgs -join ' ')" -Level Debug
        return 0
    }

    # Redirect both streams to variable for analysis in case of error
    $output = & robocopy.exe @roboArgs 2>&1
    $code = $LASTEXITCODE

    # Robocopy exit codes:
    # 0     = nothing done
    # 1     = files copied
    # 2     = extra files/dirs
    # 4     = mismatched files/dirs (warning)
    # 8     = some files not copied (FAIL)
    # 16    = serious error
    # Bits are additive. Any value >= 8 = error.
    if ($code -ge 8) {
        Write-Log "Robocopy output:`n$($output -join "`n")" -Level Error
        throw "Robocopy exited with error (code $code). Some files were not copied."
    }

    if (($code -band 4) -eq 4) {
        Write-Log "Robocopy: mismatched files detected (code $code)." -Level Warning
    }

    Write-Log "Robocopy successfully finished (code $code)." -Level Success
    return $code
}

function Update-ChromiumBinary {
    <#
    .SYNOPSIS
        Checks for updates and applies them.
    .OUTPUTS
        [bool] $true  -- update was applied;
              $false -- update not required or impossible.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($SkipUpdate) {
        Write-Log "Update check skipped (-SkipUpdate)." -Level Info
        return $false
    }

    Write-Log "`n--- Checking for Updates ---" -Level Info

    $localVersion = Get-ChromiumVersion -Path $Script:Config.ChromeExe
    Write-Log "Local version: $localVersion" -Level Info

    try {
        $release = Get-LatestRelease
    }
    catch {
        Write-Log "Failed to retrieve release information. Update skipped." -Level Warning
        return $false
    }

    try {
        $remoteVersion = ConvertTo-NormalizedVersion -Tag $release.tag_name
    }
    catch {
        Write-Log $_.Exception.Message -Level Warning
        return $false
    }

    Write-Log "GitHub version: $remoteVersion (tag: $($release.tag_name))" -Level Info

    if (-not $Force -and $localVersion -ge $remoteVersion) {
        Write-Log "Update not required." -Level Success
        return $false
    }

    $asset = $release.assets | Where-Object { $_.name -match '_windows_x64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw "Archive *_windows_x64.zip not found in release $($release.tag_name)."
    }

    Write-Log "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..." -Level Info

    if (-not $DryRun) {
        try {
            Invoke-WebRequest `
                -Uri $asset.browser_download_url `
                -OutFile $Script:Config.UpdateZip `
                -TimeoutSec $Script:Config.DownloadTimeoutSec `
                -UseBasicParsing `
                -UserAgent $Script:Config.UserAgent
        }
        catch {
            throw "Download failed: $($_.Exception.Message)"
        }

        # Verification
        if (-not (Test-DownloadIntegrity -FilePath $Script:Config.UpdateZip -Release $release -AssetName $asset.name)) {
            throw "Archive failed SHA256 integrity check."
        }
    }

    Write-Log "Extracting archive..." -Level Info
    Expand-UpdateArchive -ZipPath $Script:Config.UpdateZip -DestinationPath $Script:Config.TempUpdateDir

    $sourceRoot = Get-ChildItem -LiteralPath $Script:Config.TempUpdateDir -Directory |
        Select-Object -First 1
    if (-not $sourceRoot) {
        throw "Incorrect archive structure: root folder not found."
    }

    # Authenticode verification of extracted chrome.exe
    $newChromeExe = [IO.Path]::Combine($sourceRoot.FullName, 'chrome.exe')
    if (Test-Path -LiteralPath $newChromeExe) {
        if (-not (Test-AuthenticodeSignature -Path $newChromeExe)) {
            Write-Log "Authenticode signature of chrome.exe is not valid (normal for ungoogled-chromium -- not signed by Google). Continuing." -Level Warning
        }
    }

    # Remove from source files that should NOT overwrite user files
    Write-Log "Preparing for deployment..." -Level Info
    foreach ($file in $Script:Config.ProtectedFiles) {
        $filePath = [IO.Path]::Combine($sourceRoot.FullName, $file)
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            Remove-Item -LiteralPath $filePath -Force
        }
    }

    $newManifest = Get-ChildItem -LiteralPath $sourceRoot.FullName -Filter '*.manifest' |
        Select-Object -First 1

    # Backup BEFORE stopping processes (to rollback in case of stopping error)
    Backup-ChromiumConfig -BackupPath $Script:Config.TempBackupDir

    # Stop processes with real wait
    Stop-ChromiumProcesses

    # Deploy
    [void](Invoke-RobocopyDeploy `
        -Source $sourceRoot.FullName `
        -Destination $Script:Config.AppDir `
        -ExcludeDirs @('User Data', '.tmp_update', '.tmp_backup'))

    # Restore protected files
    Restore-ChromiumConfig -BackupPath $Script:Config.TempBackupDir

    # Remove orphan files from previous version
    Remove-OrphanedFiles -SourceRoot $sourceRoot.FullName -DestinationRoot $Script:Config.AppDir

    # Clean old manifests
    if ($newManifest -and -not $DryRun) {
        Get-ChildItem -LiteralPath $Script:Config.AppDir -Filter '*.manifest' |
            Where-Object { $_.Name -ne $newManifest.Name } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Final verification
    $newLocalVersion = Get-ChromiumVersion -Path $Script:Config.ChromeExe
    if ($newLocalVersion -lt $remoteVersion -and -not $DryRun) {
        Write-Log "Warning: version after installation = $newLocalVersion, expected $remoteVersion." -Level Warning
    }

    Write-Log "Update to $remoteVersion complete." -Level Success
    return $true
}

function Remove-OrphanedFiles {
    <#
    .SYNOPSIS
        Removes files in DestinationRoot absent in SourceRoot.
        Analogous to robocopy /MIR, but safer: excludes user files,
        protected configs, log, script itself and temp directories.
    .DESCRIPTION
        Comparison is done only at the top level and recursively for 
        Chromium internal directories (Locales, Extensions, etc).
        Files in distribution root not in the new build are removed
        as junk from previous versions (old .dll, .pak, .bin etc).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    if ($DryRun) {
        Write-Log "[DryRun] Searching for orphan files..." -Level Debug
        return
    }

    Write-Log "Searching for files from previous versions..." -Level Info

    # Protected names in root
    $rootProtected = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            $Script:Config.ProtectedFiles
            'User Data'
            '.tmp_update', '.tmp_backup'
            (Split-Path -Leaf $Script:Config.UpdateZip)
            (Split-Path -Leaf $Script:Config.LogFile)
            'chrupdate.ps1', 'chrupdate.fixed.ps1'  # script itself
            (Split-Path -Leaf $PSCommandPath)        # in case of rename
        ),
        [StringComparer]::OrdinalIgnoreCase
    )

    # Directories where file composition is strictly synced with the new version
    $syncDirs = @('Locales', 'resources', 'swiftshader', 'MEIPreload')

    $removedCount = 0

    # 1. Distribution root: remove files absent in source and not protected
    try {
        $sourceFiles = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]([IO.Directory]::EnumerateFiles($SourceRoot, '*', [IO.SearchOption]::TopDirectoryOnly) |
                ForEach-Object { [IO.Path]::GetFileName($_) }),
            [StringComparer]::OrdinalIgnoreCase
        )

        foreach ($destFile in [IO.Directory]::EnumerateFiles($DestinationRoot, '*', [IO.SearchOption]::TopDirectoryOnly)) {
            $name = [IO.Path]::GetFileName($destFile)
            if ($rootProtected.Contains($name)) { continue }
            if ($sourceFiles.Contains($name))   { continue }

            try {
                [IO.File]::Delete($destFile)
                Write-Log "Removed orphan: $name" -Level Debug
                $removedCount++
            }
            catch {
                Write-Log "Failed to remove '$name': $($_.Exception.Message)" -Level Debug
            }
        }
    }
    catch {
        Write-Log "Error searching for orphan files in root: $($_.Exception.Message)" -Level Warning
    }

    # 2. Sync directories: full composition synchronization
    foreach ($dirName in $syncDirs) {
        $sourceDir = [IO.Path]::Combine($SourceRoot, $dirName)
        $destDir   = [IO.Path]::Combine($DestinationRoot, $dirName)

        if (-not (Test-Path -LiteralPath $destDir -PathType Container))   { continue }
        if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) { continue }

        try {
            $sourceRel = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]([IO.Directory]::EnumerateFiles($sourceDir, '*', [IO.SearchOption]::AllDirectories) |
                    ForEach-Object { $_.Substring($sourceDir.Length).TrimStart('\') }),
                [StringComparer]::OrdinalIgnoreCase
            )

            foreach ($destFile in [IO.Directory]::EnumerateFiles($destDir, '*', [IO.SearchOption]::AllDirectories)) {
                $rel = $destFile.Substring($destDir.Length).TrimStart('\')
                if ($sourceRel.Contains($rel)) { continue }

                try {
                    [IO.File]::Delete($destFile)
                    Write-Log "Removed orphan: $dirName\$rel" -Level Debug
                    $removedCount++
                }
                catch {
                    Write-Log "Failed to remove '$dirName\$rel': $($_.Exception.Message)" -Level Debug
                }
            }
        }
        catch {
            Write-Log "Error synchronizing '$dirName': $($_.Exception.Message)" -Level Warning
        }
    }

    Write-Log "Orphan files removed: $removedCount" -Level Success
}

function Clear-TempFiles {
    [CmdletBinding()]
    param()

    $paths = @(
        $Script:Config.UpdateZip
        $Script:Config.TempUpdateDir
        $Script:Config.TempBackupDir
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $attrs = [IO.File]::GetAttributes($path)
            if (($attrs -band [IO.FileAttributes]::Directory) -eq [IO.FileAttributes]::Directory) {
                [IO.Directory]::Delete($path, $true)
            }
            else {
                [IO.File]::Delete($path)
            }
        }
        catch {
            Write-Log "Failed to remove temporary object: $path -- $($_.Exception.Message)" -Level Debug
        }
    }
}

function Read-SpacebarOverride {
    <#
    .SYNOPSIS
        Waits for Spacebar press for TimeoutSeconds seconds with countdown.
    .DESCRIPTION
        Used for optional override input in interactive runs.
        In non-interactive (scheduler, redirected stdin) -- returns $false immediately.
        Returns $true if Spacebar was pressed before timeout.

        Uses [System.Console] directly (not Write-Host / RawUI) as Write-Host
        is buffered and -NoNewline + \r may not render until flush on some 
        console configurations (Windows Terminal, ConPTY).
    #>
    [OutputType([bool])]
    param(
        [int]$TimeoutSeconds = 3,
        [string]$Prompt = 'Press SPACEBAR to force-close browser and clear cache'
    )

    # Interactivity check
    if (-not [Environment]::UserInteractive) { return $false }
    # If stdin is redirected (piped / scheduler) -- KeyAvailable does not work
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { return $false }

    # Clear input buffer of accidental presses
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    }
    catch {
        # If KeyAvailable is not supported by this host -- override unavailable
        return $false
    }

    # Save original color
    $origFg = [Console]::ForegroundColor
    $pressed = $false

    try {
        # New line + initial output
        [Console]::WriteLine()
        [Console]::ForegroundColor = 'Yellow'

        $deadline = [DateTime]::Now.AddSeconds($TimeoutSeconds)
        $lastSecond = -1

        while ([DateTime]::Now -lt $deadline) {
            $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::Now).TotalSeconds)

            # Redraw string only when second changed -- less flicker
            if ($remaining -ne $lastSecond) {
                $line = "  {0} ({1})... " -f $Prompt, $remaining
                # \r at start -- carriage return. Padding with spaces at end just in case.
                [Console]::Write("`r" + $line.PadRight(80))
                $lastSecond = $remaining
            }

            # Check press (non-blocking)
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Spacebar) {
                    $pressed = $true
                    break
                }
                # Other key -- ignore, keep waiting
            }

            Start-Sleep -Milliseconds 50
        }
    }
    finally {
        # Erase countdown line and return carriage
        try {
            [Console]::Write("`r" + (' ' * 80) + "`r")
            [Console]::ForegroundColor = $origFg
        }
        catch { }
    }

    return $pressed
}

# ============================================================================
# MAIN FLOW
# ============================================================================

$exitCode = 0

try {
    Write-Log "==================================================" -Level Info -NoConsole
    Write-Log "Starting chrupdate v2.1 ($([DateTime]::Now))" -Level Info -NoConsole
    Write-Log "AppDir: $($Script:Config.AppDir)" -Level Debug -NoConsole

    if (-not (Acquire-SingleInstanceMutex)) {
        Write-Log "Another instance of the script is already running. Exiting." -Level Warning
        $exitCode = 2
        return
    }

    if ($DryRun) {
        Write-Log "DryRun Mode: destructive operations disabled." -Level Warning
    }

    # 1. Portability setup (junction). Must be BEFORE any profile operations
    #    and BEFORE browser launch, so User Data is written to the right place.
    #    Does not require stopping Chromium processes -- works with %LOCALAPPDATA%\Chromium,
    #    which is not locked, except for initial migration (handled below).
    Initialize-UserDataStructure

    # 2. Update check + installation.
    #    The function stops Chromium processes if applying an update.
    #    If "no update needed" -- browser keeps running.
    $updated = Update-ChromiumBinary

    # 3. Cache clearing.
    #    Logic:
    #    - after successful update: clear automatically (Code Cache / shaders
    #      from old V8/Skia version are invalidated);
    #    - otherwise: give user 3 seconds to press SPACEBAR for forced clear.
    if ($SkipCacheClean) {
        Write-Log "Cache clearing skipped (-SkipCacheClean)." -Level Info
    }
    elseif ($updated) {
        Write-Log "`nUpdate applied -- invalidating cache from old version." -Level Info
        if (Test-Path -LiteralPath $Script:Config.PortableUserData) {
            Remove-ChromiumCache -Path $Script:Config.PortableUserData
        }
    }
    else {
        # No update -- ask user
        $forceClean = Read-SpacebarOverride -TimeoutSeconds 3
        if ($forceClean) {
            Write-Log "`nForced cache clearing requested. Stopping browser and clearing cache..." -Level Warning
            # Cache files are locked by chrome.exe. Must stop browser.
            Stop-ChromiumProcesses
            if (Test-Path -LiteralPath $Script:Config.PortableUserData) {
                Remove-ChromiumCache -Path $Script:Config.PortableUserData
            }
        }
    }

    Write-Log "`nAll operations completed successfully." -Level Success
    Write-Log "Browser is ready to launch." -Level Success
}
catch {
    Write-Log "`nCritical error: $($_.Exception.Message)" -Level Error
    # Stack trace -- log only, not console
    Write-Log "Stack: $($_.ScriptStackTrace)" -Level Debug -NoConsole
    Write-Log "See details in $($Script:Config.LogFile)" -Level Error
    $exitCode = 1
}
finally {
    Clear-TempFiles
    Release-SingleInstanceMutex

    # In interactive mode always hold the window for 3 seconds so the user
    # can read the final output -- regardless of success or failure.
    if ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
        if ($exitCode -ne 0) {
            Write-Host "`nDetails in $($Script:Config.LogFile)" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
}

exit $exitCode
