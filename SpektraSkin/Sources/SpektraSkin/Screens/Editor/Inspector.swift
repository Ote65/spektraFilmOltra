import SwiftUI

struct InspectorView: View {
    let snapshot: EditorSnapshot
    let actions: SkinActions

    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 10) {
                histogramCard
                    .padding(.horizontal, 14)

                Group {
                    if mode == 0 {
                        QuickPanel(snapshot: snapshot, actions: actions)
                            .transition(.opacity)
                    } else {
                        ProPanel(pages: snapshot.proPages, actions: actions)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 10)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity)
        }
        .background(SkinColor.app)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SkinSegmented(titles: ["快速", "专业"], selection: $mode, width: 168)

            Spacer(minLength: 0)

            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.skin(10.5, .medium).monospacedDigit())
                    .foregroundStyle(SkinColor.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(SkinColor.accent.opacity(0.10))
                    )
                    .help("\(badgeCount) 项参数已调整")
            }

            SkinButton("重置", kind: .secondary, height: 26) {
                actions.resetParameters()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var histogramCard: some View {
        SkinCard(padding: 10) {
            VStack(spacing: 6) {
                HStack {
                    Text("直方图")
                        .font(.skin(10.5, .medium))
                        .foregroundStyle(SkinColor.text2)

                    Spacer()

                    Text("亮度 / RGB")
                        .font(.skin(9.5))
                        .foregroundStyle(SkinColor.text4)
                }

                SkinHistogram(data: snapshot.histogram)
            }
        }
    }

    private var badgeCount: Int {
        if mode == 0 {
            return snapshot.dirtyCount
        }
        return snapshot.proPages
            .flatMap(\.groups)
            .flatMap(\.rows)
            .filter {
                if case .slider(_, _, let dirty) = $0.control { return dirty }
                return false
            }
            .count
    }
}

// MARK: - Quick panel

struct QuickPanel: View {
    let snapshot: EditorSnapshot
    let actions: SkinActions

    @State private var values: [String: Double]
    @State private var padX: Double
    @State private var padY: Double

    init(snapshot: EditorSnapshot, actions: SkinActions = .preview) {
        self.snapshot = snapshot
        self.actions = actions
        let axes = snapshot.quickGroups.flatMap(\.axes)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: axes.map { ($0.id, $0.value) }))
        let pad = snapshot.quickGroups.compactMap(\.pad).first
        _padX = State(initialValue: pad?.x ?? 0)
        _padY = State(initialValue: pad?.y ?? 0)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.quickGroups.enumerated()), id: \.element.id) { item in
                    if item.offset > 0 {
                        Spacer().frame(height: 12)
                    }

                    Text(item.element.title)
                        .font(.groupLabel)
                        .tracking(0.4)
                        .foregroundStyle(SkinColor.text3)
                        .padding(.bottom, 3)

                    if let pad = item.element.pad {
                        colorPad(pad)
                    }

                    ForEach(item.element.axes) { axis in
                        QuickAxisRow(
                            axis: axis,
                            value: binding(for: axis),
                            isAvailable: axis.unavailableReason == nil
                        )
                    }
                }

                Spacer().frame(height: 10)

                Button {
                    actions.resetParameters()
                } label: {
                    Text("重置快速")
                        .font(.skin(11.5, .medium))
                        .foregroundStyle(SkinColor.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(SkinColor.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(SkinColor.hairline, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
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
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func binding(for axis: QuickAxis) -> Binding<Double> {
        Binding(
            get: { values[axis.id] ?? axis.value },
            set: { newValue in
                values[axis.id] = newValue
                actions.quickChanged(axis.id, newValue)
            }
        )
    }

    private func colorPad(_ pad: QuickPad) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(pad.title)
                    .font(.skin(12))
                    .foregroundStyle(SkinColor.text2)
                Spacer()
            }

            HStack {
                Spacer()
                SkinColorPad(x: padXBinding, y: padYBinding)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("冷暖  \(ccText(padX))")
                    .font(.skin(10.5).monospacedDigit())
                    .foregroundStyle(abs(padX) > 0.01 ? SkinColor.accent : SkinColor.text3)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("品红  \(ccText(padY))")
                    .font(.skin(10.5).monospacedDigit())
                    .foregroundStyle(abs(padY) > 0.01 ? SkinColor.accent : SkinColor.text3)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.vertical, 3)
    }

    private var padXBinding: Binding<Double> {
        Binding(
            get: { padX },
            set: { newValue in
                padX = newValue
                actions.padChanged(newValue, padY)
            }
        )
    }

    private var padYBinding: Binding<Double> {
        Binding(
            get: { padY },
            set: { newValue in
                padY = newValue
                actions.padChanged(padX, newValue)
            }
        )
    }

    private func ccText(_ value: Double) -> String {
        let cc = value * 0.6
        if abs(cc) < 0.05 { return "0 CC" }
        let text = String(format: "%.1f", cc)
            .replacingOccurrences(of: ".0", with: "")
        return (cc > 0 ? "+\(text)" : text) + " CC"
    }
}

private struct QuickAxisRow: View {
    let axis: QuickAxis
    @Binding var value: Double
    let isAvailable: Bool

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(axis.label)
                    .font(.skin(12))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(axis.text(for: value))
                    .font(.readout)
                    .foregroundStyle(axis.isDirty ? SkinColor.accent : SkinColor.text3)
                    .lineLimit(1)
            }

            SkinSlider(
                value: $value,
                range: axis.range,
                step: axis.step,
                dirty: axis.isDirty,
                isEnabled: isAvailable
            )
        }
        .frame(height: 46)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .help(axis.unavailableReason ?? axis.label)
    }

    private var labelColor: Color {
        if !isAvailable { return SkinColor.text4 }
        return hovered ? SkinColor.text1 : SkinColor.text2
    }
}
