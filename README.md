# Caffy

菜单栏小工具：阻止 MacBook 合盖后休眠。

原理是以 root 运行的 helper 执行 `pmset -a disablesleep 1/0`。普通的 `caffeinate` / IOPMAssertion 无法阻止合盖休眠。

## 结构

```
Sources/Shared/       XPC 协议、代码签名校验（两个目标共用）
Sources/Caffy/        菜单栏 App（SwiftUI MenuBarExtra）
Sources/CaffyHelper/  root 守护进程，通过 SMAppService.daemon 注册
Resources/            Info.plist、launchd plist
```

## 构建与安装

```bash
./build.sh            # 构建到 build/Caffy.app
./build.sh install    # 构建并安装到 /Applications，然后启动
```

签名证书按团队选择，默认团队是 `VTDBDK5H2X`（JIAYU CHEN），可以用 `CAFFY_TEAM_ID` 修改。开发构建自动选用该团队的 Apple Development 证书，发布构建自动选用该团队的 Developer ID Application 证书。
开发版和发布版必须属于同一团队：helper 只接受同一 Team ID 签名的 App 连接。

首次点击「开启防休眠」时会注册 helper，并打开「系统设置 › 通用 › 登录项与扩展」。在那里允许 Caffy 后，再点一次即可。

## 发布（Developer ID + 公证）

```bash
./build.sh release    # universal 构建 → 公证并 staple App → 打包 DMG → 公证并 staple DMG
```

一次性准备：

1. 在团队 `VTDBDK5H2X` 下创建 **Developer ID Application** 证书，并安装到钥匙串。只有 Account Holder 能创建，可以请对方导出 .p12 后再导入。
2. 保存公证凭据。可以复用 XPilot 的 App Store Connect API Key：
   ```bash
   xcrun notarytool store-credentials caffy-notary \
       --key ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
   ```
   也可以改用 Apple ID 加 App 专用密码：`--apple-id <Apple ID> --team-id VTDBDK5H2X`。

产物是 `build/Caffy-<版本>.dmg`。版本号取自 `Resources/Info.plist` 的 `CFBundleShortVersionString`。
设置 `CAFFY_SKIP_NOTARIZE=1` 可以跳过公证，只在本地验证打包流程。

## 安全机制

- App 退出、崩溃或被强杀后，XPC 连接断开，helper 会立即恢复休眠。
- helper 启动（包括开机）和被 launchd 停止时，都会复位为允许休眠。
- 可以设置定时（到时自动恢复）、过热保护和低电量保护（未接电源且电量低于阈值时自动恢复）。
- XPC 双向校验代码签名：对端必须是同一 Team ID 签名，且 bundle id 匹配。
- 覆盖安装新版本后，App 启动时比对 helper 的 cdhash，不一致就注销再注册，换成包内的新 helper。系统会保留之前的批准，无需再次允许。

## 排查

```bash
pmset -g | grep SleepDisabled                       # 当前状态
# zsh 有同名内置命令 log，必须写完整路径
/usr/bin/log show --last 10m --info --predicate 'subsystem BEGINSWITH "com.caffy"'
sudo pmset -a disablesleep 0                         # 手动恢复
```
