# brew-update-all

Upgrade Homebrew formulae and casks one by one, with interactive and auto modes.
A failed package never blocks the others — no more "one stuck download kills the whole batch".

## BrewUA — the GUI companion

**BrewUA** is a native SwiftUI macOS app (in `BrewUA/`) that brings the same two-phase upgrade strategy to a visual interface:

- 🏪 **App-Store-style upgrade center** — check for updates, tick the ones you want, update selected or all
- 📦 **Per-package progress** — download size (probed via HTTP HEAD), live speed, and status badges (waiting / downloading / downloaded / installing / done / failed)
- 📚 **Package manager** — browse, search, upgrade, pin-badge, uninstall, and a "ignored only" filter
- 🔒 **Upgrade ignore list** — shared with the CLI (`~/.config/brew-ua/ignored_casks`)
- 🖥 **Services manager** — start/stop `brew services`
- 🪞 **Mirror detection** — USTC / Tsinghua / Aliyun / official auto-detection (shell config aware)
- 🏷 **Cask auto-update badge** — shows whether a cask updates itself (`auto_updates`)

Build it from source with Xcode (project generated via `xcodegen` from `BrewUA/project.yml`). The GUI ships independently of the CLI versioning (GUI 1.x / CLI 1.8.x).

## Install

```bash
brew tap yingshu0218/update-all
brew install brew-update-all
```

## Usage

```bash
# Interactive mode – pick packages by number
brew ua

# Auto mode – upgrade everything without prompting
brew ua auto

# Formulae only / casks only
brew ua formula
brew ua cask

# Include self-updating apps (Chrome/VS Code etc. are skipped by default)
brew ua -a
brew ua auto -a

# Deep-clean download cache / clean this run's temp logs after upgrading
brew ua auto --prune
brew ua auto --clean-logs

# Environment diagnostics (network / tap sources / local config)
brew ua ck

# Ignore a cask, un-ignore it, list ignored casks
brew ua ig firefox
brew ua uig firefox
brew ua igl

# Ignore/un-ignore a formula (cask remains the default)
brew ua ig --formula wget
brew ua uig --formula wget
```

| Mode / option | Description |
|------|------|
| *(none)* | Interactive mode, enter numbers to pick packages |
| `auto` | Auto mode, upgrade everything |
| `formula` | Formulae only (interactive) |
| `cask` | Casks only (interactive) |
| `-a` | Include self-updating casks (Chrome, VS Code, Edge, …) |
| `--prune` | Deep clean download cache after upgrading (`brew cleanup --prune=all`) |
| `--clean-logs` | Clean this run's temp log directory |
| `ck` / `check` | Diagnostics: network, tap sources, local config |
| `ig` / `ignore <name>` | Ignore a cask (default) so it never appears in the update list |
| `ig --formula <name>` | Ignore a formula |
| `uig` / `unignore <name>` | Un-ignore a cask (default) |
| `uig --formula <name>` | Un-ignore a formula |
| `igl` / `ignored` | List ignored formulae and casks |

Ignore rules remain in `~/.config/brew-ua/ignored_casks`: legacy bare-name lines and new cask rules apply to casks; formula rules use `formula:<name>`. A rule containing `/` matches that full tap name only. A short name matches the last path component for the same package type.

> **Note**: without `-a`, Homebrew skips casks with `auto_updates true` (they update themselves). Add `-a` if you want to pin every app version.

## Features

- 🎨 **Colored UI** – clear color coding and polished borders
- 📊 **Progress bars** – overall progress with percentage
- ⏱️ **Timing stats** – per-package and total duration
- 📋 **Summary report** – success/failure counts and detail lists
- 🎯 **Category filter** – formulae-only or casks-only
- 🚫 **Ignore list** – skip specific formulae and casks
- 🔍 **Logging** – failed packages keep logs in a private temp dir (`$TMPDIR/brew-ua.XXXXXX`)
- 📦 **Package size** – parsed after download and shown inline
- ⚡ **Download speed** – live MB/s for both casks and formulae
- 🌀 **Spinner animations** – live feedback while working
- 🧹 **Cleanup options** – deep cache prune and temp log cleanup

