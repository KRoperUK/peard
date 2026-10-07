import PeardCore
import SwiftUI

/// Millilitres or fluid ounces (#324): how water is drawn, everywhere.
///
/// The user's, not a connection's — it sits with Appearance and Low Data, the
/// other things in Settings that belong to the phone's owner, and a change
/// applies to every connection at once. Display only: amounts are stored and
/// sent in millilitres whichever is chosen, so nothing already logged moves and
/// no past total changes.
struct WaterUnitSection: View {
    let app: AppModel

    var body: some View {
        Section {
            Picker("Water units", selection: Binding(
                get: { app.waterUnit },
                set: { app.waterUnit = $0 }
            )) {
                ForEach(WaterUnit.allCases, id: \.self) { unit in
                    Text(unit.symbol).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Water units")
        } header: {
            Text("Water units")
        } footer: {
            Text("How amounts of water are shown, in every connection. Logged amounts are kept in millilitres, so switching changes nothing already logged.")
        }
    }
}
