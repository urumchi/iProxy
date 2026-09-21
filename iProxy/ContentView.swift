import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("iProxy").font(.title2.weight(.semibold))
                    Text(store.filter.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新扫描", systemImage: "arrow.clockwise") { store.reloadApplications() }
                    .disabled(store.isLoading)
            }
            .padding()

            TextField("搜索应用或 Bundle ID", text: $store.searchText)
                .textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 10)

            List(store.visibleApplications) { application in
                ApplicationRow(application: application)
            }
            .overlay {
                if store.isLoading { ProgressView("正在扫描应用…") }
            }
        }
        .task {
            store.filter.refresh()
            store.reloadApplications()
        }
    }
}

private struct ApplicationRow: View {
    @EnvironmentObject private var store: AppStore
    let application: ManagedApplication

    private var blocked: Bool { store.rules.rule(for: application)?.action == .drop }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: application.icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading) {
                Text(application.name)
                Text(application.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("禁止联网", isOn: Binding(
                get: { blocked },
                set: { store.setBlocked($0, for: application) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            Text(blocked ? "已阻止" : "允许").foregroundStyle(blocked ? .red : .green).font(.caption)
        }
        .padding(.vertical, 3)
    }
}
