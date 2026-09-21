import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var applications: [ManagedApplication] = []
    @Published var searchText = ""
    @Published var isLoading = false

    let rules = RuleStore()
    let filter = FilterConfigurationService()

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // 嵌套的 ObservableObject 不会把变化冒泡给 AppStore：
        // 不转发的话，开关和状态栏文案要等 AppStore 自身属性变化（例如点「重新扫描」）才刷新。
        rules.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        filter.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var visibleApplications: [ManagedApplication] {
        guard !searchText.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }

    func reloadApplications() {
        isLoading = true
        Task {
            let applications = await Task.detached { ApplicationScanner.scan() }.value
            self.applications = applications
            self.isLoading = false
        }
    }

    func setBlocked(_ blocked: Bool, for application: ManagedApplication) {
        rules.setBlocked(blocked, for: application)
        filter.apply(rules: Array(rules.rules.values))
    }
}
