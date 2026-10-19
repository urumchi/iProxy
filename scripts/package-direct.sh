#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

build_dir="$project_dir/build"
archive_path="${ARCHIVE_PATH:-$build_dir/iProxy.xcarchive}"
product_dir="$build_dir/direct"
app_path="$product_dir/iProxy.app"
extension_relative="Contents/Library/SystemExtensions/org.mktime.hmccb.iProxy.ContentFilter.systemextension"
extension_path="$app_path/$extension_relative"
profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
team_id="HE98L3L35Z"

if [[ -z "${ARCHIVE_PATH:-}" ]]; then
    rm -rf "$archive_path"
    xcodebuild -quiet -project iProxy.xcodeproj -scheme iProxy -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$build_dir/DerivedData" \
        -archivePath "$archive_path" archive
fi

if [[ ! -d "$archive_path/Products/Applications/iProxy.app" ]]; then
    print -u2 "归档中找不到 iProxy.app：$archive_path"
    exit 1
fi

find_direct_profile() {
    local bundle_id="$1"
    local profile
    local best_profile=""
    local decoded
    local name
    local application_identifier
    local entitlements

    for profile in "$profile_dir"/*.provisionprofile; do
        [[ -e "$profile" ]] || continue
        decoded=$(openssl cms -inform der -verify -noverify -in "$profile" 2>/dev/null) || continue
        name=$(print -r -- "$decoded" | plutil -extract Name raw -o - - 2>/dev/null) || continue
        if [[ "$name" != "Mac Team Direct Provisioning Profile: $bundle_id" ]]; then
            continue
        fi
        application_identifier=$(print -r -- "$decoded" \
            | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - 2>/dev/null) || continue
        if [[ "$application_identifier" != "$team_id.$bundle_id" ]]; then
            continue
        fi
        entitlements=$(print -r -- "$decoded" | plutil -extract Entitlements json -o - - 2>/dev/null) || continue
        if [[ "$entitlements" != *"content-filter-provider-systemextension"* ]]; then
            continue
        fi
        if [[ -z "$best_profile" || "$profile" -nt "$best_profile" ]]; then
            best_profile="$profile"
        fi
    done

    if [[ -z "$best_profile" ]]; then
        return 1
    fi
    print -r -- "$best_profile"
}

if [[ -n "${MAIN_PROFILE:-}" ]]; then
    main_profile="$MAIN_PROFILE"
else
    main_profile=$(find_direct_profile org.mktime.hmccb.iProxy) || {
        print -u2 "找不到主 App 的 Mac Team Direct Provisioning Profile。"
        exit 1
    }
fi

if [[ -n "${EXTENSION_PROFILE:-}" ]]; then
    extension_profile="$EXTENSION_PROFILE"
else
    extension_profile=$(find_direct_profile org.mktime.hmccb.iProxy.ContentFilter) || {
        print -u2 "找不到系统扩展的 Mac Team Direct Provisioning Profile。"
        exit 1
    }
fi

identity_hash=$(security find-identity -v -p codesigning \
    | awk -v team="($team_id)" '/"Developer ID Application: / && index($0, team) { print $2; exit }')
if [[ -z "$identity_hash" ]]; then
    print -u2 "找不到属于团队 $team_id 的 Developer ID Application 签名身份。"
    exit 1
fi

rm -rf "$product_dir"
mkdir -p "$product_dir"
ditto "$archive_path/Products/Applications/iProxy.app" "$app_path"

cp "$main_profile" "$app_path/Contents/embedded.provisionprofile"
cp "$extension_profile" "$extension_path/Contents/embedded.provisionprofile"

codesign --force --timestamp --options runtime \
    --entitlements "$project_dir/ContentFilter/ContentFilter-Distribution.entitlements" \
    --sign "$identity_hash" "$extension_path"

codesign --force --timestamp --options runtime \
    --entitlements "$project_dir/iProxy/iProxy-Distribution.entitlements" \
    --sign "$identity_hash" "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"

main_entitlements=$(codesign -d --entitlements - "$app_path" 2>/dev/null)
extension_entitlements=$(codesign -d --entitlements - "$extension_path" 2>/dev/null)

if ! print -r -- "$main_entitlements" | grep -q "content-filter-provider-systemextension"; then
    print -u2 "主 App 的签名权限不包含 content-filter-provider-systemextension。"
    exit 1
fi
if ! print -r -- "$main_entitlements" | grep -q "HE98L3L35Z.org.mktime.hmccb.iProxy"; then
    print -u2 "主 App 的签名权限不包含正确的 application-identifier。"
    exit 1
fi
if ! print -r -- "$extension_entitlements" | grep -q "content-filter-provider-systemextension"; then
    print -u2 "系统扩展的签名权限不包含 content-filter-provider-systemextension。"
    exit 1
fi
if ! print -r -- "$extension_entitlements" | grep -q "HE98L3L35Z.org.mktime.hmccb.iProxy.ContentFilter"; then
    print -u2 "系统扩展的签名权限不包含正确的 application-identifier。"
    exit 1
fi
if print -r -- "$main_entitlements" | grep -q "get-task-allow"; then
    print -u2 "主 App 的签名权限不应包含 get-task-allow。"
    exit 1
fi
if print -r -- "$extension_entitlements" | grep -q "get-task-allow"; then
    print -u2 "系统扩展的签名权限不应包含 get-task-allow。"
    exit 1
fi

main_architectures=$(lipo -info "$app_path/Contents/MacOS/iProxy")
extension_architectures=$(lipo -info "$extension_path/Contents/MacOS/org.mktime.hmccb.iProxy.ContentFilter")
if [[ "$main_architectures" != *"x86_64"* || "$main_architectures" != *"arm64"* ]]; then
    print -u2 "主 App 不是 arm64 与 x86_64 的通用二进制。"
    exit 1
fi
if [[ "$extension_architectures" != *"x86_64"* || "$extension_architectures" != *"arm64"* ]]; then
    print -u2 "系统扩展不是 arm64 与 x86_64 的通用二进制。"
    exit 1
fi

zip_path="$build_dir/iProxy.zip"
dmg_path="$build_dir/iProxy.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$zip_path" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
fi

hdiutil create -volname iProxy -srcfolder "$app_path" -ov -format UDZO "$dmg_path"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$dmg_path" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl -a -vvv -t exec "$app_path"
    spctl -a -vvv -t open --context context:primary-signature "$dmg_path"
    print "已生成并公证：$dmg_path"
else
    print "已生成未公证产物：$zip_path 与 $dmg_path"
    print "公证后 Gatekeeper 才会放行。创建凭据后可用 NOTARY_PROFILE 重新执行："
    print "xcrun notarytool store-credentials iproxy-notary --apple-id <Apple ID> --team-id $team_id --password <App 专用密码>"
    print "NOTARY_PROFILE=iproxy-notary ./scripts/package-direct.sh"
fi
