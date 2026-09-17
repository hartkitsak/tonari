param(
    [switch]$SkipTools,
    [switch]$SkipStarship,
    [switch]$SkipConfig,
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/hartkitsak/tonari.git"
$scriptPath = try { Split-Path -Parent $PSCommandPath -ErrorAction Stop } catch { $null }

# Auto-clone when piped via irm | iex (no local files)
if (-not $scriptPath -or -not (Test-Path (Join-Path $scriptPath "profile\Microsoft.PowerShell_profile.ps1"))) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git is required. Install it first: winget install Git.Git" }
    $cloneDir = Join-Path $env:TEMP "tonari"
    Write-Host "=== Cloning repo to $cloneDir ===" -ForegroundColor Cyan
    if (Test-Path "$cloneDir\.git") { git -C $cloneDir pull 2>&1 | Out-Null } else { git clone $repoUrl $cloneDir 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "Git clone/pull failed" }
    & "$cloneDir\install.ps1" @PSBoundParameters
    return
}
$DOTFILES = $scriptPath

# Component selection: install everything by default, -Skip* to exclude
$installTools    = -not $SkipTools
$installStarship = -not $SkipStarship
$installConfig   = -not $SkipConfig
$installCleanup  = -not $SkipCleanup

if (-not ($installTools -or $installStarship -or $installConfig -or $installCleanup)) {
    Write-Host "Nothing to do (all components skipped)." -ForegroundColor Yellow
    return
}

# Always run elevated (winget, PATH, and machine-wide changes need admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "pwsh.exe"
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch] -and $kv.Value) { $argList += " -$($kv.Key)" }
    }
    $psi.Arguments = $argList
    $psi.Verb = "RunAs"
    $psi.UseShellExecute = $true
    try {
        $null = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Host "[CANCELED] Admin elevation declined: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit
}

$BackupSuffix = ".bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$phase = 0
$total = @($installTools, $installStarship, $installConfig, $installCleanup) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count

# ─── Phase 1: Tools (winget) ────────────────────────────────────────
if ($installTools) {
    $phase++
    Write-Host "`n[$phase/$total] Tools" -ForegroundColor Cyan

    $WingetTools = @(
        @{ Id = "junegunn.fzf";              Name = "fzf" }
        @{ Id = "ajeetdsouza.zoxide";        Name = "zoxide" }
        @{ Id = "BurntSushi.ripgrep.MSVC";   Name = "ripgrep" }
    )

    function Test-WingetInstalled {
        param([string]$Id)
        $out = winget list --id $Id --accept-source-agreements 2>&1 | Out-String
        return ($out -match [regex]::Escape($Id))
    }

    foreach ($t in $WingetTools) {
        $toolPath = Get-Command $t.Name -ErrorAction SilentlyContinue
        if ($toolPath) {
            Write-Host "  [ALREADY] $($t.Name)" -ForegroundColor Green
            continue
        }
        Write-Host "  [INSTALL] $($t.Name)..." -ForegroundColor Magenta
        try {
            winget install --id $t.Id --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            Start-Sleep -Seconds 2
            if (-not (Test-WingetInstalled $t.Id)) {
                Write-Host "  [FAIL] $($t.Name) not registered after install" -ForegroundColor Red
                continue
            }

            # winget from an elevated context often skips the user PATH update
            # for portable packages — detect the package dir and add it ourselves
            $pkgDir = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$($t.Id)_*" } | Select-Object -First 1
            if (-not $pkgDir) {
                Write-Host "  [WARN] $($t.Name) installed but package dir not found" -ForegroundColor Yellow
                continue
            }
            $exePath = Get-ChildItem $pkgDir.FullName -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $dirToAdd = if ($exePath) { $exePath.DirectoryName } else { $pkgDir.FullName }
            $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($userPath -notlike "*$dirToAdd*") {
                [Environment]::SetEnvironmentVariable("PATH", "$userPath;$dirToAdd", "User")
                $env:PATH = "$env:PATH;$dirToAdd"
                Write-Host "  [PATH] $($t.Name) -> $dirToAdd" -ForegroundColor Green
            }
            Write-Host "  [OK] $($t.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL] $($t.Name): $_" -ForegroundColor Red
        }
    }
}

