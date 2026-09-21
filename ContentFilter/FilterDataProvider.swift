import Foundation
import NetworkExtension
import Security
import os

/// 过滤决策进程：每条网络连接是否放行，只在这里判断。
/// 规则由主 App 通过 `NEFilterProviderConfiguration.vendorConfiguration` 下发。
final class FilterDataProvider: NEFilterDataProvider {
    /// 与主 App 里 `NetworkRule.Action.drop` 的原始值保持一致（两个 target 不共享源码）。
    private static let dropAction = "drop"
    private static let log = Logger(subsystem: "org.mktime.hmccb.iProxy", category: "provider")
    /// 兜底刷新间隔：防止配置原地变化却没触发 KVO。
    private static let refreshInterval: TimeInterval = 2
    /// 进程标识缓存上限，避免长期运行后无限增长。
    private static let cacheLimit = 512

    private var blockedBundleIdentifiers: Set<String> = []
    /// audit token → Bundle ID；空串表示解析失败，避免对同一进程反复重试。
    private var bundleIdentifiersByAuditToken: [Data: String] = [:]
    private var configurationObservation: NSKeyValueObservation?
    private var lastRuleRefresh = Date.distantPast

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        Self.log.notice("过滤器已启动")
        refreshRules()
        // 主 App 保存新配置时，系统可能原地更新 filterConfiguration。
        configurationObservation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
            self?.refreshRules()
        }
        completionHandler(nil)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        refreshRulesIfStale()
        // 取不到来源 App 时放行，避免误伤系统流量。
        guard let identifier = bundleIdentifier(for: flow) else { return .allow() }
        guard isBlocked(identifier) else { return .allow() }
        Self.log.notice("拦截 \(identifier, privacy: .public)")
        return .drop()
    }

    /// 精确匹配 Bundle ID；另外匹配 `com.foo.app.helper` 这类同前缀的辅助进程。
    private func isBlocked(_ identifier: String) -> Bool {
        if blockedBundleIdentifiers.contains(identifier) { return true }
        return blockedBundleIdentifiers.contains { identifier.hasPrefix("\($0).") }
    }

    private func refreshRules() {
        lastRuleRefresh = Date()
        let updated = Self.blockedBundleIdentifiers(from: filterConfiguration)
        // 2 秒一次的兜底刷新会一直调用这里，只有规则真的变了才记日志。
        guard updated != blockedBundleIdentifiers else { return }
        blockedBundleIdentifiers = updated
        Self.log.notice("规则已更新：拦截 \(updated.count) 个应用")
    }

    private func refreshRulesIfStale() {
        guard Date().timeIntervalSince(lastRuleRefresh) >= Self.refreshInterval else { return }
        refreshRules()
    }

    private func bundleIdentifier(for flow: NEFilterFlow) -> String? {
        guard let auditToken = flow.sourceAppAuditToken else { return nil }
        if let cached = bundleIdentifiersByAuditToken[auditToken] {
            return cached.isEmpty ? nil : cached
        }

        let resolved = Self.bundleIdentifier(fromAuditToken: auditToken)
        if bundleIdentifiersByAuditToken.count >= Self.cacheLimit {
            bundleIdentifiersByAuditToken.removeAll()
        }
        bundleIdentifiersByAuditToken[auditToken] = resolved ?? ""
        if let resolved {
            Self.log.notice("来源进程：\(resolved, privacy: .public)")
        } else {
            Self.log.notice("来源进程解析失败：audit token 无法映射到 Bundle ID")
        }
        return resolved
    }

    /// macOS 上 NEFilterFlow 不提供 Bundle ID，只能拿 audit token 反查代码签名标识。
    private static func bundleIdentifier(fromAuditToken auditToken: Data) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        // 辅助进程（WPS 的 promecefpluginhost、Chrome/CEF 的 helper 等）有自己的签名标识，
        // 先回溯到最外层 .app，让规则落在用户实际勾选的那个 App 上。
        if let path = codePath(of: staticCode),
           let identifier = outermostApplicationIdentifier(forPath: path) {
            return identifier
        }

        // 兜底：进程自身的签名标识。
        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any] else { return nil }
        return information[kSecCodeInfoIdentifier as String] as? String
    }

    private static func codePath(of staticCode: SecStaticCode) -> String? {
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    /// 取路径里最外层的 `.app`：
    /// `/Applications/wpsoffice.app/Contents/SharedSupport/promecefpluginhost.app`
    /// → `/Applications/wpsoffice.app`。
    private static func outermostApplicationIdentifier(forPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        // 路径从根到叶子排列，第一个 `.app` 才是最外层；用 lastIndex 会拿到
        // 内嵌的 helper bundle（例如 promecefpluginhost.app），等于没归一。
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundleURL = URL(fileURLWithPath: NSString.path(withComponents: Array(components[0...index])))
        return Bundle(url: bundleURL)?.bundleIdentifier
    }

    private static func blockedBundleIdentifiers(
        from configuration: NEFilterProviderConfiguration?
    ) -> Set<String> {
        let rules = configuration?.vendorConfiguration?["rules"] as? [[String: String]] ?? []
        return Set(rules.compactMap { rule in
            rule["action"] == dropAction ? rule["bundleIdentifier"] : nil
        })
    }
}
