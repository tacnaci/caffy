#!/bin/bash
# 构建 Caffy.app
#   ./build.sh            开发构建（Apple Development 签名，本机架构）→ build/Caffy.app
#   ./build.sh install    开发构建并安装到 /Applications/Caffy.app
#   ./build.sh release    发布构建（Developer ID 签名，universal，公证）→ build/Caffy-<版本>.dmg
#
# 环境变量：
#   CAFFY_TEAM_ID           签名所属团队，默认 VTDBDK5H2X（JIAYU CHEN）。开发版与发布版须同一团队，
#                           否则 App 与 helper 的 XPC 签名校验对不上
#   CAFFY_SIGN_IDENTITY     开发签名证书（名称或 SHA-1），默认取该团队的 Apple Development 证书
#   CAFFY_RELEASE_IDENTITY  发布签名证书，默认取该团队的 Developer ID Application 证书
#   CAFFY_NOTARY_PROFILE    notarytool 钥匙串凭据名，默认 caffy-notary
#   CAFFY_SKIP_NOTARIZE=1   发布构建时跳过公证（仅用于本地验证打包流程）
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
BUILD="$ROOT/build"
APP="$BUILD/Caffy.app"
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Resources/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist)
MODE="${1:-dev}"
TEAM_ID="${CAFFY_TEAM_ID:-VTDBDK5H2X}"

