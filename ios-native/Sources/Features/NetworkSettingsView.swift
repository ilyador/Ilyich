import SwiftUI
import UniformTypeIdentifiers
import UIKit
import WidgetKit

struct NetworkSettingsView: View {
    var api: APIClient? = nil
    let server: URL
    @Environment(\.dismiss) private var dismiss
    @State private var headers: [NetworkHeaderRow] = []
    @State private var endpoints: [NetworkEndpointRow] = []
    @State private var switchEndpoints = false
    @State private var preferredWifiName = ""
    @State private var localEndpoint = ""
    @State private var wifiPermissionDenied = false
    @State private var loaded = false
    @State private var busy = false
    @State private var failure: FeatureFailure?
    @State private var importing = false
    @State private var certificate: Data?
    @State private var certificateName = ""
    @State private var certificatePassword = ""
    @State private var certificatePresent = false
    @State private var confirmRemoveCertificate = false
    var body: some View {
        Form {
            Section("Server") { Text(server.absoluteString).font(.subheadline).textSelection(.enabled) }
            Section {
                ForEach($headers) { $header in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Header name", text: $header.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Remove header", systemImage: "minus.circle", role: .destructive) { headers.removeAll { $0.id == header.id } }.labelStyle(.iconOnly)
                        }
                        SecureField("Value", text: $header.value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }.padding(.vertical, 4)
                }
                Button("Add header", systemImage: "plus") { headers.append(.init()) }
            } header: { Text("Custom headers") } footer: { Text("For a reverse proxy or additional server authentication. Values are stored securely in the Keychain. Your Ilyich sign-in is sent separately from proxy authorization.") }
            Section {
                Toggle("Switch addresses automatically", isOn: $switchEndpoints)
                ForEach($endpoints) { $endpoint in
                    HStack {
                        TextField("https://server.example", text: $endpoint.address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Remove address", systemImage: "minus.circle", role: .destructive) { endpoints.removeAll { $0.id == endpoint.id } }.labelStyle(.iconOnly)
                    }
                }.onMove { endpoints.move(fromOffsets: $0, toOffset: $1) }
                Button("Add address", systemImage: "plus") { endpoints.append(.init()) }
            } header: { Text("Other addresses for this server") } footer: {
                Text("Addresses are tried in this order, then your main server address. Add only addresses for this same server, such as its local network address. These addresses receive your sign-in credentials and custom headers.")
            }
            Section {
                TextField("Wi-Fi name", text: $preferredWifiName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("http://192.168.1.20:2283", text: $localEndpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use current Wi-Fi name", systemImage: "wifi") { Task { await fillCurrentWifiName() } }
                    .frame(minHeight: 44)
            } header: { Text("Preferred home Wi-Fi") } footer: {
                Text("Enter the Wi-Fi name and local address, or use the current name and allow location access when prompted. The local address is preferred only on that Wi-Fi.")
            }
            Section {
                Label(certificatePresent ? "Client certificate installed" : "No client certificate", systemImage: certificatePresent ? "checkmark.shield" : "lock.shield")
                Button(certificatePresent ? "Choose replacement certificate" : "Choose certificate") { importing = true }
                if certificate != nil {
                    Text(certificateName).font(.subheadline)
                    SecureField("Certificate password", text: $certificatePassword).textContentType(.password)
                    Button("Import certificate") { Task { await importCertificate() } }
                    Button("Discard selected file", role: .cancel) { clearCertificate() }
                }
                if certificatePresent { Button("Remove client certificate", role: .destructive) { confirmRemoveCertificate = true } }
            } header: { Text("Client certificate") } footer: {
                Text("Use a PKCS#12 (.p12 or .pfx) file containing your certificate and private key. Importing or removing it takes effect for new secure connections to this server.")
            }
        }.navigationTitle("Network settings").disabled(!loaded || busy)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!loaded || busy) }
            if endpoints.count > 1 { ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!loaded || busy) } }
        }
        .overlay { if busy || !loaded { ProgressView() } }
        .task { await load() }
        .onDisappear { clearCertificate() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 10 * 1024 * 1024 else { throw APIError.invalidResponse("Choose a certificate file smaller than 10 MB.") }
                certificate = try Data(contentsOf: url); certificateName = url.lastPathComponent; certificatePassword = ""
            } catch { failure = .init(error) }
        }
        .confirmationDialog("Remove this server’s client certificate?", isPresented: $confirmRemoveCertificate, titleVisibility: .visible) {
            Button("Remove certificate", role: .destructive) {
                do { try ClientCertificateStore.remove(server: server); certificatePresent = false; clearCertificate() } catch { failure = .init(error) }
            }
        }
        .alert("Couldn’t update network settings", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if wifiPermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            if !loaded { Button("Retry") { Task { await load() } } }
            Button("OK", role: .cancel) { }
        } message: { Text(failure?.message ?? "") }
    }
    private func load() async {
        guard !loaded else { return }
        do {
            let configuration: NetworkConfiguration
            if let api { configuration = await api.networkConfiguration() }
            else { configuration = try NetworkConfigurationStore.load(server: server) }
            headers = configuration.customHeaders.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { .init(name: $0.key, value: $0.value) }
            endpoints = configuration.alternateEndpoints.map { .init(address: $0.absoluteString) }
            switchEndpoints = configuration.automaticallySwitchEndpoints
            preferredWifiName = configuration.preferredWifiName ?? ""
            localEndpoint = configuration.localEndpoint?.absoluteString ?? ""
            certificatePresent = try ClientCertificateStore.hasCertificate(server: server)
            loaded = true
        } catch { failure = .init(error) }
    }
    private func save() async {
        busy = true; defer { busy = false }
        do {
            var values: [String: String] = [:], names = Set<String>()
            for header in headers where !header.name.isEmpty || !header.value.isEmpty {
                let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard names.insert(name.lowercased()).inserted else { throw NetworkConfigurationError.invalidHeader }
                values[name] = header.value
            }
            let addresses = try endpoints.compactMap { row -> URL? in
                let address = row.address.trimmingCharacters(in: .whitespacesAndNewlines)
                if address.isEmpty { return nil }
                guard let url = URL(string: address) else { throw NetworkConfigurationError.invalidAddress }
                return try ServerAddress.normalized(url)
            }
            let localAddress = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let localURL: URL?
            if localAddress.isEmpty { localURL = nil }
            else {
                guard let url = URL(string: localAddress) else { throw NetworkConfigurationError.invalidAddress }
                localURL = try ServerAddress.normalized(url)
            }
            let configuration = try NetworkConfiguration(customHeaders: values, alternateEndpoints: addresses,
                                                          automaticallySwitchEndpoints: switchEndpoints,
                                                          preferredWifiName: preferredWifiName, localEndpoint: localURL).validated()
            if let api { try await api.updateNetworkConfiguration(configuration) }
            else { try NetworkConfigurationStore.save(configuration, server: server) }
            WidgetCenter.shared.reloadAllTimelines()
            dismiss()
        } catch { failure = .init(error) }
    }
    private func importCertificate() async {
        guard let data = certificate else { return }
        busy = true; defer { busy = false }
        do {
            let password = certificatePassword, target = server
            try await Task.detached(priority: .userInitiated) { try ClientCertificateStore.importCertificate(data: data, password: password, server: target) }.value
            certificatePresent = true; clearCertificate()
        } catch { failure = .init(error) }
    }
    private func fillCurrentWifiName() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        wifiPermissionDenied = false
        do {
            let wifiAccess = WiFiNetworkAccess()
            guard let name = try await wifiAccess.requestCurrentName(), !name.isEmpty else {
                wifiPermissionDenied = true
                throw APIError.invalidResponse("The current Wi-Fi name is unavailable. Enter it manually or check Location Services access.")
            }
            preferredWifiName = name
        } catch {
            wifiPermissionDenied = true
            failure = .init(error)
        }
    }
    private func clearCertificate() { certificate = nil; certificateName = ""; certificatePassword = "" }
}

private struct NetworkHeaderRow: Identifiable { let id = UUID(); var name = ""; var value = "" }
private struct NetworkEndpointRow: Identifiable { let id = UUID(); var address = "" }
