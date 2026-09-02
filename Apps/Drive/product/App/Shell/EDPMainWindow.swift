import AppKit
import SwiftUI

struct EDPMainView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var section: EDPMainSection? = .overview
    @StateObject private var splitBridge = EDPNativeSplitBridge()

    var body: some View {
        EDPNativeSplitView(model: model, section: $section, bridge: splitBridge)
            .frame(minWidth: 900, minHeight: 620)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { splitBridge.toggleSidebar() } label: {
                        Label("显示或隐藏侧栏", systemImage: "sidebar.leading")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("显示或隐藏侧栏")
                    .focusEffectDisabled()
                    .help("显示或隐藏侧栏")
                }
            }
            .alert("操作失败", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("好") { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "未知错误")
            }
    }
}

@MainActor
private final class EDPNativeSplitBridge: ObservableObject {
    weak var controller: EDPNativeSplitViewController?

    func toggleSidebar() {
        controller?.toggleSidebar(nil)
    }
}

private struct EDPNativeSplitView: NSViewControllerRepresentable {
    @ObservedObject var model: EDPVaultViewModel
    @Binding var section: EDPMainSection?
    @ObservedObject var bridge: EDPNativeSplitBridge

    func makeNSViewController(context: Context) -> EDPNativeSplitViewController {
        let controller = EDPNativeSplitViewController(model: model, section: $section)
        bridge.controller = controller
        return controller
    }

    func updateNSViewController(_ nsViewController: EDPNativeSplitViewController, context: Context) {
        nsViewController.update(model: model, section: $section)
        bridge.controller = nsViewController
    }
}

private struct EDPNativeDetailView: View {
    @ObservedObject var model: EDPVaultViewModel
    let section: EDPMainSection?

    var body: some View {
        ZStack {
            EDPWindowBackdrop()
            switch section ?? .overview {
            case .overview: EDPOverviewView(model: model)
            case .devices: EDPDevicesView(model: model)
            case .activity: EDPActivityView(model: model)
            case .settings: EDPSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class EDPNativeSplitViewController: NSSplitViewController {
    private let sidebarHost: NSHostingController<EDPNativeSidebarView>
    private let detailHost: NSHostingController<EDPNativeDetailView>
    private var currentSection: EDPMainSection?

    init(model: EDPVaultViewModel, section: Binding<EDPMainSection?>) {
        sidebarHost = NSHostingController(rootView: EDPNativeSidebarView(section: section))
        detailHost = NSHostingController(
            rootView: EDPNativeDetailView(model: model, section: section.wrappedValue)
        )
        currentSection = section.wrappedValue
        super.init(nibName: nil, bundle: nil)

        // NSSplitViewController owns the live-resize geometry. Prevent the SwiftUI
        // hosting controllers from feeding intrinsic/preferred-size updates back
        // into each animation frame, which otherwise amplifies cold sidebar hitches.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        minimumThicknessForInlineSidebars = 0

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 500

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(model: EDPVaultViewModel, section: Binding<EDPMainSection?>) {
        let nextSection = section.wrappedValue
        guard nextSection != currentSection else { return }
        currentSection = nextSection
        detailHost.rootView = EDPNativeDetailView(model: model, section: nextSection)
    }
}

#if EDP_UI_AUTOMATION
@MainActor
func edpAutomationToggleSidebar(_ controller: NSSplitViewController) {
    guard let controller = controller as? EDPNativeSplitViewController else { return }
    controller.toggleSidebar(nil)
}
#endif
