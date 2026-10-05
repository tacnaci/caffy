# Caffy

[English](README.md) | 简体中文

一个 macOS 菜单栏小工具：让 MacBook 合上盖子后也不休眠，编译、下载、AI 编程助手等耗时任务可以继续运行。

`caffeinate` 这类工具只能阻止**空闲**休眠。合上盖子后，除非同时接着电源**和**外接显示器，Mac 仍然会休眠。Caffy 直接切换系统级的 `SleepDisabled` 设置，合盖休眠也能阻止。

## 下载

从 [Releases](https://github.com/tacnaci/caffy/releases/latest) 下载最新的 `Caffy-<版本>.dmg`。App 使用 Developer ID 签名，并已通过 Apple 公证。

需要 macOS 13 或更高版本，同时支持 Apple Silicon 和 Intel。

## 使用

1. 打开 DMG，把 Caffy 拖进「应用程序」文件夹，然后启动。菜单栏会出现一个杯子图标。
2. 点杯子图标 › **开启防休眠**。
3. 第一次开启时，系统会打开「系统设置 › 通用 › 登录项与扩展」。在那里允许 Caffy 在后台运行，然后再开启一次。

防休眠开启期间，图标会变成实心的杯子。

菜单选项：

| 选项 | 说明 |
|---|---|
| 开启时长 | 30 分钟 / 1 / 2 / 4 小时 / 不限时，到时自动恢复休眠。修改后立即生效，从开启时刻起算。 |
| 过热时自动恢复休眠 | 设备温度过高时恢复休眠，默认开启。 |
| 低电量时自动恢复休眠 | 未接电源且电量低于阈值（10 / 20 / 30 / 50%）时恢复休眠，默认开启，阈值 20%。 |
| 防休眠期间运行 | 防休眠开启期间运行你指定的命令，比如用于远程访问的隧道。详见[防休眠期间运行](#防休眠期间运行)。 |
| 登录时启动 | 登录系统时自动启动 Caffy。 |
| 自动检查更新 | 每天检查一次新版本，默认开启。也可以随时点「检查更新…」手动检查。 |
| 辅助程序 | 安装或卸载后台辅助程序。 |

> ⚠️ 合盖不休眠时，不要把电脑放进密闭的包里，以免过热。

### 防休眠期间运行

Caffy 可以在防休眠开启期间让一条命令保持运行，比如一个隧道，让你合盖后也能用手机连回 Mac。菜单 › **防休眠期间运行** › **设置命令…**，像在终端里一样输入命令：

```
cd ~/frp && frpc -c frpc.toml
```

- 命令通过 `/bin/zsh -c` 以当前用户身份运行，不经过 root 辅助程序。`PATH` 中会补上 Homebrew 的 `bin` 目录，工作目录是用户主目录。
- 开启防休眠时启动；防休眠因任何原因关闭（手动关闭、到时、低电量、过热）时停止。Caffy 会结束整个进程组，命令派生的子进程也会一起停止。
- 命令自行退出时，Caffy 会依次等待 1、2、4 … 秒（最长 60 秒）后重启。适合长期运行的命令，不适合一次性脚本。
- 输出写入 `~/Library/Logs/Caffy/run-while-awake.log`（仅本人可读，超过 1 MB 轮转）。**查看日志**会用「控制台」打开它。命令本身会写进日志，密钥等凭据请放在配置文件里，不要写在命令行上。
- 脚本和配置文件不要放在「桌面」「文稿」「下载」里（可以放在 `~/.config` 下），否则系统可能会弹窗请求访问权限。

> ⚠️ 隧道会把 Mac 的端口暴露到公网。只暴露关闭了密码登录（`PasswordAuthentication no` 与 `KbdInteractiveAuthentication no`）的 SSH，屏幕共享通过 SSH 隧道访问。不要直接暴露屏幕共享的 5900 端口。

界面支持简体中文和英文，跟随系统语言。

## 工作原理

修改 `SleepDisabled`（`pmset -a disablesleep 1`）需要 root 权限，所以 Caffy 分成两部分：

```
Caffy.app（菜单栏，以当前用户身份运行） ──XPC──▶ CaffyHelper（launchd 守护进程，以 root 运行）
                                                      └─ pmset -a disablesleep 1 / 0
```

- 辅助程序打包在 `Caffy.app` 里，通过 `SMAppService.daemon` 注册。它只提供"开启或关闭防休眠"和"报告自身代码标识"两个功能。
- XPC 通信时双方互相校验代码签名：对端必须是同一 Team ID 签名、bundle id 也匹配，其他进程无法借用辅助程序。

### 安全机制

- App 退出、崩溃或被强杀时，XPC 连接断开，辅助程序会立即恢复休眠。
- 辅助程序启动（包括开机）和被 launchd 停止时，也会恢复休眠。崩溃或断电不会让 Mac 一直保持唤醒。
- 覆盖安装新版本后，App 会比对正在运行的辅助程序和包内辅助程序的 cdhash。不一致就注销再注册，换成新版辅助程序。系统会保留之前的批准，无需再次允许。

## 更新

1.0.3 起 Caffy 通过 [Sparkle](https://sparkle-project.org) 自动更新：发现新版本时菜单中的「检查更新…」会变成「有可用更新…」，点击即可下载安装并重启。更新包经过 EdDSA 签名校验。更早的版本需要手动下载一次新版。

## 常见问题

**怎么彻底卸载？**
菜单 › 辅助程序 › 卸载辅助程序，然后退出 Caffy，再从「应用程序」中删除。

**卸载 Caffy 后 Mac 还是不休眠？**
运行 `sudo pmset -a disablesleep 0`。

## 从源码构建

需要 Xcode（Swift 5.9 或更高）和 Apple Development 证书，因为 `SMAppService` 守护进程必须由正确签名的 App 注册才能运行。不需要 Xcode 工程，`build.sh` 直接调用 `swiftc`、`codesign` 和公证工具。

```
Sources/Shared/       XPC 协议、代码签名工具（两个目标共用）
Sources/Caffy/        菜单栏 App（SwiftUI MenuBarExtra）
Sources/CaffyHelper/  root 守护进程，通过 SMAppService.daemon 注册
Resources/            Info.plist、launchd plist、App 图标
appcast.xml           Sparkle 更新源，由 build.sh release 生成
scripts/              make-icon.swift：重新生成 Resources/AppIcon.icns
```

```bash
./build.sh            # 开发构建 → build/Caffy.app
./build.sh install    # 构建并安装到 /Applications，然后启动
```

签名证书按团队选择。默认团队是维护者的团队（`VTDBDK5H2X`），用你自己的证书构建时，把 `CAFFY_TEAM_ID` 设为你的 Team ID。开发构建使用该团队的 Apple Development 证书，发布构建使用该团队的 Developer ID Application 证书。App 和辅助程序必须由同一团队签名，因为辅助程序只接受同一 Team ID 签名的 App 连接。

### 发布（Developer ID + 公证）

```bash
./build.sh release    # universal 构建 → 公证并 staple App → 打包 DMG → 公证并 staple DMG → 更新 appcast.xml
```

Sparkle 框架在首次构建时自动下载到 `build/deps/`（固定版本并校验 SHA-256）。

一次性准备：

1. 为你的团队创建 **Developer ID Application** 证书，并安装到钥匙串。只有 Account Holder 能创建。
2. 保存公证凭据，可以用 App Store Connect API Key：
   ```bash
   xcrun notarytool store-credentials caffy-notary \
       --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```
   也可以用 Apple ID 加 App 专用密码：`--apple-id <Apple ID> --team-id <Team ID>`。
3. 钥匙串中要有 Sparkle 的 EdDSA 私钥，与 `Resources/Info.plist` 的 `SUPublicEDKey` 对应。私钥丢失后已安装的 App 将无法再收到更新，务必备份：`build/deps/Sparkle-*/bin/generate_keys -x <文件>` 导出，换机器时用 `-f <文件>` 导入。

产物是 `build/Caffy-<版本>.dmg`。版本号取自 `Resources/Info.plist` 的 `CFBundleShortVersionString`，`build.sh` 会同步写入辅助程序。设置 `CAFFY_SKIP_NOTARIZE=1` 可以跳过公证，只在本地验证打包流程（appcast 只生成到 `build/appcast/`，不改动仓库中的文件）。

发布流程：

1. 修改 `Resources/Info.plist` 中的版本号，`CFBundleVersion` 必须递增（Sparkle 用它比较新旧）。
2. `CAFFY_RELEASE_NOTES=<更新说明.md> ./build.sh release`。更新说明会显示在 Sparkle 的更新窗口中，可省略。
3. 创建 GitHub Release `v<版本>` 并上传 DMG。
4. 提交并推送 `appcast.xml`。必须在 DMG 上传之后，否则用户会下载失败。

`appcast.xml` 末尾带有签名，不要手动修改。

### 排查

```bash
pmset -g | grep SleepDisabled                       # 当前状态
# 必须写完整路径：zsh 有同名内置命令 log
/usr/bin/log show --last 10m --info --predicate 'subsystem BEGINSWITH "com.caffy"'
sudo pmset -a disablesleep 0                         # 手动恢复休眠
```

## 许可证

[MIT](LICENSE)
