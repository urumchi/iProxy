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
    private var bundleIdentifiersByAuditToken: [Data: String] = [:]
    private var configurationObservation: NSKeyValueObservation?
    private var lastRuleRefresh = Date.distantPast

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
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
        Self.log.info("拦截 \(identifier, privacy: .public)")
        return .drop()
    }

    /// 精确匹配 Bundle ID；另外匹配 `com.foo.app.helper` 这类同前缀的辅助进程。
    private func isBlocked(_ identifier: String) -> Bool {
        if blockedBundleIdentifiers.contains(identifier) { return true }
        return blockedBundleIdentifiers.contains { identifier.hasPrefix("\($0).") }
    }

    private func refreshRules() {
        lastRuleRefresh = Date()
        blockedBundleIdentifiers = Self.blockedBundleIdentifiers(from: filterConfiguration)
        Self.log.info("当前拦截 \(self.blockedBundleIdentifiers.count) 个应用")
    }

    private func refreshRulesIfStale() {
        guard Date().timeIntervalSince(lastRuleRefresh) >= Self.refreshInterval else { return }
        refreshRules()
    }

    private func bundleIdentifier(for flow: NEFilterFlow) -> String? {
        guard let auditToken = flow.sourceAppAuditToken else { return nil }
        if let cached = bundleIdentifiersByAuditToken[auditToken] { return cached }
        guard let identifier = Self.bundleIdentifier(fromAuditToken: auditToken) else { return nil }
        if bundleIdentifiersByAuditToken.count >= Self.cacheLimit {
            bundleIdentifiersByAuditToken.removeAll()
        }
        bundleIdentifiersByAuditToken[auditToken] = identifier
        return identifier
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

        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any] else { return nil }
        return information[kSecCodeInfoIdentifier as String] as? String
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
