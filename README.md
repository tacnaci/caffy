# Caffy

English | [简体中文](README.zh-CN.md)

A macOS menu bar app that keeps your MacBook awake with the lid closed, so long-running jobs (builds, downloads, AI coding agents, …) keep running.

`caffeinate` and similar tools only prevent *idle* sleep. Closing the lid still puts the Mac to sleep unless it is connected to power **and** an external display. Caffy toggles the system-wide `SleepDisabled` setting instead, which also covers lid-close sleep.

## Download

Get the latest `Caffy-<version>.dmg` from [Releases](https://github.com/xshowee/caffy/releases/latest). The app is signed with a Developer ID and notarized by Apple.

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
| Run While Awake | Run a command of your choice while Keep Awake is on, such as a tunnel for remote access. See [Run While Awake](#run-while-awake). |
| Launch at Login | Start Caffy when you log in. |
| Automatically Check for Updates | Check for a new version once a day. On by default. Use **Check for Updates…** to check at any time. |
| Helper | Install or uninstall the background helper. |

> ⚠️ Don't put a closed, awake MacBook into a sealed bag — it can overheat.

### Run While Awake

Caffy can keep a command running while Keep Awake is on, for example a tunnel so you can reach your Mac from your phone with the lid closed. Menu › **Run While Awake** › **Set Command…**, then enter the command as you would type it in Terminal:

```
cd ~/frp && frpc -c frpc.toml
```

- The command runs with `/bin/zsh -c` as you, never through the root helper. Homebrew's `bin` directories are added to `PATH`; the working directory is your home folder.
- Caffy remembers the last 5 commands. Pick one in the submenu to switch; if it's running, it restarts with the new command.
- It starts when Keep Awake turns on and stops when it turns off for any reason (manually, time's up, low battery, overheating). Caffy stops the whole process group, so child processes stop too.
- If it exits on its own, Caffy restarts it after 1, 2, 4 … up to 60 seconds. Use it for long-running commands, not one-off scripts.
- Output goes to `~/Library/Logs/Caffy/run-while-awake.log` (only readable by you, rotated at 1 MB). **Show Log** opens it in Console. Keep secrets in config files rather than on the command line, since the command is logged.
- Keep scripts and config files outside Desktop, Documents and Downloads (e.g. in `~/.config`), otherwise macOS may ask for permission to access those folders.

> ⚠️ A tunnel puts a port of your Mac on the internet. Only expose SSH with password login turned off (`PasswordAuthentication no` and `KbdInteractiveAuthentication no`), and reach Screen Sharing through an SSH tunnel. Never expose Screen Sharing (port 5900) directly.

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

## Updates

Starting with 1.0.3, Caffy updates itself with [Sparkle](https://sparkle-project.org). When a new version is found, **Check for Updates…** in the menu becomes **Update Available…**; click it to download, install and relaunch. Updates are verified with an EdDSA signature. Earlier versions need to be updated manually once.

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
appcast.xml           Sparkle update feed, generated by ./build.sh release
scripts/              make-icon.swift — regenerates Resources/AppIcon.icns
```

```bash
./build.sh            # development build → build/Caffy.app
./build.sh install    # build, install to /Applications and launch
```

Signing identities are selected by team. The default team is the maintainer's (`VTDBDK5H2X`); set `CAFFY_TEAM_ID` to your own Team ID to build with your certificates. Development builds use the team's Apple Development certificate, release builds its Developer ID Application certificate. The app and helper must be signed by the same team, because the helper only accepts connections from apps signed with its own Team ID.

### Releasing (Developer ID + notarization)

```bash
./build.sh release    # universal build → notarize & staple app → DMG → notarize & staple DMG → update appcast.xml
```

The Sparkle framework is downloaded to `build/deps/` on the first build (pinned version, SHA-256 verified).

One-time setup:

1. Create a **Developer ID Application** certificate for your team and install it in the keychain. Only the Account Holder can create one.
2. Store notarization credentials, either with an App Store Connect API key:
   ```bash
   xcrun notarytool store-credentials caffy-notary \
       --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```
   or with an Apple ID and an app-specific password: `--apple-id <Apple ID> --team-id <Team ID>`.
3. Have the Sparkle EdDSA private key matching `SUPublicEDKey` in `Resources/Info.plist` in your keychain. If the key is lost, installed copies can no longer be updated, so back it up: export with `build/deps/Sparkle-*/bin/generate_keys -x <file>` and import on another Mac with `-f <file>`.

The output is `build/Caffy-<version>.dmg`. The version comes from `CFBundleShortVersionString` in `Resources/Info.plist`, and `build.sh` copies it into the helper. Set `CAFFY_SKIP_NOTARIZE=1` to skip notarization when testing the packaging locally (the appcast then only goes to `build/appcast/` and the repo is left untouched).

To publish a release:

1. Bump the version in `Resources/Info.plist`. `CFBundleVersion` must increase, since Sparkle compares versions by it.
2. `CAFFY_RELEASE_NOTES=<notes.md> ./build.sh release`. The notes are shown in Sparkle's update window and are optional.
3. Create the GitHub release `v<version>` and upload the DMG.
4. Commit and push `appcast.xml`. Do this after uploading the DMG, or users will fail to download it.

`appcast.xml` is signed at the end of the file; don't edit it by hand.

### Troubleshooting

```bash
pmset -g | grep SleepDisabled                       # current state
# use the full path: zsh has a builtin named `log`
/usr/bin/log show --last 10m --info --predicate 'subsystem BEGINSWITH "com.caffy"'
sudo pmset -a disablesleep 0                         # restore sleep manually
```

## License

[MIT](LICENSE)
