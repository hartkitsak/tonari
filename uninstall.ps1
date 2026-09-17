param(
    [switch]$SkipConfig,
    [switch]$SkipStarship,
    [switch]$SkipTools,
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/hartkitsak/tonari.git"
$scriptPath = try { Split-Path -Parent $PSCommandPath -ErrorAction Stop } catch { $null }

# Auto-clone when piped via irm | iex (must be before admin check — $PSCommandPath is null)
if (-not $scriptPath -or -not (Test-Path (Join-Path $scriptPath "profile\Microsoft.PowerShell_profile.ps1"))) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git is required. Install it first: winget install Git.Git" }
    $cloneDir = Join-Path $env:TEMP "tonari"
    Write-Host "=== Cloning repo to $cloneDir ===" -ForegroundColor Cyan
    if (Test-Path "$cloneDir\.git") { git -C $cloneDir pull 2>&1 | Out-Null } else { git clone $repoUrl $cloneDir 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "Git clone/pull failed" }
    & "$cloneDir\uninstall.ps1" @PSBoundParameters
    return
}

# Component selection: remove everything by default, -Skip* to exclude
$removeConfig   = -not $SkipConfig
$removeStarship = -not $SkipStarship
$removeTools    = -not $SkipTools
$removeCleanup  = -not $SkipCleanup

if (-not ($removeConfig -or $removeStarship -or $removeTools -or $removeCleanup)) {
    Write-Host "Nothing to do (all components skipped)." -ForegroundColor Yellow
    return
}

# Always run elevated (winget uninstall and Machine PATH cleanup need admin)
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

function Test-WingetInstalled {
    param([string]$Id)
    $out = winget list --id $Id --accept-source-agreements 2>&1 | Out-String
    return ($out -match [regex]::Escape($Id))
}

function Invoke-WingetUninstall {
    param([string]$Id, [string]$Name)
    $out = winget uninstall --id $Id --silent --accept-source-agreements 2>&1 | Out-String
    if (-not (Test-WingetInstalled $Id)) { return $true }
    if ($out.Trim()) {
        $tail = ($out.Trim() -split "`n" | Select-Object -Last 2) -join ' | '
        Write-Host "    winget said: $tail" -ForegroundColor DarkGray
    }
    Write-Host "  [RETRY] $Name still registered, elevating to admin..." -ForegroundColor Yellow
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "winget"
        $psi.Arguments = "uninstall --id $Id --silent --accept-source-agreements"
        $psi.Verb = "RunAs"
        $psi.UseShellExecute = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($p) { $null = $p.WaitForExit(180000) }
    } catch {
        Write-Host "  [WARN] Elevation declined or failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    Start-Sleep -Seconds 2
    return -not (Test-WingetInstalled $Id)
}

function Remove-StaleToolPath {
    param([AllowNull()][string]$PathValue)

    $starshipPath = (Join-Path $env:USERPROFILE '.starship\bin').TrimEnd('\')
    $parts = $PathValue -split ';' | Where-Object {
        $entry = [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\')
        $isToolPath = $entry -eq $starshipPath -or
            $entry -match 'junegunn\.fzf.*Microsoft\.Winget\.Source' -or
            $entry -match 'ajeetdsouza\.zoxide.*Microsoft\.Winget\.Source' -or
            $entry -match 'Starship\.Starship.*Microsoft\.Winget\.Source' -or
            $entry -match '\\starship\\bin'
        -not ($isToolPath -and -not (Test-Path -LiteralPath $entry -PathType Container))
    }
    $parts -join ';'
}

# Manual deep clean used when winget's own uninstall silently fails
# (portable packages can refuse to uninstall from an elevated context).
# Removes links, package dirs, ARP registration, and dangling PATH entries.
function Remove-ToolLeftovers {
    param([string]$Id, [string[]]$Links)

    foreach ($lnk in $Links) {
        $linkPath = Join-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Links" $lnk
        if (Test-Path -LiteralPath $linkPath) {
            Remove-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
            Write-Host "    removed link: $lnk" -ForegroundColor DarkYellow
        }
    }

    $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    Get-ChildItem $pkgRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "${Id}_*" } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $_.FullName)) { Write-Host "    removed dir: $($_.Name)" -ForegroundColor DarkYellow }
        }

    foreach ($root in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
    )) {
        Get-ChildItem $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "${Id}_*" } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    removed registration: $($_.PSChildName)" -ForegroundColor DarkYellow
            }
    }

    foreach ($hive in @(
        @{ Reg = "Registry::HKEY_CURRENT_USER\Environment"; Scope = "User" }
        @{ Reg = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; Scope = "Machine" }
    )) {
        try {
            $cur = (Get-ItemProperty -Path $hive.Reg -Name PATH -ErrorAction SilentlyContinue).PATH
            if (-not $cur) { continue }
            $new = ($cur -split ';' | Where-Object {
                $entry = [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\')
                $isTool = $entry -like "*${Id}_*"
                -not ($isTool -and -not (Test-Path -LiteralPath $entry -PathType Container))
            }) -join ';'
            if ($new -ne $cur) {
                Set-ItemProperty -Path $hive.Reg -Name PATH -Value $new
                Write-Host "    cleaned $($hive.Scope) PATH entries" -ForegroundColor DarkYellow
            }
        } catch { }
    }
}

