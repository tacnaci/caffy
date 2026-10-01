# Caffy

English | [简体中文](README.zh-CN.md)

A macOS menu bar app that keeps your MacBook awake with the lid closed, so long-running jobs (builds, downloads, AI coding agents, …) keep running.

`caffeinate` and similar tools only prevent *idle* sleep. Closing the lid still puts the Mac to sleep unless it is connected to power **and** an external display. Caffy toggles the system-wide `SleepDisabled` setting instead, which also covers lid-close sleep.

## Download

Get the latest `Caffy-<version>.dmg` from [Releases](https://github.com/tacnaci/caffy/releases/latest). The app is signed with a Developer ID and notarized by Apple.

Requires macOS 13 or later. Universal binary (Apple Silicon and Intel).

## Usage

1. Open the DMG and drag Caffy into **Applications**, then launch it. A cup icon appears in the menu bar.
2. Click the cup › **Turn On Keep Awake**.
3. The first time, macOS opens **System Settings › General › Login Items & Extensions**. Allow Caffy to run in the background, then turn it on again.

The icon turns solid while Caffy is keeping the Mac awake.

Menu options:

| Option | Description |
|---|---|
| Duration | 30 minutes / 1 / 2 / 4 hours / no limit. Sleep is restored automatically when time is up. Changes take effect immediately, counted from when Caffy was turned on. |
| Restore Sleep When Overheated | Restore sleep when the Mac gets too hot. On by default. |
| Restore Sleep on Low Battery | Restore sleep when running on battery below the threshold (10 / 20 / 30 / 50 %). On by default, 20 %. |
| Launch at Login | Start Caffy when you log in. |
| Helper | Install or uninstall the background helper. |

> ⚠️ Don't put a closed, awake MacBook into a sealed bag — it can overheat.

The UI is available in English and Simplified Chinese and follows your system language.

## How it works

Changing `SleepDisabled` (`pmset -a disablesleep 1`) requires root, so Caffy is split in two:

```
Caffy.app (menu bar, runs as you) ──XPC──▶ CaffyHelper (launchd daemon, runs as root)
                                                └─ pmset -a disablesleep 1 / 0
```

- The helper is bundled inside `Caffy.app` and registered with `SMAppService.daemon`. It only exposes "turn sleep prevention on/off" and "report its own code identity".
- Both sides verify each other's code signature over XPC: the peer must be signed by the same Team ID with the expected bundle identifier, so other processes cannot drive the helper.

### Safety

- When the app quits, crashes or is force-killed, its XPC connection drops and the helper restores sleep immediately.
- The helper also restores sleep when it starts (including at boot) and when launchd stops it, so a crash or power loss can't leave the Mac permanently awake.
- After an update, the app compares the running helper's cdhash with the one in its bundle. If they differ, it unregisters and re-registers the daemon so the new helper takes over. macOS keeps the user's approval, so no prompt is shown again.

## FAQ

**How do I remove it completely?**
Menu › Helper › Uninstall Helper, quit Caffy, then delete it from Applications.

**The Mac still won't sleep after removing Caffy.**
Run `sudo pmset -a disablesleep 0`.

## Building from source

Requires Xcode (Swift 5.9+) and an Apple Development certificate — `SMAppService` daemons only run from properly signed apps. No Xcode project is needed; `build.sh` drives `swiftc`, `codesign` and the notarization tools directly.

```
Sources/Shared/       XPC protocol and code-signing helpers (shared by both targets)
Sources/Caffy/        Menu bar app (SwiftUI MenuBarExtra)
Sources/CaffyHelper/  Root daemon, registered via SMAppService.daemon
Resources/            Info.plist files, launchd plist, app icon
scripts/              make-icon.swift — regenerates Resources/AppIcon.icns
```

```bash
./build.sh            # development build → build/Caffy.app
./build.sh install    # build, install to /Applications and launch
```

Signing identities are selected by team. The default team is the maintainer's (`VTDBDK5H2X`); set `CAFFY_TEAM_ID` to your own Team ID to build with your certificates. Development builds use the team's Apple Development certificate, release builds its Developer ID Application certificate. The app and helper must be signed by the same team, because the helper only accepts connections from apps signed with its own Team ID.

### Releasing (Developer ID + notarization)

```bash
./build.sh release    # universal build → notarize & staple app → DMG → notarize & staple DMG
```

One-time setup:

1. Create a **Developer ID Application** certificate for your team and install it in the keychain. Only the Account Holder can create one.
2. Store notarization credentials, either with an App Store Connect API key:
   ```bash
   xcrun notarytool store-credentials caffy-notary \
       --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```
   or with an Apple ID and an app-specific password: `--apple-id <Apple ID> --team-id <Team ID>`.

The output is `build/Caffy-<version>.dmg`. The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`, and `build.sh` copies it into the helper. Set `CAFFY_SKIP_NOTARIZE=1` to skip notarization when testing the packaging locally.

### Troubleshooting

```bash
pmset -g | grep SleepDisabled                       # current state
# use the full path: zsh has a builtin named `log`
/usr/bin/log show --last 10m --info --predicate 'subsystem BEGINSWITH "com.caffy"'
sudo pmset -a disablesleep 0                         # restore sleep manually
```