## How it works

1. **brew update** – refresh taps and package info
2. **List outdated packages** – formulae and casks in a bordered panel
3. **Stage 1: download all** – fetch each package with live progress/speed, a per-package timeout (default 10 min), and failure isolation. Formula fetches include `--deps`; cask fetches use supported cask options. Cancellation and timeout stop and reap the download process group.
4. **Stage 2: install all** – install only the successfully downloaded packages (casks via `brew reinstall`, formulae via `brew upgrade`). Cancellation waits for the current install to finish before stopping the queue. Formula source builds and cask installers can still need network access during installation.
5. **brew cleanup** – remove old versions
6. **Summary** – total time, success rate, success/failure lists

## Changelog

### v1.8.7 (2026-08-20)

- 🖥 **BrewUA GUI** — native SwiftUI app with App-Store-style upgrade center, package manager, services manager and mirror detection
- 🐛 **Crash fixes** — strict `@MainActor` isolation for all engine/service streams (background `@Published` mutation no longer possible)
- ⚡ **Download UX** — per-package size via HTTP HEAD, live speed via cache-file polling, status badges per stage
- 🔒 **Ignore list UI** — red lock toggle in the GUI + "ignored only" filter

### v1.8.5 (2026-08-13)

- 🏗️ **Two-phase upgrade** – download every package first (with live speed, per-package timeout and failure isolation), then install the ones that downloaded OK. A single stuck download can no longer stall anything else
- ⚡ **Formula download speed** – formulae now show the same live MB/s progress as casks
- 🖥️ **Non-TTY output** – clean plain-text output when piped/redirected (no ANSI noise)
- 🧪 **Test suite + CI** – smoke tests (`scripts/test.sh`) covering speed, sizing, two-phase order, timeout, failure isolation and non-TTY; CI runs syntax check, tests and `brew audit`
- 🔒 **Strict mode & single-instance lock** – undefined-variable errors surface early; a second `brew ua` refuses to run
- 📢 **Version self-check** – notifies when a new release is available

### v1.8.4 (2026-08-13)

- 🐛 **Homebrew 6.x compatibility** – `brew --verbose fetch` broke on Homebrew 6.x ("Unknown command"); now uses the `HOMEBREW_VERBOSE=1` env var
- ⚡ **Download speed** – parses brew's `Downloading X/Y` frames into live MB/s
- 🤖 **Auto release** – pushing a `v*` tag downloads the tarball, computes sha256 and bumps the Formula automatically

### v1.8.3 (2026-08-12)

- 🐛 **Failed download no longer reported as success** – fetch exit code was taken from the wrong pipe slot (always `tee`'s 0)
- 🐛 **UI artifacts fixed** – download/install row accounting unified via cursor-save + clear
- 🐛 **Package size always `?` fixed** – supports `20.0M` / `121k` formats
- 🛡️ **Temp logs hardened** – moved from fixed `/tmp` filenames to a private temp dir

## Uninstall

```bash
brew uninstall brew-update-all
brew untap yingshu0218/update-all
```

## CI

- **CNB** (`.cnb.yml`) — zsh syntax check, smoke tests, CLI boundary regressions, and lock checks on every push (tests use fake brew and no network)
- **GitHub Actions** — CLI tests and Formula checks, plus a macOS app build/XCTest workflow
- **CNB sync** — GitHub checks the CNB development repo daily at 09:17 China time. After a successful sync it explicitly dispatches CLI and macOS validation for the actual GitHub `main` SHA, then dispatches one Formula update for the highest valid newly synced `v*` tag. Formula updates start from current `main` and reject downgrades. These runs do not depend on recursive `push` events from `GITHUB_TOKEN`.

## License

MIT