# find_identity <证书类型>：输出 TEAM_ID 团队下该类型第一个有效证书的 SHA-1
find_identity() {
    local hash name
    while IFS=$'\t' read -r hash name; do
        local team
        team=$(security find-certificate -a -Z -p -c "$name" \
            | awk -v h="$hash" '/^SHA-1 hash:/ {keep = ($3 == h); next} keep && /BEGIN/ {p = 1} p {print} /END/ {p = 0}' \
            | openssl x509 -noout -subject 2>/dev/null \
            | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$')
        if [[ "$team" == "$TEAM_ID" ]]; then
            echo "$hash"
            return
        fi
    done < <(security find-identity -v -p codesigning \
        | awk -F'"' -v kind="$1" '$2 ~ kind {split($1, f, " "); print f[2] "\t" $2}')
}

# 证书 SHA-1 转为名称用于显示；传入的本来就是名称时原样输出
identity_name() {
    local name
    name=$(security find-identity -v -p codesigning | awk -F'"' -v h="$1" '$1 ~ h {print $2; exit}')
    echo "${name:-$1}"
}

# compile <module> <output> <arch...> -- <swiftc 额外参数...>
compile() {
    local module=$1 output=$2; shift 2
    local archs=()
    while [[ $1 != "--" ]]; do archs+=("$1"); shift; done
    shift
    local slices=()
    for arch in "${archs[@]}"; do
        local slice="$BUILD/obj/$module-$arch"
        mkdir -p "$BUILD/obj"
        swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" -module-name "$module" "$@" -o "$slice"
        slices+=("$slice")
    done
    lipo -create "${slices[@]}" -output "$output"
}

build_app() {
    local identity=$1 timestamp=$2; shift 2
    local archs=("$@")

    rm -rf "$APP" "$BUILD/obj"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

    # helper 的版本号与 App 保持一致（Resources/Info.plist 为唯一来源）
    local helper_plist="$BUILD/Helper-Info.plist"
    cp Resources/Helper-Info.plist "$helper_plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" \
        -c "Add :CFBundleVersion string $BUILD_NUMBER" "$helper_plist"

    echo "==> 编译 CaffyHelper（${archs[*]}）"
    compile CaffyHelper "$APP/Contents/MacOS/CaffyHelper" "${archs[@]}" -- \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$helper_plist" \
        Sources/Shared/*.swift Sources/CaffyHelper/*.swift

    echo "==> 编译 Caffy（${archs[*]}）"
    compile Caffy "$APP/Contents/MacOS/Caffy" "${archs[@]}" -- \
        -parse-as-library Sources/Shared/*.swift Sources/Caffy/*.swift

    cp Resources/Info.plist "$APP/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
    cp Resources/com.caffy.helper.plist "$APP/Contents/Library/LaunchDaemons/"

    echo "==> 签名（$(identity_name "$identity")）"
    codesign --force --options runtime "$timestamp" \
        --identifier com.caffy.helper --sign "$identity" "$APP/Contents/MacOS/CaffyHelper"
    codesign --force --options runtime "$timestamp" \
        --sign "$identity" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "==> 构建完成：$APP"
}

notarize() {
    local path=$1
    echo "==> 公证 $(basename "$path")（通常需要几分钟）"
    local output id
    output=$(xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
    # 被拒（Invalid）时 notarytool 退出码仍为 0，需要自行判断
    if ! grep -q 'status: Accepted' <<<"$output"; then
        id=$(awk '/^ *id:/ {print $2; exit}' <<<"$output")
        echo "公证未通过，日志如下：" >&2
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
    # zip 只是上传载体，无法 staple；票据由调用方 staple 到解压前的 App 上
    if [[ "$path" != *.zip ]]; then
        xcrun stapler staple "$path"
    fi
}

case "$MODE" in
dev | install)
    IDENTITY="${CAFFY_SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
    if [[ -z "$IDENTITY" ]]; then
        echo "未找到团队 $TEAM_ID 的 Apple Development 证书，SMAppService 需要有效签名" >&2
        exit 1
    fi
    build_app "$IDENTITY" --timestamp=none "$(uname -m)"

    if [[ "$MODE" == "install" ]]; then
        DEST=/Applications/Caffy.app
        osascript -e 'tell application id "com.caffy.app" to quit' >/dev/null 2>&1 || true
        # 等旧进程真正退出再替换，否则 open 可能只是激活仍在运行的旧实例
        for _ in $(seq 1 50); do
            pgrep -x Caffy >/dev/null || break
            sleep 0.2
        done
        if pgrep -x Caffy >/dev/null; then
            pkill -x Caffy || true
            sleep 0.5
        fi
        rm -rf "$DEST"
        # 旧 helper 若仍在运行，App 启动时会检测到版本不一致并自动替换
        cp -R "$APP" "$DEST"
        echo "==> 已安装到 $DEST"
        open "$DEST"
    fi
    ;;

release)
    IDENTITY="${CAFFY_RELEASE_IDENTITY:-$(find_identity 'Developer ID Application')}"
    NOTARY_PROFILE="${CAFFY_NOTARY_PROFILE:-caffy-notary}"
    SKIP_NOTARIZE="${CAFFY_SKIP_NOTARIZE:-0}"
    if [[ -z "$IDENTITY" ]]; then
        echo "未找到团队 $TEAM_ID 的 Developer ID Application 证书，请先在 developer.apple.com 创建并安装到钥匙串" >&2
        exit 1
    fi
    if [[ "$SKIP_NOTARIZE" != 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "未找到公证凭据 \"$NOTARY_PROFILE\"，请先执行：" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <Team ID>" >&2
        exit 1
    fi

    build_app "$IDENTITY" --timestamp arm64 x86_64

    # 先公证并 staple App 本身，这样从 DMG 拷出来后离线也能通过 Gatekeeper
    if [[ "$SKIP_NOTARIZE" != 1 ]]; then
        ZIP="$BUILD/Caffy.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"
        notarize "$ZIP"
        rm "$ZIP"
        xcrun stapler staple "$APP"
    fi

    echo "==> 打包 DMG"
    DMG="$BUILD/Caffy-$VERSION.dmg"
    STAGING="$BUILD/dmg"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -quiet -volname "Caffy" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
    rm -rf "$STAGING"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"

    if [[ "$SKIP_NOTARIZE" != 1 ]]; then
        notarize "$DMG"
        echo "==> Gatekeeper 校验"
        spctl --assess --type execute --verbose "$APP"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    else
        echo "提示：已跳过公证，此 DMG 仅供本地验证"
    fi
    echo "==> 发布包：$DMG"
    ;;

*)
    echo "用法：$0 [dev|install|release]" >&2
    exit 1
    ;;
esac
