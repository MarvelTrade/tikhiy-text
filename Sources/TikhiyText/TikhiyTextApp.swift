import SwiftUI

@main
struct TikhiyTextApp: App {
    @StateObject private var state: AppState

    init() {
        let value = AppState()
        AppStateHolder.shared = value
        _state = StateObject(wrappedValue: value)
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть файл…") { state.openPanel() }.keyboardShortcut("o")
            }
        }
    }
}
