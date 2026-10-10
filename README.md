# Ctrl+Alt+Salvage

*Forty years after the Collapse, the machines woke up. You are UNIT K-7, a salvage robot searching the Dead Zone for the Verdant Core, the device that could bring the planet back to life.*

## Download

**[Download the launcher (Windows)](https://github.com/TheDrTesla/The-wild-things/releases/latest/download/CtrlAltSalvageLauncher.exe)**

1. Run `CtrlAltSalvageLauncher.exe`.
2. The launcher downloads the game the first time, and installs any update each time you start it.
3. Press **PLAY**.

> **Windows SmartScreen:** the launcher isn't code-signed yet, so Windows may say *"Windows protected your PC"*. Click **More info → Run anyway**.

## How updates stay safe

Every game build is signed by the developer. Before installing anything, the launcher:

- checks the release's digital signature against a public key built into the launcher,
- checks the SHA-256 checksum of the download and of every file inside it,
- refuses to install files outside the game folder, and
- never "updates" to an older build.

If any check fails, the update is ignored and your current version keeps working. If your game files get damaged, the launcher notices and re-downloads them (or press **Repair**).

Files live in `%APPDATA%\CtrlAltSalvageLauncher\game`. Your saves live separately in `%APPDATA%\CtrlAltSalvage` and are never touched by updates.

---

## For the developer

This repo holds the launcher source (`launcher/`, a Godot 4.7 project) and hosts releases:

| Release tag | What it is | Published by |
|---|---|---|
| `launcher-v*` | The launcher players download | This repo's workflow, when you push a `launcher-v1.2.3` tag |
| `game-v*` | Signed game builds | The private game repo's workflow, on every push to `main` |

The launcher contains no passwords or tokens, only the public key in `launcher/scripts/updater.gd`.
