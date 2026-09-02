import SwiftUI

enum EDPMainSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case devices = "设备"
    case activity = "活动"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .devices: return "externaldrive"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct EDPNativeSidebarView: View {
    @Binding var section: EDPMainSection?

    var body: some View {
        List(EDPMainSection.allCases, selection: $section) { item in
            Label(item.rawValue, systemImage: item.icon)
                .padding(.vertical, 3)
                .tag(item)
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
