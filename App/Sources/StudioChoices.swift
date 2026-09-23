import SwiftUI

/// A row-wrapping set of choice buttons for the Studio inspector — used instead of a segmented
/// control where the choices would not fit the 260-point column (a segmented control can't shrink,
/// so six aspect ratios pushed the whole panel wider than its column and over the dividers).
struct StudioChoices<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    var columns: Int = 3

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: max(1, min(columns, options.count))), spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? StudioStyle.blue : StudioStyle.control))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
