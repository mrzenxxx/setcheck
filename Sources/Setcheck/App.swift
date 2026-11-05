import SwiftUI

@main struct SetcheckApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(SetcheckDelegate.self) private var delegate
    var body: some Scene {
        Window("Setcheck", id: "main") {
            ContentView(model: model).onAppear { delegate.model = model }
        }.defaultSize(width: 1040, height: 760)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Добавить плейлист или файлы…") { model.chooseSources() }.keyboardShortcut("o").disabled(model.busy)
                }
                CommandGroup(replacing: .help) { Button("Как проверить на YouTube") { model.showHelp = true } }
            }
    }
}
@MainActor final class SetcheckDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        model.cancel()
        Task { @MainActor in
            while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for _ in 0..<50 {
                if let model { model.add(urls); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
