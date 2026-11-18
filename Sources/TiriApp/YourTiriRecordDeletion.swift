import SwiftUI
import TiriCore

extension YourTiriModel {
    var listedChanges: [PersonalChange] {
        recordVisibility?.visible(changes) ?? changes
    }

    func deleteChangeRecord(_ change: PersonalChange) {
        do {
            // Reload before writing so a damaged file is never silently replaced.
            var visibility = try ChangeRecordVisibility()
            try visibility.delete(change.id)
            recordVisibility = visibility
        } catch {
            model?.showToast(title: String(localized: "Couldn't hide this record"),
                             detail: "\(error)", symbol: "exclamationmark.triangle", tint: .orange)
        }
    }
}

struct DeleteChangeRecordButton: View {
    let change: PersonalChange
    @Environment(AppModel.self) private var model

    var body: some View {
        Divider()
        Button("Hide Record") { model.yourTiri.deleteChangeRecord(change) }
            .help("Hide this record from the list. The change keeps its current state.")
    }
}
