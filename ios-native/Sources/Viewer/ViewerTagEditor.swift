import SwiftUI

struct ViewerTagEditor: View {
    let api: APIClient
    let asset: Asset
    let onUpdated: (Asset) -> Void
    @State private var tags: [AssetTag] = []
    @State private var selected = Set<String>()
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New tag", text: $name)
                    Button("Create") { create() }.requiresWriteAccess(api).disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section {
                ForEach(tags) { tag in
                    Button { Task { await toggle(tag) } } label: {
                        HStack { Text(tag.value); Spacer(); if selected.contains(tag.id) { Image(systemName: "checkmark").foregroundStyle(.tint) } }
                    }.disabled(busy).requiresWriteAccess(api)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Tags")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .task {
                selected = Set((asset.tags ?? []).map(\.id))
                do { tags = try await api.request(.get, path: "tags") } catch { self.error = error.localizedDescription }
            }
    }
    private func toggle(_ tag: AssetTag) async {
        busy = true; defer { busy = false }
        do {
            let results: [BulkResult] = try await api.request(selected.contains(tag.id) ? .delete : .put, path: "tags/\(tag.id)/assets", body: BulkIDs(ids: [asset.id]))
            guard results.allSatisfy(\.success) else { throw APIError.invalidResponse("The tag could not be updated. Refresh and try again.") }
            if !selected.insert(tag.id).inserted { selected.remove(tag.id) }
            onUpdated(try await api.asset(id: asset.id))
        } catch { self.error = error.localizedDescription }
    }
    private func create() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.contains("/") else { error = "A tag name cannot contain a slash."; return }
        busy = true
        Task {
            do {
                let tag: AssetTag = try await api.request(.post, path: "tags", body: ["name": name])
                tags.append(tag); self.name = ""; await toggle(tag)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
