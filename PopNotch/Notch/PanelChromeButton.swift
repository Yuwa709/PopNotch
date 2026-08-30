import SwiftUI

/// One panel-chrome button in the neck band: the clipboard door, the back
/// arrow, and whatever future screens need. Matches CaffeinateControl's
/// metrics so the band's chrome reads as one family.
struct PanelChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
