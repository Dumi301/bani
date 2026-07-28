import SwiftUI

// PHASE-0 STUB — replaced by worker unit C (Log cluster). Keeps the shell green.
struct LogView: View {
    var body: some View {
        ZStack {
            Color("BaniCanvas").ignoresSafeArea()
            Text("Log")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundStyle(Color("BaniInk"))
        }
    }
}
