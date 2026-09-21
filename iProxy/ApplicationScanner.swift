import AppKit
import Foundation

enum ApplicationScanner {
    /// Lists launchable .app bundles in the standard system and user locations.
    nonisolated static func scan() -> [ManagedApplication] {
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        ]

        var seen = Set<String>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let apps = directories.flatMap { directory -> [ManagedApplication] in
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }

            var result: [ManagedApplication] = []
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let identifier = bundle.bundleIdentifier,
                      seen.insert(identifier).inserted else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                result.append(ManagedApplication(bundleIdentifier: identifier, name: name, url: url))
            }
            return result
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
