import SwiftUI

@MainActor
final class ReminderPresentationModel: ObservableObject {
    @Published var remainingSeconds = 3
    var isPaused = false
}

struct ReminderView: View {
    var title = "待办提醒"
    let totalCount: Int
    let taskTexts: [String]
    @ObservedObject var model: ReminderPresentationModel
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        standardReminder
        .onHover { model.isPaused = $0 }
    }

    private var standardReminder: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(totalCount) 项")
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
