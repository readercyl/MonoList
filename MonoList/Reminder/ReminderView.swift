import SwiftUI

@MainActor
final class ReminderPresentationModel: ObservableObject {
    @Published var remainingSeconds = 3
    var isPaused = false
}

struct ReminderView: View {
    var title = "待办提醒"
    var statusText: String?
    var isFocusReminder = false
    let totalCount: Int
    let taskTexts: [String]
    @ObservedObject var model: ReminderPresentationModel
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            if isFocusReminder {
                focusReminder
            } else {
                standardReminder
            }
        }
        .onHover { model.isPaused = $0 }
    }

    private var focusReminder: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("关闭提醒")
            }

            Button(action: onOpen) {
                Text(taskTexts.first ?? "")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.35)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 21)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 17))
    }

    private var standardReminder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(statusText ?? "\(totalCount) 项")
                    .foregroundStyle(.secondary)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(taskTexts.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(.secondary)
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("悬停可暂停")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }
}
