import Combine
import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions
import os

/// 负责两件事：安装（激活）随 App 分发的系统扩展，以及把规则写进系统过滤器。
/// 每条网络流是否放行由扩展进程决定，这个类不参与判定。
@MainActor
final class FilterConfigurationService: NSObject, ObservableObject {
    nonisolated static let providerBundleIdentifier = "org.mktime.hmccb.iProxy.ContentFilter"
    nonisolated private static let log = Logger(subsystem: "org.mktime.hmccb.iProxy", category: "filter")

    @Published private(set) var isEnabled = false
    @Published private(set) var statusMessage = "正在读取系统过滤器状态…"

    private var pendingRules: [NetworkRule] = []
    private var isExtensionActivated = false
    private var isActivating = false
    private var activationRequest: OSSystemExtensionRequest?

    func refresh() {
        NEFilterManager.shared().loadFromPreferences { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.statusMessage = "无法读取过滤器：\(error.localizedDescription)"
                    Self.log.error("loadFromPreferences 失败: \(error.localizedDescription, privacy: .public)")
                    return
                }
                self.isEnabled = NEFilterManager.shared().isEnabled
                self.statusMessage = self.isEnabled ? "系统内容过滤器已启用" : "系统内容过滤器未启用"
            }
        }
    }

    /// 下发最新规则；扩展还没装好时先安装，装好后再写配置。
    func apply(rules: [NetworkRule]) {
        pendingRules = rules
        statusMessage = "正在应用规则…"
        if isExtensionActivated {
            savePreferences()
        } else {
            activateExtension()
        }
    }

    private func activateExtension() {
        guard !isActivating else {
            statusMessage = "正在等待系统扩展安装完成…"
            return
        }
        isActivating = true
        statusMessage = "正在安装网络过滤器扩展…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.providerBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func savePreferences() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.statusMessage = "无法加载过滤器配置：\(error.localizedDescription)"
                    Self.log.error("过滤配置读取失败: \(error.localizedDescription, privacy: .public)")
                    return
                }

                let configuration = NEFilterProviderConfiguration()
                // 这里填的是 NEFilterDataProvider 扩展的 Bundle ID，不是外层 SwiftUI App。
                configuration.filterDataProviderBundleIdentifier = Self.providerBundleIdentifier
                configuration.filterSockets = true
                configuration.vendorConfiguration = Self.vendorConfiguration(from: self.pendingRules)
                manager.providerConfiguration = configuration
                manager.localizedDescription = "iProxy 网络访问控制"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    Task { @MainActor in
                        if let error {
                            self.isEnabled = false
                            self.statusMessage = "无法启用过滤器：\(error.localizedDescription)"
                            Self.log.error("saveToPreferences 失败: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        self.isEnabled = true
                        self.statusMessage = self.pendingRules.isEmpty
                            ? "系统过滤器已启用，当前没有应用被禁止联网"
                            : "已生效：\(self.pendingRules.count) 个应用被禁止联网"
                        Self.log.info("已下发 \(self.pendingRules.count) 条规则")
                    }
                }
            }
        }
    }

    nonisolated private static func vendorConfiguration(from rules: [NetworkRule]) -> [String: Any] {
        ["rules": rules.map { ["bundleIdentifier": $0.applicationBundleIdentifier, "action": $0.action.rawValue] }]
    }
}

extension FilterConfigurationService: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.statusMessage = "请在“系统设置 → 通用 → 登录项与扩展”中允许 iProxy 的扩展"
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.isActivating = false
            switch result {
            case .completed:
                self.isExtensionActivated = true
                Self.log.info("系统扩展已安装")
                self.savePreferences()
            case .willCompleteAfterReboot:
                self.isExtensionActivated = true
                self.statusMessage = "扩展已安装，重启后生效"
                self.savePreferences()
            @unknown default:
                self.statusMessage = "扩展安装返回未知结果"
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.isActivating = false
            self.isExtensionActivated = false
            self.statusMessage = "扩展安装失败：\(error.localizedDescription)"
            Self.log.error("系统扩展安装失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