# ─── Phase 2: Starship (manual) ─────────────────────────────────────
if ($installStarship) {
    $phase++
    Write-Host "`n[$phase/$total] Starship" -ForegroundColor Cyan

    $starshipBin = Get-Command starship -ErrorAction SilentlyContinue
    if ($starshipBin) {
        Write-Host "  [ALREADY] starship ($($starshipBin.Source))" -ForegroundColor Green
    }
    else {
        Write-Host "  [DOWNLOAD] starship..." -ForegroundColor Magenta
        $starshipDir = "$env:USERPROFILE\.starship"
        $binDir = "$starshipDir\bin"
        $zipPath = "$env:TEMP\starship.zip"
        try {
            $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/starship/starship/releases/latest" -Headers @{ "User-Agent" = "powershell" }
            $asset = $latest.assets | Where-Object { $_.name -like "*x86_64-pc-windows-msvc*" -and $_.name -like "*.zip" } | Select-Object -First 1
            if (-not $asset) { throw "No .zip asset found for x86_64" }
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath
            New-Item -ItemType Directory -Path $binDir -Force | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $binDir -Force
            Remove-Item $zipPath -Force
            Write-Host "  [OK] starship -> $binDir" -ForegroundColor Green
            $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
            if ($userPath -notlike "*$binDir*") {
                [Environment]::SetEnvironmentVariable("PATH", "$userPath;$binDir", "User")
                $env:PATH = "$env:PATH;$binDir"
                Write-Host "  [PATH] Added $binDir to PATH" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [FAIL] starship download: $_" -ForegroundColor Red
        }
    }
}

# ─── Phase 3: Config ────────────────────────────────────────────────
if ($installConfig) {
    $phase++
    Write-Host "`n[$phase/$total] Config files" -ForegroundColor Cyan

    $wtSettingsPaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        "$env:LOCALAPPDATA\Scoop\apps\windows-terminal\current\settings.json"
    )
    $wtDest = $wtSettingsPaths | Where-Object { Test-Path (Split-Path -Parent $_) } | Select-Object -First 1
    if (-not $wtDest) { $wtDest = $wtSettingsPaths[0] }

    $Configs = @(
        @{ Name = "PowerShell Profile"; Source = Join-Path $DOTFILES "profile\Microsoft.PowerShell_profile.ps1"; Dest = $PROFILE }
        @{ Name = "Starship";           Source = Join-Path $DOTFILES "config\starship.toml";                     Dest = Join-Path $env:USERPROFILE ".config\starship.toml" }
        @{ Name = "Windows Terminal";   Source = Join-Path $DOTFILES "config\windows-terminal.settings.json";   Dest = $wtDest }
    )

    foreach ($c in $Configs) {
        if (-not (Test-Path $c.Source)) {
            Write-Host "  [SKIP] $($c.Name) source not found" -ForegroundColor Yellow
            continue
        }
        try {
            $destDir = Split-Path -Parent $c.Dest
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            if (Test-Path $c.Dest) {
                $currentHash = (Get-FileHash $c.Dest -Algorithm MD5).Hash
                $sourceHash  = (Get-FileHash $c.Source -Algorithm MD5).Hash
                if ($currentHash -eq $sourceHash) {
                    Write-Host "  [SAME]  $($c.Name)" -ForegroundColor Green
                    continue
                }
                $bakName = "$(Split-Path -Leaf $c.Dest)$BackupSuffix"
                Rename-Item -Path $c.Dest -NewName $bakName -Force
                Write-Host "  [BACKUP] -> $($c.Name)" -ForegroundColor DarkYellow
            }
            Copy-Item -Path $c.Source -Destination $c.Dest -Force
            Write-Host "  [OK] $($c.Name)" -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL] $($c.Name): $_" -ForegroundColor Red
        }
    }
}

# ─── Phase 4: Clean stale PATH entries ──────────────────────────────
if ($installCleanup) {
    $phase++
    Write-Host "`n[$phase/$total] Clean PATH" -ForegroundColor Cyan

    try {
        $envReg = "Registry::HKEY_CURRENT_USER\Environment"
        $currentPath = (Get-ItemProperty -Path $envReg -Name PATH -ErrorAction SilentlyContinue).PATH
        if (-not $currentPath) { $currentPath = "" }

        $stalePatterns = @(
            "junegunn\.fzf.*Microsoft\.Winget\.Source",
            "ajeetdsouza\.zoxide.*Microsoft\.Winget\.Source"
        )

        # Only drop tool-related entries whose directory no longer exists on disk
        # (winget names live package dirs with the same source string, so pattern
        # matching alone would remove entries that are still valid)
        $newPathParts = $currentPath -split ';' | Where-Object {
            $entry = [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\')
            $isToolPath = $false
            foreach ($pattern in $stalePatterns) {
                if ($entry -match $pattern) { $isToolPath = $true; break }
            }
            -not ($isToolPath -and -not (Test-Path -LiteralPath $entry -PathType Container))
        }
        $newPath = $newPathParts -join ';'

        if ($newPath -ne $currentPath) {
            Set-ItemProperty -Path $envReg -Name PATH -Value $newPath
            Write-Host "  [OK] Removed stale PATH entries" -ForegroundColor Green
        } else {
            Write-Host "  [CLEAN] No stale PATH entries found" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [FAIL] PATH cleanup: $_" -ForegroundColor Red
    }
}

Write-Host "`n[DONE] Restart your terminal or run: . `$PROFILE" -ForegroundColor Cyan
Write-Host "Press any key to close..." -ForegroundColor DarkGray
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { }
