import SwiftUI

struct PresetRail: View {
    let presets: PresetCatalog
    let actions: SkinActions

    @State private var tab = 0
    @State private var query = ""
    @State private var brand = "全部"
    @State private var selectedFilmID: String
    @State private var selectedPaperID: String

    init(presets: PresetCatalog, currentFilmID: String, currentPaperID: String, actions: SkinActions) {
        self.presets = presets
        self.actions = actions
        _selectedFilmID = State(initialValue: currentFilmID)
        _selectedPaperID = State(initialValue: currentPaperID)
    }

    var body: some View {
        VStack(spacing: 10) {
            SkinUnderlineTabs(
                titles: [
                    "胶片 \(presets.films.count)",
                    "相纸 \(presets.papers.count)",
                ],
                selection: $tab,
                fontSize: 11.5,
                height: 26
            )

            SkinSearchField(
                placeholder: "搜索胶片或相纸",
                text: $query,
                width: nil,
                height: 32,
                fontSize: 11.5
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                ForEach(["全部", "柯达", "富士"], id: \.self) { item in
                    RailBrandChip(title: item, selected: brand == item) {
                        withAnimation(SkinMotion.state) { brand = item }
                    }
                }
                Spacer(minLength: 0)
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(entries) { preset in
                        PresetCard(
                            preset: preset,
                            selected: selectedID == preset.id
                        ) {
                            if tab == 0 {
                                selectedFilmID = preset.id
                                actions.selectFilm(preset.id)
                            } else {
                                selectedPaperID = preset.id
                                actions.selectPaper(preset.id)
                            }
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(SkinColor.app)
    }

    private var selectedID: String {
        tab == 0 ? selectedFilmID : selectedPaperID
    }

    private var entries: [PresetItem] {
        let source = tab == 0 ? presets.films : presets.papers
        var result = source
        if brand != "全部" {
            result = result.filter { $0.brand == brand }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(needle)
                    || $0.meta.localizedCaseInsensitiveContains(needle)
                    || $0.brand.localizedCaseInsensitiveContains(needle)
            }
        }
        return result
    }
}

// MARK: - Brand chip

private struct RailBrandChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.skin(11.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? SkinColor.accent : (hovered ? SkinColor.text1 : SkinColor.text3))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? SkinColor.accent.opacity(0.09) : (hovered ? SkinColor.wash : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selected ? SkinColor.accent.opacity(0.28) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
    }
}

// MARK: - Preset card

private struct PresetCard: View {
    let preset: PresetItem
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SkinPresetSwatch(preset: preset)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.skin(12.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? SkinColor.accentHover : SkinColor.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(preset.meta)
                        .font(.skin(10.5))
                        .foregroundStyle(SkinColor.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(preset.brand)
                    .font(.skin(9, .medium))
                    .tracking(0.6)
                    .foregroundStyle(selected ? SkinColor.accent.opacity(0.75) : SkinColor.text4)
            }
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(height: SkinMetric.presetCardHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? SkinColor.surface2 : (hovered ? SkinColor.surface1 : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        selected ? SkinColor.accent.opacity(0.42) : (hovered ? SkinColor.hairline : .clear),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(SkinMotion.hover, value: hovered)
        .help("\(preset.name)\n\(preset.meta)")
    }
}
