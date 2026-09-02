import SwiftUI

private enum EDPActivityFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case device = "设备"
    case mount = "挂载"
    case security = "安全"
    case error = "错误"

    var id: String { rawValue }
}

struct EDPActivityView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var filter: EDPActivityFilter = .all

    private var filteredActivities: [EDPXPCActivity] {
        model.snapshot.activities.filter { activity in
            switch filter {
            case .all:
                return true
            case .device:
                return activity.deviceID != nil && activity.partitionType == nil && activity.level != "error"
            case .mount:
                return activity.partitionType != nil
                    || activity.message.contains("挂载")
                    || activity.message.contains("卸载")
                    || activity.message.contains("推出")
            case .security:
                return activity.message.contains("密码")
                    || activity.message.contains("凭据")
                    || activity.message.contains("权限")
                    || activity.message.contains("磁盘访问")
            case .error:
                return activity.level == "error"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("活动筛选", selection: $filter) {
                ForEach(EDPActivityFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.top, EDPTheme.Spacing.lg)
            .padding(.horizontal, EDPTheme.Spacing.lg)
            .accessibilityLabel("活动筛选")

            if model.snapshot.activities.isEmpty {
                EDPEmptyState(
                    "暂无活动记录",
                    message: "设备插入、挂载和凭据变更会显示在这里。",
                    systemImage: "clock.arrow.circlepath"
                )
            } else if filteredActivities.isEmpty {
                EDPEmptyState(
                    "当前筛选没有记录",
                    message: "切换上方筛选条件查看其他活动。",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredActivities.enumerated()), id: \.element.id) { index, activity in
                            EDPActivityTimelineRow(activity: activity, isLast: index == filteredActivities.count - 1)
                        }
                    }
                    .padding(.horizontal, EDPTheme.Spacing.lg)
                    .padding(.vertical, EDPTheme.Spacing.md)
                }
            }
        }
        .navigationTitle("活动")
    }
}

private struct EDPActivityTimelineRow: View {
    let activity: EDPXPCActivity
    let isLast: Bool

    private var isError: Bool { activity.level == "error" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: isError ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(isError ? .callout : .caption2)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                        .frame(minHeight: 42)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(activity.message)
                    .font(.body)
                    .foregroundStyle(isError ? Color.red : Color.primary)
                HStack(spacing: 6) {
                    Text(activity.timestamp)
                    if let type = activity.partitionType,
                       let kind = EDPPartitionKind(rawValue: type) {
                        Text("·")
                        Text(kind.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 16)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
