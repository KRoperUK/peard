import PeardCore
import SwiftUI

/// Picking an earlier time for a moment about to be sent.
///
/// Bounded to the last 24 hours, which is also what the server accepts, so there
/// is no time on the wheel that would come back refused.
struct RewindSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Captured when the sheet opens, so the range does not creep while it is up.
    private let now: Date
    @State private var date: Date
    /// `nil` means "it happened just now".
    private let onPick: (Date?) -> Void

    init(initial: Date?, now: Date = Date(), onPick: @escaping (Date?) -> Void) {
        self.now = now
        self.onPick = onPick
        _date = State(initialValue: initial ?? now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "When it happened",
                        selection: $date,
                        in: Rewind.range(loggedAt: now),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("Up to 24 hours back. It will show as Rewound, so everyone knows it was logged later.")
                }

                Section {
                    Button("It happened just now") {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PearColor.background)
            .navigationTitle("Rewind")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onPick(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
