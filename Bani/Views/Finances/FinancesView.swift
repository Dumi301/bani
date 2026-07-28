import SwiftUI

// PHASE-0 STUB — replaced by worker unit D (Finances cluster). Keeps the shell green.
struct FinancesView: View {
    var body: some View {
        ZStack {
            Color("BaniCanvas").ignoresSafeArea()
            Text("Finances")
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundStyle(Color("BaniInk"))
        }
    }
}
