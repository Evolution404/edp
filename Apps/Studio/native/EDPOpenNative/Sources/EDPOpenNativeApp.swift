import SwiftUI

@main
struct EDPOpenNativeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("EDPOpen") {
            RootView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .defaultSize(width: 1320, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            NativeSettingsView()
                .frame(width: 520, height: 300)
        }
    }
}

struct NativeSettingsView: View {
    var body: some View {
        Form {
            Section("原生迁移") {
                LabeledContent("界面") { Text("SwiftUI + AppKit") }
                LabeledContent("最低系统") { Text("macOS 26") }
                LabeledContent("Raw Broker") { Text("Swift XPC · FDA · 已接入") }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
