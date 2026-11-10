import AppKit
import SwiftUI

@MainActor
final class UpdatePanel: NSObject, ObservableObject, NSWindowDelegate {
    enum Action {
        case install, later, download, skip
    }

    private let window: NSPanel
    private var choice: CheckedContinuation<Action, Never>?
    @Published private var stage: String?

    init(version: String, current: String, notes: String?, isBeta: Bool) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "NormalSwitcher"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: Content(
            panel: self, version: version, current: current, notes: notes, isBeta: isBeta
        ))
    }

    func ask() async -> Action {
        await withCheckedContinuation { continuation in
            choice = continuation
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func showStage(_ label: String) {
        stage = label
        window.standardWindowButton(.closeButton)?.isEnabled = false
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        select(.later)
        return false
    }

    private func select(_ action: Action) {
        guard let choice else { return }
        self.choice = nil
        choice.resume(returning: action)
    }

    private struct Content: View {
        @ObservedObject var panel: UpdatePanel
        let version: String
        let current: String
        let notes: String?
        let isBeta: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 54, height: 54)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NormalSwitcher")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(L10n.updateAvailable + (isBeta ? " " + L10n.updateBeta : ""))
                            .font(.title2.weight(.semibold))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(L10n.updateNewVersion) \(version)").fontWeight(.medium)
                    Text("\(L10n.updateInstalledVersion) \(current)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ScrollView {
                        Text(verbatim: notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: 140)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer(minLength: 0)
                if let stage = panel.stage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(stage).foregroundStyle(.secondary)
                        ProgressView()
                            .progressViewStyle(.linear)
                            .accessibilityLabel(stage)
                    }
                } else {
                    HStack(spacing: 10) {
                        Menu {
                            Button(L10n.updateDownload) { panel.select(.download) }
                            Button(L10n.updateSkip) { panel.select(.skip) }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel(L10n.updateOptions)
                        }
                        .fixedSize()
                        Spacer()
                        Button(L10n.updateLater) { panel.select(.later) }.keyboardShortcut(.cancelAction)
                        Button(L10n.updateInstallRestart) {
                            panel.showStage(L10n.updateDownloading)
                            panel.select(.install)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(26)
            .frame(width: 470, height: 365, alignment: .topLeading)
            .tint(Color(red: 0.44, green: 0.26, blue: 0.78))
        }
    }
}