$phase = 0
$total = @($removeConfig, $removeStarship, $removeTools, $removeCleanup) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count

# ─── Phase 1: Config files ──────────────────────────────────────────
if ($removeConfig) {
    $phase++
    Write-Host "`n[$phase/$total] Config files" -ForegroundColor Cyan

    $wtSettingsPaths = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        "$env:LOCALAPPDATA\Scoop\apps\windows-terminal\current\settings.json"
    )
    $wtPath = $wtSettingsPaths | Where-Object { Test-Path (Split-Path -Parent $_) } | Select-Object -First 1

    $Configs = @(
        @{ Name = "PowerShell Profile"; Path = $PROFILE }
        @{ Name = "Starship";           Path = Join-Path $env:USERPROFILE ".config\starship.toml" }
    )
    if ($wtPath) { $Configs += @{ Name = "Windows Terminal"; Path = $wtPath } }

    foreach ($c in $Configs) {
        $restored = $false
        try {
            if (Test-Path $c.Path) {
                Remove-Item -Path $c.Path -Force
                Write-Host "  [REMOVED] $($c.Name)" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [WARN] Could not remove $($c.Name): $_" -ForegroundColor Yellow
        }

        try {
            $baseName = Split-Path -Leaf $c.Path
            $destDir  = Split-Path -Parent $c.Path
            $bakFiles = Get-ChildItem -Path $destDir -Filter "$baseName.bak.*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending
            $latestBak = $bakFiles | Select-Object -First 1
            if ($latestBak) {
                Rename-Item -Path $latestBak.FullName -NewName $baseName -Force
                Write-Host "  [RESTORED] $($latestBak.Name)" -ForegroundColor Green
                $restored = $true
            }
        } catch {
            Write-Host "  [WARN] Could not restore backup for $($c.Name): $_" -ForegroundColor Yellow
        }

        if ((-not (Test-Path $c.Path)) -and (-not $restored)) {
            Write-Host "  [NONE] $($c.Name)" -ForegroundColor Gray
        }
    }
}

