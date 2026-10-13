import AppKit
import ScanSlapCore
import SwiftUI

@main
struct ScanSlapApp: App {
    @StateObject private var model = ScanSlapModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 560, idealWidth: 620, minHeight: 500, idealHeight: 560)
                .task { await model.refreshStatus() }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class ScanSlapModel: ObservableObject {
    @Published var scannerStatus: ScannerStatus = .checking
    @Published var source: ScanSource = .duplex
    @Published var colorMode: ScanColorMode = .color
    @Published var resolution = 300
    @Published var autoRotate = true
    @Published var outputFormat: ScanOutputFormat = .searchablePDF
    @Published var isScanning = false
    @Published var statusText = "Checking scanner…"
    @Published var lastScanURL: URL?
    @Published var errorMessage: String?
    @Published var outputDirectory: URL

    private let scanner = ScannerService()

    init() {
        outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Scans", isDirectory: true)
    }

    var canScan: Bool { scannerStatus == .ready && !isScanning }

    func refreshStatus() async {
        scannerStatus = .checking
        statusText = "Checking scanner…"
        let status = await scanner.status()
        scannerStatus = status
        switch status {
        case .checking: statusText = "Checking scanner…"
        case .ready: statusText = "ScanSnap S300M ready"
        case .unavailable(let detail): statusText = "Scanner unavailable: \(detail)"
        }
    }

    func scan() {
        guard canScan else { return }
        isScanning = true
        errorMessage = nil
        statusText = "Scanning… keep feeding pages"
        let settings = ScanSettings(source: source, colorMode: colorMode, resolution: resolution)
        let destination = outputDirectory
        let rotate = autoRotate
        let format = outputFormat

        Task {
            do {
                let result = try await scanner.scan(
                    settings: settings,
                    outputDirectory: destination,
                    outputFormat: format,
                    autoRotatePortrait: rotate
                )
                lastScanURL = result.outputURL
                statusText = "Saved \(result.pageCount) page\(result.pageCount == 1 ? "" : "s")"
                NSSound(named: "Glass")?.play()
            } catch {
                errorMessage = error.localizedDescription
                statusText = "Scan failed"
            }
            isScanning = false
            scannerStatus = await scanner.status()
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose where ScanSlap saves scans"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let selected = panel.url { outputDirectory = selected }
    }

    func openLastScan() {
        guard let lastScanURL else { return }
        NSWorkspace.shared.open(lastScanURL)
    }

    func revealOutputDirectory() { NSWorkspace.shared.open(outputDirectory) }
}

struct ContentView: View {
    @EnvironmentObject private var model: ScanSlapModel

    var body: some View {
        VStack(spacing: 22) {
            header
            statusCard
            settingsCard
            destinationCard
            actions
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "document.viewfinder")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("ScanSlap").font(.largeTitle.bold())
                Text("A modern home for your ScanSnap S300M").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 11, height: 11)
            Text(model.statusText).font(.headline)
            Spacer()
            if model.scannerStatus == .checking || model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button("Refresh") { Task { await model.refreshStatus() } }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var settingsCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            GridRow {
                Text("Sides")
                Picker("Sides", selection: $model.source) {
                    Text("Front").tag(ScanSource.front)
                    Text("Back").tag(ScanSource.back)
                    Text("Duplex").tag(ScanSource.duplex)
                }.labelsHidden().pickerStyle(.segmented)
            }
            GridRow {
                Text("Color")
                Picker("Color", selection: $model.colorMode) {
                    Text("Color").tag(ScanColorMode.color)
                    Text("Grayscale").tag(ScanColorMode.grayscale)
                    Text("Line art").tag(ScanColorMode.lineart)
                }.labelsHidden().pickerStyle(.segmented)
            }
            GridRow {
                Text("Resolution")
                Picker("Resolution", selection: $model.resolution) {
                    Text("150 dpi").tag(150)
                    Text("300 dpi").tag(300)
                    Text("600 dpi").tag(600)
                }.labelsHidden().pickerStyle(.segmented)
            }
            GridRow {
                Text("Cleanup")
                Toggle("Rotate landscape scans to portrait", isOn: $model.autoRotate)
            }
            GridRow {
                Text("Output")
                Picker("Output", selection: $model.outputFormat) {
                    ForEach(ScanOutputFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private var destinationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save scans to").font(.caption).foregroundStyle(.secondary)
                Text(model.outputDirectory.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { model.chooseOutputDirectory() }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private var actions: some View {
        HStack {
            Button("Show Scans") { model.revealOutputDirectory() }
            if model.lastScanURL != nil { Button("Open Last Scan") { model.openLastScan() } }
            Spacer()
            Button { model.scan() } label: {
                Label(model.isScanning ? "Scanning…" : "Scan", systemImage: "scanner.fill")
                    .font(.headline).frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canScan)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private var statusColor: Color {
        switch model.scannerStatus {
        case .checking: .orange
        case .ready: .green
        case .unavailable: .red
        }
    }
}
