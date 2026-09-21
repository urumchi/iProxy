# iProxy

macOS 应用级网络访问控制工具。列出本机应用，逐个开关该应用的网络访问。

当前已经跑通「最小闭环」：勾选某个应用 → 规则经 `NEFilterManager` 下发给 Content Filter 系统扩展 → 该应用新发起的网络连接被 `.drop()`；取消勾选即恢复。

```sh
xcodebuild -project iProxy.xcodeproj -scheme iProxy -configuration Debug \
  -derivedDataPath build build

# 系统扩展要求宿主 App 必须位于 /Applications
rm -rf /Applications/iProxy.app
ditto build/Build/Products/Debug/iProxy.app /Applications/iProxy.app
open /Applications/iProxy.app
```

**不要**直接从 `build/` 或 DerivedData 里运行 App，否则安装扩展会失败并报 `App containing System Extension to be activated must be in /Applications folder`。用 Xcode ⌘R 开发时同理：产物在 DerivedData 里，要从那里拷到 `/Applications` 再运行。每次重新构建后都要重新拷贝，拷贝前先退出正在运行的 iProxy，否则 LaunchServices 只会把旧实例调到前台。

`build/` 只是产物目录，建议加进 `.gitignore`（仓库目前还没有）。

## 首次使用需要授权

1. 从 `/Applications/iProxy.app` 启动，确认列表里出现应用。
2. 打开任意应用的「禁止联网」开关。第一次会触发系统扩展安装，App 顶部状态栏会提示。
3. 到「系统设置 → 通用 → 登录项与扩展」允许 iProxy 的扩展（可能需要管理员密码），随后系统会要求允许该内容过滤器。
4. 状态栏出现「已生效：N 个应用被禁止联网」即已生效。此时目标应用应无法联网，关掉开关后恢复。

调试日志：

```sh
log stream --predicate 'subsystem == "org.mktime.hmccb.iProxy"' --level info
```

## 工作原理

主 App 不参与判定，只负责下发规则和安装扩展：

1. `RuleStore` 把「Bundle ID → allow / drop」存成 JSON。
2. `FilterConfigurationService` 用 `OSSystemExtensionRequest` 安装扩展，再用 `NEFilterManager.saveToPreferences` 把规则写进 `NEFilterProviderConfiguration.vendorConfiguration`，并置 `isEnabled = true`、`filterSockets = true`。
3. 扩展进程 `FilterDataProvider` 在 `startFilter` 读取 `vendorConfiguration["rules"]`，之后由 KVO（加 2 秒兜底刷新）跟随配置变化。
4. 每条新 flow 到来时，用 `flow.sourceAppAuditToken` 反查进程身份：先用 `SecCodeCopyPath` 回溯到最外层 `.app` 取其 Bundle ID（这样 WPS 的 `promecefpluginhost`、各类 CEF / helper 都会归到用户勾选的那个 App），拿不到再退回进程自身的签名标识。命中规则返回 `.drop()`，否则 `.allow()`。macOS 上 `NEFilterFlow` 没有 iOS 的 `sourceAppIdentifier`，只有 audit token。
5. 取不到来源应用标识时一律放行（fail open），避免误伤系统流量。

主 App 与扩展都申请了 `com.apple.developer.networking.networkextension` 的 `content-filter-provider`；主 App 另外需要 `com.apple.developer.system-extension.install` 才能安装扩展。

## 已知限制

- 只按「应用」匹配：嵌套在 App 包内的辅助进程（WPS 的 `promecefpluginhost`、`cn.wps.wpscloudsvr` 等）靠回溯最外层 `.app` 归一，但 WebKit 这类宿主在 App 包之外的系统进程仍会漏判。
- fail open：拿不到 audit token 或签名标识的 flow 不会被拦截。
- 需要 Apple 签名与用户手动批准，未签名或本地 ad-hoc 构建无法启用扩展。

## 故障排查

- 列表为空：App Sandbox 可能挡住了 `/Applications` 枚举，可关掉主 App 的 App Sandbox，或改用 LaunchServices 列举。
- 停留在「扩展安装失败」：确认主 App 有 `system-extension.install`，签名是 Apple Development / Developer ID；若报错与 entitlement 有关，再把扩展的 entitlement 换成 `content-filter-provider-systemextension` 试一次。
- 报「must be in /Applications folder」：App 没放在 `/Applications`，按上面的运行步骤拷贝后重开。
- 报「require the presence of the 'NSSystemExtensionUsageDescription' property」：Info.plist 缺这个 key，主 App（`INFOPLIST_KEY_NSSystemExtensionUsageDescription` 构建设置）与扩展（`ContentFilter/Info.plist`）各需一份。
- 勾选后不生效：看日志。出现「当前拦截 N 个应用」说明扩展在跑且规则已到；只有「当前拦截 0 个应用」说明规则没下发；完全没有 provider 日志说明扩展未获批准或未运行。

## 规则存储

规则目前存在 App 沙箱容器内 `~/Library/Containers/org.mktime.hmccb.iProxy/Data/Library/Application Support/iProxy/rules.json`，便于先完成单机最小闭环；生产版可替换为 SQLite + App Group，并改为 provider 侧的可靠同步通道（见 `todo.md`）。