# ─── Phase 2: Starship (files) ──────────────────────────────────────
if ($removeStarship) {
    $phase++
    Write-Host "`n[$phase/$total] Starship" -ForegroundColor Cyan

    $starshipDirs = @(
        "$env:USERPROFILE\.starship"
    )

    foreach ($dir in $starshipDirs) {
        if (Test-Path $dir) {
            try {
                Remove-Item -Path $dir -Recurse -Force
                Write-Host "  [REMOVED] $dir" -ForegroundColor Red
            } catch {
                Write-Host "  [WARN] Could not remove $($dir): $_" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [NONE] $dir" -ForegroundColor Gray
        }
    }

    if (Test-WingetInstalled "Starship.Starship") {
        Write-Host "  [FOUND] starship (winget machine-wide install)" -ForegroundColor Magenta
        if (Invoke-WingetUninstall -Id "Starship.Starship" -Name "starship") {
            Write-Host "  [UNINSTALLED] starship (winget)" -ForegroundColor Red
        } else {
            Write-Host "  [FAIL] starship winget package still present" -ForegroundColor Red
        }
    }
}

# ─── Phase 3: Tools (winget) ────────────────────────────────────────
if ($removeTools) {
    $phase++
    Write-Host "`n[$phase/$total] Tools" -ForegroundColor Cyan

    $WingetTools = @(
        @{ Id = "junegunn.fzf";              Name = "fzf";     Links = @("fzf.exe") }
        @{ Id = "ajeetdsouza.zoxide";        Name = "zoxide";  Links = @("zoxide.exe") }
        @{ Id = "BurntSushi.ripgrep.MSVC";   Name = "ripgrep"; Links = @("rg.exe") }
    )

    foreach ($t in $WingetTools) {
        $toolPath = Get-Command $t.Name -ErrorAction SilentlyContinue
        $inWinget = Test-WingetInstalled $t.Id
        if (-not $toolPath -and -not $inWinget) {
            Write-Host "  [NONE] $($t.Name)" -ForegroundColor Gray
            continue
        }
        try {
            if (Invoke-WingetUninstall -Id $t.Id -Name $t.Name) {
                foreach ($lnk in $t.Links) {
                    $leftover = Join-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Links" $lnk
                    if (Test-Path -LiteralPath $leftover) {
                        Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue
                        Write-Host "  [CLEAN] leftover link $lnk" -ForegroundColor DarkYellow
                    }
                }
                Write-Host "  [UNINSTALLED] $($t.Name)" -ForegroundColor Red
            } else {
                Write-Host "  [FALLBACK] manual deep clean for $($t.Name)..." -ForegroundColor Yellow
                Remove-ToolLeftovers -Id $t.Id -Links $t.Links
                if (-not (Test-WingetInstalled $t.Id)) {
                    Write-Host "  [UNINSTALLED] $($t.Name) (manual)" -ForegroundColor Red
                } else {
                    Write-Host "  [FAIL] $($t.Name) still present after manual clean" -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "  [FAIL] $($t.Name): $_" -ForegroundColor Red
        }
    }
}

# ─── Phase 4: Clean PATH ────────────────────────────────────────────
if ($removeCleanup) {
    $phase++
    Write-Host "`n[$phase/$total] Clean PATH" -ForegroundColor Cyan

    # Clean User PATH
    try {
        $envReg = "Registry::HKEY_CURRENT_USER\Environment"
        $currentPath = (Get-ItemProperty -Path $envReg -Name PATH -ErrorAction SilentlyContinue).PATH
        if (-not $currentPath) { $currentPath = "" }

        $newPath = Remove-StaleToolPath $currentPath

        if ($newPath -ne $currentPath) {
            Set-ItemProperty -Path $envReg -Name PATH -Value $newPath
            Write-Host "  [OK] Cleaned User PATH" -ForegroundColor Green
        } else {
            Write-Host "  [CLEAN] User PATH clean" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [FAIL] User PATH cleanup: $_" -ForegroundColor Red
    }

    # Clean Machine PATH
    try {
        $machineReg = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
        $currentMachinePath = (Get-ItemProperty -Path $machineReg -Name PATH -ErrorAction SilentlyContinue).PATH
        if (-not $currentMachinePath) { $currentMachinePath = "" }

        $newMachinePath = Remove-StaleToolPath $currentMachinePath

        if ($newMachinePath -ne $currentMachinePath) {
            Set-ItemProperty -Path $machineReg -Name PATH -Value $newMachinePath
            Write-Host "  [OK] Cleaned Machine PATH" -ForegroundColor Green
        } else {
            Write-Host "  [CLEAN] Machine PATH clean" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [FAIL] Machine PATH cleanup: $_" -ForegroundColor Red
    }

    $env:PATH = Remove-StaleToolPath $env:PATH
    Write-Host "  [OK] Refreshed PATH in this process" -ForegroundColor Green
}

Write-Host "`n[DONE] Selected uninstall phases finished. Review any warnings or failures above." -ForegroundColor Cyan
Write-Host "Close all Windows Terminal windows and reopen. Existing parent sessions retain their PATH and loaded prompt functions." -ForegroundColor Yellow
Write-Host "Press any key to close..." -ForegroundColor DarkGray
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { }
