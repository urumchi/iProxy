# 分发指南（App Store 之外）

iProxy 使用 `NEFilterDataProvider` 系统扩展，Developer ID 分发需要正确的网络扩展权限、Direct 配置描述文件、公证和票据装订。仓库里的 `scripts/package-direct.sh` 已经把归档、重签、校验、zip 和 dmg 生成串成一条可重复执行的流程。

## 权限值差异

`com.apple.developer.networking.networkextension` 在两种签名方式下使用不同的值：

| 签名方式 | 权限值 | 配置描述文件 |
| --- | --- | --- |
| 开发签名 | `content-filter-provider` | `Mac Team Provisioning Profile` |
| Developer ID 分发 | `content-filter-provider-systemextension` | `Mac Team Direct Provisioning Profile` |

主 App 还需要 `com.apple.developer.system-extension.install`，用于安装系统扩展。主 App 的沙盒和用户选择文件只读权限写在 `iProxy/iProxy-Distribution.entitlements` 中，系统扩展的沙盒权限写在 `ContentFilter/ContentFilter-Distribution.entitlements` 中。两个文件还显式写入 `com.apple.application-identifier` 与 `com.apple.developer.team-identifier`，与 Direct 配置描述文件中的值一致。

报错

```text
Provisioning profile "Mac Team Direct Provisioning Profile: org.mktime.hmccb.iProxy.ContentFilter"
doesn't match the entitlements file's value for the com.apple.developer.networking.networkextension entitlement.
```

的原因是归档产物仍然写着 `content-filter-provider`，而 Direct 配置描述文件只授予 `content-filter-provider-systemextension`。Xcode 在导出阶段逐个比较这两组值，遇到不一致就停止。

工程的 Debug 与 Release 继续使用开发用 entitlements，保证日常运行和归档正常。Developer ID 专用 entitlements 只在打包脚本重签阶段使用。

## 打包

先确认本机钥匙串中有当前团队的 `Developer ID Application` 证书及私钥：

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

执行：

```sh
cd /Users/apple/Documents/iProxy
./scripts/package-direct.sh
```

脚本依次完成：

1. 用 Release 配置归档，产物包含 arm64 与 x86_64。
2. 从归档复制出独立的 `iProxy.app` 到 `build/direct/`。
3. 把两个 Mac Team Direct 配置描述文件分别嵌入主 App 和系统扩展。
4. 先用 `ContentFilter-Distribution.entitlements` 重签系统扩展，再用 `iProxy-Distribution.entitlements` 重签主 App。
5. 校验签名、权限值、通用架构以及 `get-task-allow` 是否存在。
6. 生成 `build/iProxy.zip` 与 `build/iProxy.dmg`。

输出位置：

```text
build/direct/iProxy.app
build/iProxy.zip
build/iProxy.dmg
```

Xcode 的自动签名会把归档签成开发签名。Direct 配置描述文件由 Xcode 管理，Xcode 的手动签名模式会拒绝使用它们；`codesign` 可以直接使用这些配置描述文件完成 Developer ID 重签。因此发布产物由脚本生成，Organizer 中的 Direct Distribution 导出步骤不再作为发布路径。

如果已经在 Xcode 中完成归档，可以让脚本复用现有归档：

```sh
ARCHIVE_PATH="$HOME/Library/Developer/Xcode/Archives/2026-10-19/iProxy 2026-10-19, 17.16.xcarchive" \
  ./scripts/package-direct.sh
```

脚本按名称查找 `Mac Team Direct Provisioning Profile: <bundle id>`，并检查配置描述文件中的 `application-identifier` 与 `content-filter-provider-systemextension`。需要指定其他配置描述文件时，使用 `MAIN_PROFILE` 与 `EXTENSION_PROFILE` 环境变量。

## 公证

没有公证的 Developer ID 产物会被 Gatekeeper 拒绝，`spctl` 会显示 `Unnotarized Developer ID`。先保存 notarytool 凭据：

```sh
xcrun notarytool store-credentials iproxy-notary \
  --apple-id <Apple ID> \
  --team-id HE98L3L35Z \
  --password <App 专用密码>
```

再执行完整打包与公证：

```sh
NOTARY_PROFILE=iproxy-notary ./scripts/package-direct.sh
```

脚本会先提交 zip 并装订 App 的票据，然后用已装订的 App 重新生成 zip 和 dmg，再提交 dmg 并装订 dmg 的票据。完成后的校验命令：

```sh
xcrun stapler validate build/direct/iProxy.app
xcrun stapler validate build/iProxy.dmg
spctl -a -vvv -t exec build/direct/iProxy.app
spctl -a -vvv -t open --context context:primary-signature build/iProxy.dmg
shasum -a 256 build/iProxy.dmg
```

## 脚本中的关键签名命令

需要排查签名问题时，可以按下面的顺序手工执行。两个 `codesign` 的顺序不能交换，系统扩展必须先完成签名。

```sh
codesign --force --timestamp --options runtime \
  --entitlements ContentFilter/ContentFilter-Distribution.entitlements \
  --sign "Developer ID Application: <证书名称>" \
  build/direct/iProxy.app/Contents/Library/SystemExtensions/org.mktime.hmccb.iProxy.ContentFilter.systemextension

codesign --force --timestamp --options runtime \
  --entitlements iProxy/iProxy-Distribution.entitlements \
  --sign "Developer ID Application: <证书名称>" \
  build/direct/iProxy.app

codesign --verify --deep --strict --verbose=2 build/direct/iProxy.app
```

## 用户安装

1. 把 `iProxy.app` 放进 `/Applications`。系统扩展要求宿主 App 位于这个目录，放在其他位置会激活失败。
2. 首次启动后勾选某个应用的「禁止联网」，触发系统扩展安装。
3. 到「系统设置 → 通用 → 登录项与扩展」批准 iProxy 的扩展，可能需要管理员密码。
4. 状态栏出现「已生效：N 个应用被禁止联网」后再验证目标应用是否被阻断。
5. 升级版本后，系统扩展可能需要重新批准一次。

## 发布前检查

- `security find-identity -v -p codesigning` 能看到当前团队的 `Developer ID Application`。
- `Mac Team Direct Provisioning Profile` 的主 App 与系统扩展配置描述文件都存在且未过期。
- `lipo -info` 显示主 App 与系统扩展都包含 `arm64` 和 `x86_64`。
- 签名权限包含 `content-filter-provider-systemextension`，并且没有 `get-task-allow`。
- App 与 dmg 都完成公证，`stapler validate` 与 `spctl` 校验通过。
- 下载页给出 dmg 的 SHA-256 校验值。

当前工程的 `MACOSX_DEPLOYMENT_TARGET = 13.0`。主 App 和系统扩展都是 `arm64` 和 `x86_64` 通用二进制，支持能运行 macOS 13.0 及以上的 Apple Silicon Mac 和 Intel Mac。Intel Mac 的最低系统版本同样是 macOS 13.0；macOS 12 及更早版本不能启动这个产物。Intel Mac 上的系统扩展安装、批准和网络拦截流程仍需要在真实 Intel 机器上回归一次。
