import Combine
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var applications: [ManagedApplication] = []
    @Published var searchText = ""
    @Published var isLoading = false

    let rules = RuleStore()
    let filter = FilterConfigurationService()

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
