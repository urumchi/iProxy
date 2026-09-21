我想实现一个macOS系统下的网络控制工具。它可以：
1、获取应用列表，可以开启/关闭这个应用的网络访问功能。

参考的系统架构：
Core:
    Swift
Network:
    NetworkExtension
    NEFilterDataProvider
    NEFilterControlProvider
Process:
    Endpoint Security
辅助诊断:
    lsof
    nettop
Rule DB:
    SQLite
UI:
    SwiftUI
架构：
                  ┌──────────────────────┐
                  │       SwiftUI        │
                  │                      │
                  │ Apps / Connections   │
                  │ Rules / Logs         │
                  └──────────┬───────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Rule Engine    │
                    │                 │
                    │ App             │
                    │ Process         │
                    │ IP              │
                    │ Domain          │
                    │ Port            │
                    └───────┬─────────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
              ▼                           ▼
      Network Extension             Endpoint Security
              │                           │
              │                           │
       Network Flow                  Process Events
              │                           │
              └─────────────┬─────────────┘
                            ▼
                     Identity Manager
十七、最终可以实现成类似这样的 UI
┌─────────────────────────────────────────────────────────┐
│ Network Monitor                              ON ●       │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ 🟢 Safari                                              │
│    com.apple.Safari                                    │
│    └── 17.57.xxx.xxx:443                               │
│        HTTPS · 128 KB ↓ · 32 KB ↑                       │
│                                                         │
│ 🔴 Chrome                                               │
│    com.google.Chrome                                   │
│    ├── 142.250.xxx.xxx:443                             │
│    ├── 1.2.3.4:443                                     │
│    └── 8.8.8.8:53                                      │
│                                                         │
│ 🟢 MyApp                                                │
│    com.example.myapp                                   │
│    └── api.example.com:443                             │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ Rules                                                   │
│                                                         │
│ Chrome        Internet       BLOCK                     │
│ MyApp         api.foo.com   ALLOW                     │
│ MyApp         10.0.0.1      ALLOW                     │
└─────────────────────────────────────────────────────────┘
点击：
Chrome
   ↓
Block Internet
实际上就是：
Rule:
application = com.google.Chrome
action      = drop
之后新的 network flow 到达：
NEFilterDataProvider
        ↓
Chrome?
        ↓
YES
        ↓
DROP
最关键的结论
如果你的目标是**“现代 macOS 上做一个真正的 App 级网络防火墙”**：
              不推荐
                 │
        ┌────────┴────────┐
        │                 │
      pfctl             kill
        │                 │
        └────────┬────────┘
                 │
                 ▼
             不够完整

                 ↓

              推荐
                 │
       Network Extension
                 │
        NEFilterDataProvider
                 │
       ┌─────────┴─────────┐
       │                   │
    observe              block
       │                   │
       ▼                   ▼
   App/Flow             allow/drop
而如果要把**“App、多个 Helper 进程、进程生命周期、网络连接”**全部关联起来：
Network Extension
       +
Endpoint Security
       +
App Identity
       +
Rule Engine
是更完整的现代 macOS 架构。Apple 当前的 Network Extension entitlement 也明确包含 content-filter-provider，用于允许/拒绝其他 App 创建的网络连接；system extension 形式也有对应的 content-filter-provider-systemextension。

---

## 进度与待办

### 已完成：最小闭环（App 级网络开 / 关）

- [x] Content Filter System Extension target 保留并修正配置：`NetworkExtension → NEProviderClasses → com.apple.networkextension.filter-data` 指向 `FilterDataProvider`。
- [x] 扩展 entitlement 收敛为 `content-filter-provider`；入口 `main.swift` 只用 `NEProvider.startSystemExtensionMode()` + `dispatchMain()`。
- [x] 主 App 增加 Network Extensions capability 与 `iProxy.entitlements`（`content-filter-provider` + `system-extension.install`）。
- [x] `FilterConfigurationService` 用 `OSSystemExtensionRequest` 安装扩展，再把规则写进 `vendorConfiguration` 并启用过滤器。
- [x] `FilterDataProvider` 读取规则并判定：`sourceAppAuditToken` → `SecCodeCopyGuestWithAttributes` → 代码签名标识 → `.drop()` / `.allow()`。
- [x] 规则热更新：`filterConfiguration` 的 KVO + 2 秒兜底刷新。
- [x] `RuleStore` 持久化、UI 开关、状态栏提示、`os.Logger` 日志（subsystem `org.mktime.hmccb.iProxy`）。
- [x] 构建通过、签名含预期 entitlements、扩展已内嵌到 `Contents/Library/SystemExtensions`。

### 待验证（需要在真机上点一遍）

- [ ] 首次勾选时扩展能装成功并获批准；状态栏走到「已生效」。
- [ ] 目标应用确实断网，取消勾选后恢复。
- [ ] 若扩展加载被拒，把扩展 entitlement 换成 `content-filter-provider-systemextension` 再试。
- [ ] 确认规则变更后扩展能在不重启的情况下拿到新规则（KVO 是否真的触发）。
- [ ] 确认扩展能否读取其它进程签名标识（`SecCodeCopyGuestWithAttributes` 在沙箱下的权限）。

### 下一步

- [ ] Rule DB 换成 SQLite，并用 App Group 让主 App 与扩展共享，替代 `vendorConfiguration` 的单次下发。
- [ ] 引入 Endpoint Security 获取进程事件，把 App / helper / 进程生命周期关联起来，解决 Safari、Chrome 等辅助进程漏判。
- [ ] 规则模型扩展：IP、域名、端口、方向（出站 / 入站），对应架构图里的 Rule Engine。
- [ ] 连接视图：按 App 展示实时连接（IP:port、协议、上下行流量），即架构图里的最终 UI。
- [ ] `NEFilterControlProvider` + remediation（拦截时给出提示页面）与放行白名单。
- [ ] 单元测试：`RuleStore` 持久化、规则解析与匹配（`iProxyTests`，Swift Testing）。
- [ ] 分发：Developer ID 签名 + 公证，梳理主 App 是否还需要关闭 App Sandbox。
