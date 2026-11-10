import SwiftUI

struct ProPanel: View {
    let pages: [ParamPage]
    let actions: SkinActions

    @State private var page = 0
    @State private var values: [String: Double]
    @State private var toggles: [String: Bool]

    init(pages: [ParamPage], actions: SkinActions = .preview) {
        self.pages = pages
        self.actions = actions
        var sliderValues: [String: Double] = [:]
        var toggleValues: [String: Bool] = [:]
        for page in pages {
            for group in page.groups {
                for row in group.rows {
                    switch row.control {
                    case .slider(let value, _, _):
                        sliderValues[row.id] = value
                    case .toggle(let isOn):
                        toggleValues[row.id] = isOn
                    case .choice:
                        break
                    }
                }
            }
        }
        _values = State(initialValue: sliderValues)
        _toggles = State(initialValue: toggleValues)
    }

    var body: some View {
        VStack(spacing: 0) {
            SkinUnderlineTabs(
                titles: pages.map(\.title),
                selection: $page,
                fontSize: 10.5,
                height: 30
            )
            .padding(.horizontal, 14)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(currentPage.groups.enumerated()), id: \.element.id) { item in
                        if item.offset > 0 {
                            Spacer().frame(height: 8)
                        }

                        Text(item.element.title)
                            .font(.groupLabel)
                            .tracking(0.4)
                            .foregroundStyle(SkinColor.text3)
                            .padding(.bottom, 2)

                        ForEach(item.element.rows) { row in
                            ParamRowView(
                                row: row,
                                value: sliderBinding(for: row),
                                toggle: toggleBinding(for: row),
                                range: range(for: row)
                            )
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
                        .fill(SkinColor.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SkinRadius.panel, style: .continuous)
                        .strokeBorder(SkinColor.hairline, lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var currentPage: ParamPage {
        pages[min(max(page, 0), pages.count - 1)]
    }

    private func sliderBinding(for row: ParamRow) -> Binding<Double> {
        Binding(
            get: { values[row.id] ?? fallbackValue(for: row) },
            set: { newValue in
                values[row.id] = newValue
                actions.proChanged(row.id, newValue)
            }
        )
    }

    private func toggleBinding(for row: ParamRow) -> Binding<Bool> {
        Binding(
            get: { toggles[row.id] ?? fallbackToggle(for: row) },
            set: { newValue in
                toggles[row.id] = newValue
                actions.proToggled(row.id, newValue)
            }
        )
    }

    private func fallbackValue(for row: ParamRow) -> Double {
        if case .slider(let value, _, _) = row.control { return value }
        return 0
    }

    private func fallbackToggle(for row: ParamRow) -> Bool {
        if case .toggle(let isOn) = row.control { return isOn }
        return false
    }

    private func range(for row: ParamRow) -> ClosedRange<Double> {
        let value = fallbackValue(for: row)
        switch row.id {
        case "white_level":
            return 0...1
        case "black_level":
            return 0...0.08
        case "exposure_compensation_ev":
            return -5...5
        case "raw_temperature":
            return 1000...10000
        case "film_format_mm":
            return 8...120
        case "preflash_exposure":
            return 0...0.3
        default:
            if value < 0 {
                let bound = max(2, abs(value) * 1.6)
                return -bound...bound
            }
            return 0...max(2, value * 1.6)
        }
    }
}

private struct ParamRowView: View {
    let row: ParamRow
    @Binding var value: Double
    @Binding var toggle: Bool
    let range: ClosedRange<Double>

    @State private var hovered = false

    var body: some View {
        Group {
            switch row.control {
            case .slider(_, _, let dirty):
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.skin(12))
                            .foregroundStyle(labelColor)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(displayValue(for: row))
                            .font(.readout)
                            .foregroundStyle(dirty ? SkinColor.accent : SkinColor.text3)
                            .lineLimit(1)
                    }

                    SkinSlider(
                        value: $value,
                        range: range,
                        step: 0.01,
                        dirty: dirty,
                        isEnabled: row.isEnabled
                    )
                }
                .frame(height: 44)

            case .toggle:
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.skin(12))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    SkinToggle(isOn: $toggle, isEnabled: row.isEnabled)
                }
                .frame(height: 44)

            case .choice(let text):
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.skin(12))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(text)
                        .font(.skin(11.5))
                        .foregroundStyle(hovered ? SkinColor.text1 : SkinColor.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(SkinColor.text4)
                }
                .frame(height: 44)
            }
        }
        .opacity(row.isEnabled ? 1 : 0.36)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .help(row.label)
    }

    private var labelColor: Color {
        guard row.isEnabled else { return SkinColor.text4 }
        return hovered ? SkinColor.text1 : SkinColor.text2
    }

    private func displayValue(for row: ParamRow) -> String {
        guard case .slider(let initial, let text, _) = row.control else { return "" }
        guard abs(value - initial) > 1e-9 else { return text }
        if value >= 100 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
