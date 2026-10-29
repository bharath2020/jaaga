import AppKit
import SwiftUI

/// Jaaga's window.
///
/// The app is a renderer: it starts the daemon, asks it questions, draws the answers, and sends the
/// user's actions back. Light appearance only for now — the palette that makes the space map readable
/// was designed for it, and a dark set is a deliberate follow-up rather than an automatic inversion.
@main
struct JaagaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Jaaga", id: "jaaga-main") {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .task {
                    // Quitting does not take the window through onDisappear, so the daemon this app
                    // started would outlive it without this.
                    appDelegate.onTerminate = { [model] in model.shutDown() }
                    await model.connect()
                }
                .onDisappear { model.shutDown() }
        }
        .defaultSize(width: Theme.windowSize.width, height: Theme.windowSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Space Map") { model.view = .spaceMap }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Usual Suspects") { model.view = .suspects }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Watched Folders") { model.view = .watched }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Rescan") { Task { await model.reload(refresh: true) } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Enclosing Folder") { Task { await model.goBack() } }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { onTerminate?() }
    }
}
