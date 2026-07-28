import SwiftUI

// PHASE-0 STUB — replaced by worker unit E (Settings + appearance). Keeps the shell green.
struct SettingsView: View {
    var body: some View {
        ZStack {
            Color("BaniCanvas").ignoresSafeArea()
            Text("Settings")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundStyle(Color("BaniInk"))
        }
    }
}
