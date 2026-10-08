import SwiftUI

@main
struct ScivaneApp: App {

    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @StateObject private var backend: BackendManager
    @StateObject private var model: AppModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        let backend = BackendManager()
        _backend = StateObject(wrappedValue: backend)
        let model = AppModel(backend: backend)
        // The only place this is set: startup side effects (seeding provider cards, which writes
        // providers.json and starts the backend) belong to the real app, not to offscreen checks.
        model.isLiveApp = true
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        Window("Scivane", id: "main") {
            ContentView(model: model, backend: backend)
                .frame(minWidth: 960, minHeight: 580)
                .ignoresSafeArea(.container, edges: .top)
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: appearance) { _, value in value.apply() }
                .onAppear {
                    appearance.apply()
                    delegate.backend = backend
                    delegate.model = model

                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1160, height: 760)
        // Our own menu items follow the UI language immediately; AppKit's built-in ones (Edit, Window,
        // Quit) pick their language at launch (Localization.launchLanguage).
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(L("设置…", "Settings…")) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("导入 PDF 或图片…", "Import PDF or Image…")) { model.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)

            }
            CommandGroup(after: .saveItem) {
                Button(L("导出 Markdown…", "Export Markdown…")) {
                    if let job = model.readingDocument { model.exportOne(job) }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.jobs.contains(where: \.hasResult))

                Button(L("复制 Markdown", "Copy Markdown")) { model.copyMarkdown() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.readingDocument == nil)
            }
            CommandGroup(after: .toolbar) {
                Button(L("查找正文", "Find in Text")) { model.isSearching.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.readingDocument == nil)
                Button(sidebarVisible ? L("隐藏侧栏", "Hide Sidebar") : L("显示侧栏", "Show Sidebar")) {
                    sidebarVisible.toggle()
                }
                    .keyboardShortcut("b", modifiers: .command)
                Button(L("页面缩略图", "Page Thumbnails")) { model.showThumbnails.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .help) {
                Button(L("重启识别引擎", "Restart Recognition Engine")) { backend.restart() }
            }
        }

        Settings {
            SettingsView(backend: backend, model: model)
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// llama-server keeps 1.8 GB resident; quitting must take it down too.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var backend: BackendManager?
private var pendingFiles: [URL] = []
var model: AppModel? {
    didSet {
        MainActor.assumeIsolated {
            if let model, !pendingFiles.isEmpty {
                model.add(urls: pendingFiles)
                pendingFiles.removeAll()
            }
        }
    }
}


    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        MainActor.assumeIsolated { let urls = filenames.map { URL(fileURLWithPath: $0) }; if let model { model.add(urls: urls) } else { pendingFiles.append(contentsOf: urls) } }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { backend?.stop() }
    }
}
