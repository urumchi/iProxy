import Combine
import Foundation

@MainActor
final class RuleStore: ObservableObject {
    @Published private(set) var rules: [String: NetworkRule] = [:]
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "iProxy", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appending(path: "rules.json")
        load()
    }

    func rule(for application: ManagedApplication) -> NetworkRule? { rules[application.bundleIdentifier] }

    func setBlocked(_ blocked: Bool, for application: ManagedApplication) {
        if blocked {
            rules[application.bundleIdentifier] = NetworkRule(
                applicationBundleIdentifier: application.bundleIdentifier, action: .drop, updatedAt: .now
            )
        } else {
            rules.removeValue(forKey: application.bundleIdentifier)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([NetworkRule].self, from: data) else { return }
        rules = Dictionary(uniqueKeysWithValues: decoded.map { ($0.applicationBundleIdentifier, $0) })
    }

    private func save() {
        let data = try? JSONEncoder().encode(Array(rules.values))
        if let data { try? data.write(to: fileURL, options: .atomic) }
    }
}
