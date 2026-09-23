# 分发指南（App Store 之外）

iProxy 可以不经 App Store 审核，用 Developer ID 签名 + 公证后直接发布给用户下载。但本 App 内嵌了 `NEFilterDataProvider` 系统扩展，整套流程和普通 App 有本质区别，下面的顺序不要跳过。

## 0. 关键卡点：受限权限的授权范围

两个 entitlement 属于 Apple 的受限权限，必须由 Apple 授权后才能签名使用：

- `com.apple.developer.networking.networkextension` = `content-filter-provider`（主 App 与扩展都要）
- `com.apple.developer.system-extension.install`（主 App 需要，用于安装扩展）

**App Store 分发和 Developer ID 分发是两条独立的授权线。** 本地开发能跑只说明开发用 provisioning profile 里有这两项权限，不代表 Developer ID 线已开通。走这条路之前先通过 Apple 的 entitlement 申请流程确认 Developer ID 权限已获批，再生成对应的 Developer ID provisioning profile。这是整个方案能否成立的唯一前置条件，其余步骤都建立在它之上。

## 1. 签名准备

加入 Apple Developer Program，然后在 Xcode > Settings > Accounts > Manage Certificates 里创建：

- **Developer ID Application**：签主 App 和系统扩展本体。
- **Developer ID Installer**：仅在制作 `.pkg` 时需要。

当前工程 `DEVELOPMENT_TEAM = HE98L3L35Z`、`CODE_SIGN_STYLE = Automatic`、`ENABLE_HARDENED_RUNTIME = YES`。加固运行时是公证的前置条件，已满足，无需改动。

### 显式声明 entitlements

注意一个容易被忽略的差异：`iProxy/iProxy.entitlements` 里只有上面两项，但当前签名产物里还带了 `com.apple.security.app-sandbox` 和 `com.apple.security.files.user-selected.read-only`——这两项是随开发用 provisioning profile 一起进来的。

Developer ID 的 profile 不会自动补这两项，所以要在 entitlements 文件里显式写清楚真正需要的权限，否则换成 Developer ID 签名后沙盒行为会变，文件访问可能直接被拒。

## 2. 出包

必须走归档流程，不要直接分发 Debug 产物（Debug 带 `get-task-allow`，且 `ONLY_ACTIVE_ARCH = YES` 只出 arm64）。

```sh
cd /Users/apple/Documents/iProxy

xcodebuild -project iProxy.xcodeproj -scheme iProxy \
  -configuration Release -destination 'platform=macOS' \
  -archivePath build/iProxy.xcarchive archive
```

导出用的 `ExportOptions.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>HE98L3L35Z</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
```

```sh
xcodebuild -exportArchive -archivePath build/iProxy.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export
```

图形界面等价操作：scheme 切到 Release → Product > Archive → Organizer → Distribute App → **Developer ID** → 勾选上传公证 → Export。

### 分发载体

推荐 `.dmg`（用户拖进 `/Applications`），做 `.pkg` 则需 Developer ID Installer 签名，裸 `.app` 打 zip 也可以：

```sh
hdiutil create -volname iProxy -srcfolder build/export/iProxy.app \
  -ov -format UDZO build/iProxy.dmg

ditto -c -k --sequesterRsrc --keepParent build/export/iProxy.app build/iProxy.zip
```

## 3. 公证与 staple

不公证的话，用户下载后会被 Gatekeeper 拦下提示「无法验证开发者」。先用 App 专用密码或 App Store Connect API Key 存一份 notarytool 凭据：

```sh
xcrun notarytool store-credentials "iproxy-notary" \
  --apple-id <你的 Apple ID> \
  --team-id HE98L3L35Z \
  --password <App 专用密码>
```

顺序是「先公证 app 并钉票据，再做 dmg 并对 dmg 本身公证 + staple」。两段都做最稳妥，只钉 dmg 的话用户离线时可能校验不过。

```sh
# 1. 公证 app，把票据钉进 app 本体
xcrun notarytool submit build/iProxy.zip --keychain-profile iproxy-notary --wait
xcrun stapler staple build/export/iProxy.app

# 2. 用已钉票据的 app 做 dmg，再公证 + 钉票据
hdiutil create -volname iProxy -srcfolder build/export/iProxy.app \
  -ov -format UDZO build/iProxy.dmg
xcrun notarytool submit build/iProxy.dmg --keychain-profile iproxy-notary --wait
xcrun stapler staple build/iProxy.dmg
```

验证：

```sh
xcrun stapler validate build/iProxy.dmg
spctl -a -vvv -t install build/iProxy.dmg
spctl -a -vvv -t exec /Applications/iProxy.app
```

## 4. 架构与部署目标

两项配置会直接决定有多少人装得上：

- `MACOSX_DEPLOYMENT_TARGET = 26.5` 会把用户限制在 macOS 26.5 及以上，受众极小。NetworkExtension 的 API 本身不新，部署目标大概率能下调很多，改完回归一遍拦截逻辑即可。
- Debug 配了 `ONLY_ACTIVE_ARCH = YES`，产物是 thin arm64，Intel Mac 跑不了。Release 归档默认标准架构（arm64 + x86_64），归档后用 `lipo -info` 确认：

```sh
lipo -info build/export/iProxy.app/Contents/MacOS/iProxy
codesign -d --entitlements - build/export/iProxy.app   # 确认没有 get-task-allow
```

## 5. 用户侧安装体验

装完不等于生效，这几点必须写进下载页的说明，否则反馈区会全是「没起作用」：

1. 把 `iProxy.app` 放进 `/Applications`（系统扩展要求宿主 App 位于稳定位置，否则激活会失败并报 `App containing System Extension to be activated must be in /Applications folder`）。
2. 首次启动后触发系统扩展激活请求，App 顶部状态栏会提示。
3. 到「系统设置 → 通用 → 登录项与扩展」手动批准 iProxy 的扩展，可能需要管理员密码。
4. 允许内容过滤器后，状态栏出现「已生效：N 个应用被禁止联网」才算成功。
5. 升级到新版本时，系统扩展可能还需要重新批准一次。

## 6. 托管与自动更新

GitHub Releases 或对象存储（Cloudflare R2、S3）都可以，下载页给出 SHA-256 校验值：

```sh
shasum -a 256 build/iProxy.dmg
```

自动更新用 Sparkle（EdDSA 签名 + 托管 `appcast.xml`）。注意更新会把内嵌的系统扩展一起替换，更新逻辑要覆盖扩展版本，并提示用户可能需重新授权。

## 7. 发版检查清单

- [ ] Developer ID 线的 entitlement 授权已确认，Developer ID provisioning profile 可用
- [ ] `iProxy.entitlements` 已显式声明需要的沙盒权限
- [ ] Release 配置归档，产物为 universal（arm64 + x86_64）
- [ ] 签名 Entitlements 无 `get-task-allow`
- [ ] app 与 dmg 均已完成公证并 staple
- [ ] `spctl` 校验通过
- [ ] 下载页写明 `/Applications` 安装位置与系统扩展批准步骤
- [ ] 已发布 SHA-256 校验值
