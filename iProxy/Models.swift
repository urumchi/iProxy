import AppKit
import Foundation

struct ManagedApplication: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let url: URL

    var id: String { bundleIdentifier }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

struct NetworkRule: Codable, Hashable, Identifiable, Sendable {
    enum Action: String, Codable, Sendable { case allow, drop }

    let applicationBundleIdentifier: String
    var action: Action
    var updatedAt: Date

    var id: String { applicationBundleIdentifier }
}
