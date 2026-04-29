# Ungoogled Chromium Portable Manager

A robust PowerShell script (v2.1) designed to automate the installation, update, and "portabilization" of **Ungoogled Chromium** on Windows.

## Key Features

* **True Portability**: Uses NTFS Junction Points to redirect the system Chromium profile folder (`%LOCALAPPDATA%`) to the local script directory.
* **Atomic Migration**: Safely moves existing profiles between system and portable locations with automatic backups.
* **Smart Updates**: Checks GitHub API for the latest releases and updates only when a newer version is available.
* **Integrity & Security**: Verifies downloads using SHA256 checksums and checks Authenticode signatures.
* **High-Speed Deployment**: Utilizes `robocopy` with multi-threading for efficient file synchronization.
* **Safe Process Management**: Automatically detects and terminates running Chromium processes before updates.
* **Clean Installation**: Automatically removes orphaned files and junk from previous versions.
* **Logging**: Maintains a detailed `chrupdate.log` for troubleshooting.

## Quick Start

1. Place `chrupdate.ps1` in the folder where you want Ungoogled Chromium to be installed.

2. Windows marks files downloaded from the internet as potentially dangerous (Zone Identifier).
   This is standard OS behavior and is not related to the script itself.
   To dismiss the warning once and for all, run in PowerShell:
```powershell
   Unblock-File -Path "C:\Path\To\chrupdate.ps1"
```

3. Run the script with PowerShell:
```powershell
   .\chrupdate.ps1
```

## Command Line Arguments

| Parameter | Description |
| :--- | :--- |
| `-SkipUpdate` | Skip checking for updates and only perform maintenance/portability setup. |
| `-SkipCacheClean` | Do not clear the browser cache during the process. |
| `-Force` | Reinstall the browser even if the local version is up to date. |
| `-DryRun` | Show planned actions without making any changes to the system. |
| `-GitHubToken` | Use a Personal Access Token to avoid GitHub API rate limiting. |

## Technical Details

The script follows a strict execution flow:
1.  **Single Instance Check**: Uses a system Mutex to prevent data corruption from parallel runs.
2.  **Junction Management**: Ensures `%LOCALAPPDATA%\Chromium\User Data` points to your portable folder.
3.  **Version Comparison**: Extracts the version from `chrome.exe` and compares it with GitHub tags.
4.  **Backup**: Creates a temporary backup of configuration files (like `initial_preferences`) before updating.
5.  **Sync**: Deploys new files while excluding user data and protected configurations.

## Requirements

* **OS**: Windows 10 (version 1607+) or Windows 11.
* **Shell**: PowerShell 5.1 or higher.
* **Storage**: NTFS file system (required for Junction Points).

## Protected Files
The following files are preserved during updates to keep your custom settings intact:
* `initial_preferences` / `master_preferences`
* `chromium.config`
* `First Run`
* Entire `User Data` directory
