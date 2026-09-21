import Combine
import Foundation
@preconcurrency import NetworkExtension

/// Installs the rule payload consumed by the Content Filter Provider extension.
/// The extension, not the UI process, decides each new network flow.
@MainActor
final class FilterConfigurationService: ObservableObject {
    nonisolated static let providerBundleIdentifier = "org.mktime.hmccb.iProxy.ContentFilter"
    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = "正在读取系统过滤器状态…"

    func refresh() {
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                if let error { self?.statusMessage = "无法读取过滤器：\(error.localizedDescription)"; return }
                self?.isEnabled = NEFilterManager.shared().isEnabled
                self?.statusMessage = self?.isEnabled == true ? "系统内容过滤器已启用" : "系统内容过滤器未启用"
            }
        }
    }

    func apply(rules: [NetworkRule]) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard error == nil else {
                DispatchQueue.main.async { self?.statusMessage = "无法加载过滤器配置：\(error!.localizedDescription)" }
                return
            }
            let configuration = NEFilterProviderConfiguration()
            // This is the bundle ID of the NEFilterDataProvider extension, not
            // the containing SwiftUI application.
            configuration.filterDataProviderBundleIdentifier = Self.providerBundleIdentifier
            configuration.filterSockets = true
            configuration.vendorConfiguration = [
                "rules": rules.map { ["bundleIdentifier": $0.applicationBundleIdentifier, "action": $0.action.rawValue] }
            ]
            manager.providerConfiguration = configuration
            manager.localizedDescription = "iProxy 网络访问控制"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    self?.isEnabled = error == nil
                    self?.statusMessage = error.map { "无法启用过滤器：\($0.localizedDescription)" } ?? "规则已提交给系统过滤器"
                }
            }
        }
    }
}
