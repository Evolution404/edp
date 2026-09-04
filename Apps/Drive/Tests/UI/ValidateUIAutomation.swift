import AppKit
import Foundation
import SwiftUI

private struct EDPUIAutomationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
@main
struct EDPUIAutomationMain {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        do {
            if CommandLine.arguments.contains("--hitch-only") {
                try validateSidebarHitches(toggleCount: 6, warmupSeconds: 3)
                print("RESULT=DRIVE_UI_HITCH_AUTOMATION_OK")
            } else {
                try validatePreviewScenarios()
                try validatePageRendering()
                try validateMenuBarCredentialFocus()
                try validateSidebarGeometry(toggleCount: 20, emitScenarioMarkers: true)
                print("RESULT=DRIVE_UI_AUTOMATION_OK")
            }
            fflush(stdout)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("DRIVE_UI_AUTOMATION_ERROR=\(error)\n".utf8))
            fflush(stderr)
            exit(1)
        }
    }

    private static func validatePreviewScenarios() throws {
        let expected = Set([
            "healthy-one-device", "no-device", "two-devices", "fda-required",
            "service-stopped", "credential-missing", "partition-error",
            "all-mounted", "offline-saved-device",
        ])
        try require(Set(EDPPreviewScenario.allCases.map(\.rawValue)) == expected, "preview scenario set drifted")

        for scenario in EDPPreviewScenario.allCases {
            let configuration = EDPPreviewScenarioFactory.configuration(for: scenario)
            switch scenario {
            case .healthyOneDevice:
                try require(configuration.snapshot.devices.count == 1, "healthy scenario device count")
                try require(configuration.snapshot.devices[0].partitions.filter { $0.mountState == .mounted }.count == 2, "healthy scenario mount count")
            case .noDevice:
                try require(configuration.snapshot.devices.isEmpty, "no-device scenario is not empty")
            case .twoDevices:
                try require(configuration.snapshot.devices.count == 2, "two-devices scenario count")
                try require(Set(configuration.snapshot.devices.map(\.deviceID)).count == 2, "two-devices identity collision")
            case .fdaRequired:
                try require(configuration.snapshot.devices.contains { $0.connected && !$0.privilegedAccessReady }, "fda-required scenario lacks blocked device")
            case .serviceStopped:
                try require(configuration.serviceStatus == "已停止" && !configuration.serviceDesiredRunning, "service-stopped state mismatch")
            case .credentialMissing:
                try require(configuration.snapshot.devices.flatMap(\.partitions).contains { $0.encrypted && $0.credentialStatus == .missing }, "credential-missing scenario lacks missing credential")
            case .partitionError:
                try require(configuration.snapshot.devices.flatMap(\.partitions).contains { $0.mountState == .failed && $0.lastError != nil }, "partition-error scenario lacks failure")
            case .allMounted:
                let partitions = configuration.snapshot.devices.flatMap(\.partitions)
                try require(!partitions.isEmpty && partitions.allSatisfy { $0.mountState == .mounted }, "all-mounted scenario has unmounted partition")
            case .offlineSavedDevice:
                try require(configuration.snapshot.devices.count == 1 && configuration.snapshot.devices[0].connected == false, "offline-saved-device state mismatch")
            }
            print("SCENARIO=UI_PREVIEW_\(scenario.rawValue)_OK")
        }
        print("RESULT=DRIVE_UI_PREVIEW_SCENARIOS_OK")
    }

    private static func validatePageRendering() throws {
        let configuration = EDPPreviewScenarioFactory.configuration(for: .healthyOneDevice)
        let model = EDPVaultViewModel(previewConfiguration: configuration)
        let twoDeviceModel = EDPVaultViewModel(
            previewConfiguration: EDPPreviewScenarioFactory.configuration(for: .twoDevices)
        )
        let credentialMissingModel = EDPVaultViewModel(
            previewConfiguration: EDPPreviewScenarioFactory.configuration(for: .credentialMissing)
        )
        guard let device = configuration.snapshot.devices.first else {
            throw EDPUIAutomationFailure(description: "healthy preview device missing")
        }

        let pages: [(String, AnyView, NSSize)] = [
            ("overview-light", AnyView(EDPOverviewView(model: model).environment(\.colorScheme, .light)), NSSize(width: 720, height: 620)),
            ("overview-dark", AnyView(EDPOverviewView(model: model).environment(\.colorScheme, .dark)), NSSize(width: 720, height: 620)),
            ("overview-two-devices", AnyView(EDPOverviewView(model: twoDeviceModel)), NSSize(width: 720, height: 620)),
            ("devices", AnyView(EDPDevicesView(model: model)), NSSize(width: 720, height: 620)),
            ("device-overview", AnyView(EDPDeviceDetailView(device: device, model: model, previewSection: .overview)), NSSize(width: 720, height: 620)),
            ("device-partitions", AnyView(EDPDeviceDetailView(device: device, model: model, previewSection: .partitions)), NSSize(width: 720, height: 620)),
            ("device-security", AnyView(EDPDeviceDetailView(device: device, model: model, previewSection: .security)), NSSize(width: 720, height: 620)),
            ("activity", AnyView(EDPActivityView(model: model)), NSSize(width: 720, height: 620)),
            ("settings", AnyView(EDPSettingsView(model: model)), NSSize(width: 720, height: 620)),
            ("menu-bar", AnyView(EDPMenuBarView(model: model)), NSSize(width: 390, height: 640)),
            ("menu-bar-credential-missing", AnyView(EDPMenuBarView(model: credentialMissingModel)), NSSize(width: 390, height: 640)),
        ]

        for (name, view, size) in pages {
            let window = makeWindow(rootView: view, size: size)
            defer { window.close() }
            spin(seconds: 0.08)
            guard let contentView = window.contentView else {
                throw EDPUIAutomationFailure(description: "\(name) content view missing")
            }
            contentView.layoutSubtreeIfNeeded()
            try require(contentView.bounds.width > 0 && contentView.bounds.height > 0, "\(name) rendered empty")
            try require(contentView.bounds.width <= size.width + 1, "\(name) exceeded test width")
            try require(!containsOverflowChevron(in: contentView), "\(name) rendered toolbar overflow chevron")
            print("SCENARIO=UI_PAGE_\(name)_OK")
        }
        print("RESULT=DRIVE_UI_PAGE_RENDERING_OK")
    }

    private static func validateMenuBarCredentialFocus() throws {
        let configuration = EDPPreviewScenarioFactory.configuration(for: .credentialMissing)
        let model = EDPVaultViewModel(previewConfiguration: configuration)
        guard let device = configuration.snapshot.devices.first(where: \.connected),
              let partition = device.partitions.first(where: { $0.encrypted }) else {
            throw EDPUIAutomationFailure(description: "menu credential focus fixture missing")
        }
        let target = EDPCredentialTarget(
            deviceID: device.deviceID,
            partitionType: partition.partitionType,
            partitionName: partition.displayName
        )
        let root = AnyView(
            EDPMenuBarView(model: model, initialCredentialTarget: target)
                .environment(\.colorScheme, .light)
        )
        let window = makeWindow(rootView: root, size: NSSize(width: 390, height: 320))
        defer { window.close() }
        spin(seconds: 0.15)

        guard let contentView = window.contentView,
              let secureField = findSecureTextField(in: contentView) else {
            throw EDPUIAutomationFailure(description: "inline menu credential SecureField missing")
        }
        try require(window.attachedSheet == nil, "menu credential editor regressed to attached sheet")
        try require(window.makeFirstResponder(secureField), "menu credential SecureField refused first responder")
        spin(seconds: 0.05)
        guard let fieldEditor = window.firstResponder as? NSTextView else {
            throw EDPUIAutomationFailure(description: "menu credential field editor did not become first responder")
        }
        fieldEditor.insertText("focus-regression", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(seconds: 0.05)
        try require(!secureField.stringValue.isEmpty, "menu credential SecureField did not accept input")
        try require(window.isVisible, "menu credential host window closed after SecureField focus")
        try require(window.attachedSheet == nil, "menu credential focus created a sheet")
        print("SCENARIO=UI_MENU_CREDENTIAL_FOCUS_OK")
        print("RESULT=DRIVE_UI_MENU_CREDENTIAL_FOCUS_OK")
    }

    private static func validateSidebarHitches(
        toggleCount: Int,
        warmupSeconds: TimeInterval
    ) throws {
        let model = EDPVaultViewModel(
            previewConfiguration: EDPPreviewScenarioFactory.configuration(for: .healthyOneDevice)
        )
        let root = AnyView(EDPMainView(model: model).environment(\.colorScheme, .light))
        let window = makeWindow(rootView: root, size: NSSize(width: 900, height: 680))
        defer { window.close() }
        spin(seconds: 0.15)

        guard let contentView = window.contentView,
              let split = findSplitController(in: contentView) else {
            throw EDPUIAutomationFailure(description: "native NSSplitViewController not found for hitch test")
        }
        print("UI_HITCH_AUTOMATION_READY=1")
        fflush(stdout)
        spin(seconds: warmupSeconds)
        print("UI_HITCH_TOGGLES_BEGIN_EPOCH=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        for _ in 0..<toggleCount {
            edpAutomationToggleSidebar(split)
            spin(seconds: 0.25)
        }
        print("UI_HITCH_TOGGLES_END_EPOCH=\(Date().timeIntervalSince1970)")
        fflush(stdout)
    }

    private static func validateSidebarGeometry(
        toggleCount: Int,
        emitScenarioMarkers: Bool
    ) throws {
        let model = EDPVaultViewModel(
            previewConfiguration: EDPPreviewScenarioFactory.configuration(for: .healthyOneDevice)
        )
        let root = AnyView(EDPMainView(model: model).environment(\.colorScheme, .light))
        let window = makeWindow(rootView: root, size: NSSize(width: 900, height: 680))
        defer { window.close() }
        spin(seconds: 0.15)

        guard let contentView = window.contentView,
              let split = findSplitController(in: contentView) else {
            throw EDPUIAutomationFailure(description: "native NSSplitViewController not found")
        }
        try require(split.splitViewItems.count == 2, "split controller item count changed")
        let sidebar = split.splitViewItems[0]
        let detail = split.splitViewItems[1]
        try require(sidebar.minimumThickness == 180, "sidebar minimum thickness changed")
        try require(sidebar.maximumThickness == 220, "sidebar maximum thickness changed")
        try require(sidebar.canCollapse, "sidebar canCollapse disabled")
        try require(!sidebar.canCollapseFromWindowResize, "sidebar auto-collapse on resize re-enabled")
        let splitSize = split.view.bounds.size
        print("UI_SIDEBAR_SPLIT_SIZE=\(splitSize.width)x\(splitSize.height)")
        // The test requests a 900×680 native window. AppKit's toolbar/titlebar
        // consumes part of that height on the GitHub macOS 26 runner, so the
        // actual split content region is currently about 900×622. The product
        // contract is the 900 px narrow width plus EDPMainView's 620 px minimum
        // usable content height, not a runner-specific toolbar height.
        try require(splitSize.width >= 899 && splitSize.width <= 901, "900px split width drifted: \(splitSize.width)")
        try require(splitSize.height >= 619 && splitSize.height <= 681, "split height escaped 620...680: \(splitSize.height)")
        var expandedSidebarWidths = [CGFloat]()
        var collapsedDetailWidths = [CGFloat]()
        for index in 0..<toggleCount {
            let wasCollapsed = sidebar.isCollapsed
            let samples = sampleSidebarTransition(split: split, detail: detail, beforeCollapsed: wasCollapsed)
            try require(sidebar.isCollapsed != wasCollapsed, "sidebar toggle \(index + 1) did not change state")
            try require(samples.count >= 2, "sidebar toggle \(index + 1) did not produce geometry samples")
            try require(isMonotonic(samples.map(\.minX), increasing: wasCollapsed, tolerance: 1.25), "sidebar toggle \(index + 1) detail x overshot/bounced")
            try require(isMonotonic(samples.map(\.width), increasing: !wasCollapsed, tolerance: 1.25), "sidebar toggle \(index + 1) detail width overshot/bounced")
            try require(!containsOverflowChevron(in: window.contentView), "sidebar toggle \(index + 1) rendered overflow chevron")
            try require(detail.viewController.view.frame.maxX <= split.view.bounds.maxX + 1.5, "sidebar toggle \(index + 1) detail clipped right edge")
            try require(detail.viewController.view.frame.minX >= split.view.bounds.minX - 1.5, "sidebar toggle \(index + 1) detail escaped left edge")
            if sidebar.isCollapsed {
                collapsedDetailWidths.append(detail.viewController.view.frame.width)
            } else {
                expandedSidebarWidths.append(sidebar.viewController.view.frame.width)
            }
            if emitScenarioMarkers {
                print("SCENARIO=UI_SIDEBAR_TOGGLE_\(index + 1)_OK")
            }
        }

        try require(expandedSidebarWidths.allSatisfy { $0 >= 179 && $0 <= 221 }, "expanded sidebar width escaped 180...220")
        if let first = collapsedDetailWidths.first {
            try require(collapsedDetailWidths.allSatisfy { abs($0 - first) <= 1.5 }, "collapsed detail width drifted across cycles")
        }
        try require(sidebar.isCollapsed == (toggleCount % 2 == 1), "sidebar final collapse parity mismatch")
        if emitScenarioMarkers {
            print("RESULT=DRIVE_UI_900X680_SIDEBAR_OK")
        }
    }

    private static func sampleSidebarTransition(
        split: NSSplitViewController,
        detail: NSSplitViewItem,
        beforeCollapsed: Bool
    ) -> [(minX: CGFloat, width: CGFloat)] {
        var samples = [(CGFloat, CGFloat)]()
        edpAutomationToggleSidebar(split)
        let deadline = Date().addingTimeInterval(0.9)
        var stableSamples = 0
        var previous: (CGFloat, CGFloat)?
        while Date() < deadline {
            split.view.window?.contentView?.layoutSubtreeIfNeeded()
            let frame = detail.viewController.view.frame
            let current = (frame.minX, frame.width)
            samples.append(current)
            if split.splitViewItems[0].isCollapsed != beforeCollapsed,
               let previous,
               abs(current.0 - previous.0) <= 0.2,
               abs(current.1 - previous.1) <= 0.2 {
                stableSamples += 1
                if stableSamples >= 6 { break }
            } else {
                stableSamples = 0
            }
            previous = current
            spin(seconds: 0.01)
        }
        return samples
    }

    private static func makeWindow(rootView: AnyView, size: NSSize) -> NSWindow {
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        return window
    }

    private static func findSplitController(in view: NSView) -> NSSplitViewController? {
        if let splitView = view as? NSSplitView {
            var responder: NSResponder? = splitView
            while let current = responder {
                if let controller = current as? NSSplitViewController { return controller }
                responder = current.nextResponder
            }
        }
        for subview in view.subviews {
            if let found = findSplitController(in: subview) { return found }
        }
        return nil
    }

    private static func findSecureTextField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        for subview in view.subviews {
            if let found = findSecureTextField(in: subview) { return found }
        }
        return nil
    }

    private static func containsOverflowChevron(in view: NSView?) -> Bool {
        guard let view else { return false }
        if let button = view as? NSButton, button.title == "»" { return true }
        if let text = view as? NSTextField, text.stringValue == "»" { return true }
        return view.subviews.contains { containsOverflowChevron(in: $0) }
    }

    private static func isMonotonic(_ values: [CGFloat], increasing: Bool, tolerance: CGFloat) -> Bool {
        guard values.count > 1 else { return true }
        for (previous, next) in zip(values, values.dropFirst()) {
            if increasing {
                if next + tolerance < previous { return false }
            } else if next - tolerance > previous {
                return false
            }
        }
        return true
    }

    private static func spin(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw EDPUIAutomationFailure(description: message) }
    }
}
