import SwiftUI
import DayCueCore

/// 写入状态标签。
///
/// 四类文案的唯一渲染点：文案来自 ExternalWriteState.displayName，
/// 视图层不允许自己拼"已写入"这种字符串，否则一旦逻辑改了就会出现两处不一致的措辞。
struct WriteStatePill: View {
    let state: ExternalWriteState
    var compact: Bool = false

    var body: some View {
        Text(state.displayName)
            .font(labelFont)
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("写入状态：" + state.displayName)
    }

    private var labelFont: Font {
        compact ? .caption2.weight(.medium) : .caption.weight(.medium)
    }

    private var tint: Color {
        switch state {
        case .written:
            return .green
        case .waitingForPermission, .pending, .notRequested:
            return .orange
        case .failed:
            return .red
        case .unknown, .needsReconciliation:
            return .purple
        }
    }
}

/// 捕获状态小标签。
struct CaptureStatusPill: View {
    let status: CaptureStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .local:
            return .gray
        case .extracting:
            return .blue
        case .extracted:
            return .green
        case .failed:
            return .red
        case .needsClarification:
            return .purple
        }
    }
}

/// 权限状态行：状态 + 去系统设置。
struct PermissionRow: View {
    let title: String
    let detail: String?
    let status: PermissionStatus
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(status.displayName)
                .font(.subheadline)
                .foregroundStyle(status.isGranted ? Color.green : Color.secondary)
            if let action, status.shouldOfferSystemSettings {
                Button("去设置", action: action)
                    .buttonStyle(.borderless)
                    .font(.subheadline)
            }
        }
    }
}

/// 空状态。文案必须给出下一步动作，而不是只说"暂无数据"。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

/// 时间展示的统一入口。任何视图要显示截止/提醒时间都必须走它，
/// 避免某处又把日期型截止日渲染成带时刻的字符串。
struct TimeSummaryText: View {
    let task: TaskRecord
    var font: Font = .subheadline

    var body: some View {
        Text(TaskTimeDisplay.scheduleSummary(for: task))
            .font(font)
            .foregroundStyle(.secondary)
    }
}
