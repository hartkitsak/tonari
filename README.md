<div align="center">

# ⚡ tonari

**Windows dev environment · PowerShell profile · CLI toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=powershell&logoColor=white)]()
[![Windows Terminal](https://img.shields.io/badge/Windows%20Terminal-4D4D4D?style=flat&logo=windowsterminal&logoColor=white)]()

</div>

---

## Overview

One-command setup for a modern Windows dev environment: PowerShell profile with zoxide + PSFzf, Starship prompt, Windows Terminal settings, and CLI tools (fzf, zoxide, ripgrep). Always runs elevated — a UAC prompt appears once, then everything works with full rights.

## Installation

Run directly from GitHub — no clone required.

```powershell
irm https://raw.githubusercontent.com/hartkitsak/tonari/master/install.ps1 | iex
```

Or clone and run locally:

```powershell
git clone https://github.com/hartkitsak/tonari.git
.\tonari\install.ps1
```

> **Uninstall:** `irm .../uninstall.ps1 \| iex` (direct) or `.\tonari\uninstall.ps1` (local)

> **UAC prompt:** Both scripts require administrator rights and will trigger one UAC prompt. Your selections are carried over to the elevated window automatically — nothing needs to be re-entered.

## What Happens When You Run It

**Everything is installed (or removed) by default** — no menu. To exclude components, pass skip flags:

```powershell
.\tonari\install.ps1                    # install all 4 phases
.\tonari\install.ps1 -SkipTools        # skip winget tools, install the rest
.\tonari\uninstall.ps1 -SkipCleanup    # uninstall everything except PATH cleanup
```

A UAC prompt appears once at start. All phases then run in a single elevated window, which stays open ("Press any key to close") so you can read the `[OK]` / `[FAIL]` results before it exits. Declining the UAC prompt cancels the run with `[CANCELED]`.

Skip flags: `-SkipTools`, `-SkipStarship`, `-SkipConfig`, `-SkipCleanup`

## What's Included

| Component | Description |
|-----------|-------------|
| **PowerShell Profile** | PSReadLine prediction, zoxide, PSFzf (Ctrl+t / Ctrl+r), custom functions + aliases |
| **Starship Prompt** | Minimal single-line prompt |
| **Windows Terminal** | 90% opacity, acrylic, custom keybindings |
| **CLI Tools** | fzf, zoxide, ripgrep (installed via winget) |

## install.ps1

4 independent phases. Runs elevated (UAC prompt on start). Installs everything by default — use `-SkipTools`, `-SkipStarship`, `-SkipConfig`, or `-SkipCleanup` to exclude phases.

| # | Phase | Description |
|---|-------|-------------|
| 1 | **Tools** | winget install fzf, zoxide, ripgrep (silent, skips if on PATH) |
| 2 | **Starship** | Download latest binary → `~/.starship/bin` → add to User PATH |
| 3 | **Config** | Copy profile, starship.toml, terminal settings (MD5 skip if identical, backs up as `.bak.<timestamp>`) |
| 4 | **Clean PATH** | Remove tool PATH entries whose directory no longer exists (stale winget leftovers) |

## uninstall.ps1

4 phases. Runs elevated (UAC prompt on start). Removes everything by default — use `-SkipConfig`, `-SkipStarship`, `-SkipTools`, or `-SkipCleanup` to exclude phases.

| # | Phase | Description |
|---|-------|-------------|
| 1 | **Config** | Remove installed files → restore latest `.bak.*` backup |
| 2 | **Starship** | Delete `~/.starship/` directory |
| 3 | **Tools** | winget uninstall fzf, zoxide, ripgrep — verified after removal |
| 4 | **Clean PATH** | Clean User + Machine PATH of stale entries |

## Aliases

| Alias | Maps to |
|-------|---------|
| `ll` | `Get-ChildItem` |
| `la` | `Get-ChildItem -Force` (function, show hidden) |
| `gs` | `git` |
| `ga` | `git add` |
| `gp` | `git push` |
| `gst` | `git status` |
| `gco` | `git checkout` |
| `gcmsg` | `git commit -m` |
| `gl` | `git log --oneline --graph --decorate` |
| `v` | `nvim` |

## Functions

| Function | Description |
|----------|-------------|
| `ff` | Fuzzy find files via ripgrep + fzf (includes hidden, skips `.git`) |
| `cdf` | Fuzzy `cd` into subdirectories (max depth 4) |
| `..` | Go up one directory |
| `...` | Go up two directories |
| `take <dir>` | Create and `cd` into a directory |

## Project Structure

```
tonari/
├── install.ps1                     # 4-phase setup with interactive menu
├── uninstall.ps1                   # 4-phase teardown with interactive menu
├── profile/
│   └── Microsoft.PowerShell_profile.ps1
├── config/
│   ├── starship.toml
│   └── windows-terminal.settings.json
└── .gitignore
```
