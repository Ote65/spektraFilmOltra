import SwiftUI
import AppKit

struct GradeView: View {
    let snapshot: GradeSnapshot
    let actions: SkinActions

    @State private var recipe: GradeRecipe
    @State private var railTab = 0
    @State private var panelTab = 0
    @State private var activePresetID = ""
    @State private var showCurve = false
    @State private var showTransparency = false
    @State private var showQuality = false
    @State private var showOptics = false
    @State private var exportOpen = false
    @State private var saveOpen = false
    @State private var saveName = ""

    init(snapshot: GradeSnapshot, actions: SkinActions) {
        self.snapshot = snapshot
        self.actions = actions
        _recipe = State(initialValue: snapshot.recipe)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            HStack(spacing: 0) {
                rail
                    .frame(width: 236)

                SkinVerticalHairline()

                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                SkinVerticalHairline()

                panel
                    .frame(width: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkinColor.app)
        .onChange(of: snapshot.recipe) { newValue in
            if newValue != recipe { recipe = newValue }
        }
        .sheet(isPresented: $exportOpen) {
            ExportSettingsSheet(
                photo: snapshot.photo,
                initial: ExportSettings(
                    format: .tiff16, longEdge: 0,
                    directory: nil, filenameTemplate: "{name}-graded"
                ),
                onCancel: { exportOpen = false },
                onExport: { settings in
                    exportOpen = false
                    actions.gradeExport(settings)
                }
            )
        }
        .sheet(isPresented: $saveOpen) { savePresetSheet }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            SkinButton(
                snapshot.origin == .direct ? "照片库" : "显影台",
                icon: "chevron.left", kind: .secondary, height: 28
            ) {
                if snapshot.origin == .direct {
                    actions.backToLibraryFromGrade()
                } else {
                    actions.backToEditor()
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.photo.filename)
                    .font(.skin(13.5, .medium))
                    .foregroundStyle(SkinColor.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(snapshot.handoffMeta)
                    .font(.skin(10.5).monospacedDigit())
                    .foregroundStyle(SkinColor.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("调色台")
                .font(.skin(10.5, .medium))
                .foregroundStyle(SkinColor.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SkinColor.accent.opacity(0.10))
                )

            SkinButton(
                "导出", icon: "square.and.arrow.up", kind: .primary, height: 28,
                disabled: !snapshot.sourceReady
            ) {
                exportOpen = true
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SkinMetric.topBarHeight)
        .background(SkinColor.app)
        .overlay(alignment: .bottom) {
            SkinHairline()
        }
    }

    // MARK: - 左栏

    private var rail: some View {
        VStack(spacing: 0) {
            HStack {
                SkinSegmented(titles: ["LUT", "预设"], selection: $railTab, width: 170)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if railTab == 0 {
                        lutList
                    } else {
                        presetList
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .background(SkinColor.app)
    }

    private var lutList: some View {
        VStack(alignment: .leading, spacing: 2) {
            railRow("无 LUT", subtitle: nil, selected: recipe.lut.path.isEmpty, icon: nil) {
                setLUT("")
            }

            ForEach(snapshot.luts) { lut in
                railRow(
                    lut.name, subtitle: nil,
                    selected: recipe.lut.path == lut.path,
                    icon: "slider.horizontal.3"
                ) {
                    setLUT(lut.path)
                }
            }

            if !recipe.lut.path.isEmpty {
                slider("lut.strength", "LUT 强度", 0...100, step: 1, suffix: "%")
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }

            SkinButton("导入 LUT", icon: "plus", kind: .secondary, height: 28) {
                actions.gradeLUTImported()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(snapshot.presets) { preset in
                railRow(
                    preset.name, subtitle: preset.builtin ? "内置" : "用户",
                    selected: activePresetID == preset.id, icon: nil
                ) {
                    recipe = preset.recipe
                    activePresetID = preset.id
                    actions.gradeRecipeChanged(recipe)
                }
            }

            HStack(spacing: 6) {
                SkinButton("保存当前", kind: .secondary, height: 28) {
                    saveName = ""
                    saveOpen = true
                }

                if let active = snapshot.presets.first(where: {
                    $0.id == activePresetID && !$0.builtin
                }) {
                    SkinButton("删除", kind: .quiet, height: 28) {
                        actions.gradePresetDeleted(active.id)
                        activePresetID = ""
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func railRow(
        _ title: String, subtitle: String?, selected: Bool, icon: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? SkinColor.accent : SkinColor.text3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.skin(11.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? SkinColor.text1 : SkinColor.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .font(.skin(9.5))
                            .foregroundStyle(SkinColor.text4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: subtitle == nil ? 30 : 40)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? SkinColor.surface2 : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 画布

    private var stage: some View {
        ZStack {
            SkinColor.canvas

            RadialGradient(
                colors: [Color(hex: 0x2A241C).opacity(0.45), .clear],
                center: UnitPoint(x: 0.5, y: 0.46),
                startRadius: 8,
                endRadius: 420
            )

            GeometryReader { geo in
                let fit = SkinPrintFit.fit(
                    geo.size,
                    horizontalInset: 110,
                    verticalInset: 100,
                    aspect: snapshot.photo.aspectRatio
                )

                Group {
                    if let preview = snapshot.previewImage {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: fit.width, height: fit.height)
                            .clipped()
                            .shadow(color: .black.opacity(0.5), radius: 26, y: 18)
                    } else {
                        VStack(spacing: 9) {
                            if snapshot.sourceReady {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(SkinColor.text4)
                                Text("暂无预览")
                                    .font(.skin(11))
                                    .foregroundStyle(SkinColor.text3)
                            } else {
                                ProgressView().controlSize(.small)
                                Text(snapshot.origin == .direct
                                    ? "正在解码 RAW…" : "正在生成交接图…")
                                    .font(.skin(11))
                                    .foregroundStyle(SkinColor.text3)
                            }
                        }
                        .frame(width: fit.width, height: fit.height)
                        .background(SkinColor.surface2)
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                if snapshot.phase.isBusy {
                    GradeProgressPill(phase: snapshot.phase)
                        .padding(.bottom, 12)
                }

                HStack {
                    Text(snapshot.handoffMeta)
                        .font(.skin(10).monospacedDigit())
                        .foregroundStyle(SkinColor.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 右栏

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                SkinSegmented(titles: ["光影", "色彩"], selection: $panelTab, width: 168)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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

                    analysisLine

                    if snapshot.sourceReady {
                        adaptiveCard

                        if panelTab == 0 {
                            lightControls
                        } else {
                            colorControls
                        }

                        if !recipe.adaptive.enabled {
                            fold("曲线", isOpen: $showCurve) {
                                slider("light.curve_highlights", "高光点", -100...100, step: 1)
                                slider("light.curve_lights", "亮部点", -100...100, step: 1)
                                slider("light.curve_darks", "暗部点", -100...100, step: 1)
                                slider("light.curve_shadows", "阴影点", -100...100, step: 1)
                            }

                            fold("通透", isOpen: $showTransparency) {
                                slider("transparency.tonal", "明暗通透", 0...100, step: 1)
                                slider("transparency.color", "颜色通透", 0...100, step: 1)
                            }

                            fold("画质", isOpen: $showQuality) {
                                slider("quality.clarity", "清晰度", -100...100, step: 1)
                                slider("quality.texture", "纹理", -100...100, step: 1)
                                slider("quality.dehaze", "去雾", -100...100, step: 1)
                                slider("quality.sharpen_amount", "锐化", 0...100, step: 1)
                                slider("quality.sharpen_radius", "锐化半径", 0.5...3,
                                       step: 0.01, decimals: 2)
                                slider("quality.sharpen_threshold", "锐化阈值", 0...100, step: 1)
                                slider("quality.noise_luminance", "明度降噪", 0...100, step: 1)
                                slider("quality.noise_color", "色彩降噪", 0...100, step: 1)
                            }
                        }

                        fold("光学", isOpen: $showOptics) {
                            slider("optics.vignette_amount", "暗角", -100...100, step: 1)
                            slider("optics.vignette_midpoint", "暗角中心", 0...100, step: 1)
                            slider("optics.vignette_roundness", "暗角圆度", -100...100, step: 1)
                            slider("optics.vignette_feather", "暗角羽化", 0...100, step: 1)
                            slider("optics.grain_amount", "颗粒强度", 0...100, step: 1)
                            slider("optics.grain_size", "颗粒大小", 0...100, step: 1)
                            slider("optics.grain_roughness", "颗粒粗糙度", 0...100, step: 1)
                            slider("optics.chromatic_aberration", "色差", 0...100, step: 1)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("等待交接图…")
                                .font(.skin(10.5))
                                .foregroundStyle(SkinColor.text3)
                        }
                        .padding(.vertical, 12)
                    }

                    if !snapshot.statusMessage.isEmpty {
                        Text(snapshot.statusMessage)
                            .font(.skin(9.5))
                            .foregroundStyle(SkinColor.text4)
                            .lineLimit(2)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .background(SkinColor.app)
    }

    private var analysisLine: some View {
        Group {
            if let analysis = snapshot.analysis {
                HStack(spacing: 8) {
                    Text(String(format: "黑场 %.2f", analysis.blackPoint))
                    Text(String(format: "白场 %.2f", analysis.whitePoint))
                    Text("\(analysis.highlightCast) / \(analysis.shadowCast)")
                }
                .font(.skin(9.5).monospacedDigit())
                .foregroundStyle(SkinColor.text3)
                .lineLimit(1)
            } else {
                Text("等待分析…")
                    .font(.skin(9.5))
                    .foregroundStyle(SkinColor.text4)
            }
        }
    }

    private var lightControls: some View {
        VStack(spacing: 0) {
            slider("light.exposure", "曝光", -5...5, step: 0.05, decimals: 2, suffix: " EV")
            if !recipe.adaptive.enabled {
                slider("light.contrast", "对比度", -100...100, step: 1)
                slider("light.highlights", "高光", -100...100, step: 1)
                slider("light.shadows", "阴影", -100...100, step: 1)
                slider("light.whites", "白色", -100...100, step: 1)
                slider("light.blacks", "黑色", -100...100, step: 1)
                slider("light.midtones", "中间调", -100...100, step: 1)
                slider("light.highlight_rolloff", "高光柔和", 0...100, step: 1)
            }
        }
    }

    private var colorControls: some View {
        VStack(spacing: 0) {
            slider("color.temperature", "色温", -100...100, step: 1)
            slider("color.tint", "色调", -100...100, step: 1)
            if !recipe.adaptive.enabled {
                slider("color.vibrance", "自然饱和度", -100...100, step: 1)
                slider("color.saturation", "饱和度", -100...100, step: 1)
                slider("color.hue_shift", "色相偏移", -180...180, step: 1, suffix: "°")
                slider("color.color_density", "色彩密度", 0...100, step: 1)
            }
        }
    }

    // MARK: - 智能净化

    private var adaptiveCard: some View {
        SkinCard(padding: 10) {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SkinColor.accent)
                    Text("智能净化")
                        .font(.skin(10.5, .medium))
                        .foregroundStyle(SkinColor.text2)
                    Spacer(minLength: 8)
                    SkinToggle(
                        isOn: Binding(
                            get: { recipe.adaptive.enabled },
                            set: { enabled in
                                recipe.adaptive.enabled = enabled
                                actions.gradeRecipeChanged(recipe)
                            }
                        )
                    )
                }

                if recipe.adaptive.enabled {
                    HStack {
                        if let report = snapshot.clarityReport {
                            Text(report.summary)
                                .font(.skin(9.5).monospacedDigit())
                                .foregroundStyle(SkinColor.text3)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text("分析中…")
                                .font(.skin(9.5))
                                .foregroundStyle(SkinColor.text4)
                        }
                        Spacer(minLength: 6)
                    }

                    adaptiveSlider("通透", value: $recipe.adaptive.clarity)
                    adaptiveSlider("色净", value: $recipe.adaptive.color)

                    HStack {
                        Spacer(minLength: 0)
                        SkinButton("一键", icon: "wand.and.stars",
                                   kind: .secondary, height: 26) {
                            guard let report = snapshot.clarityReport else { return }
                            recipe.adaptive.enabled = true
                            recipe.adaptive.clarity = report.suggestedClarity
                            recipe.adaptive.color = report.suggestedColor
                            actions.gradeRecipeChanged(recipe)
                        }
                        .disabled(snapshot.clarityReport == nil)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(SkinMotion.state, value: recipe.adaptive.enabled)
        }
    }

    private func adaptiveSlider(_ label: String, value: Binding<Double>) -> some View {
        GradeValueRow(
            label: label,
            value: value.wrappedValue * 100,
            defaultValue: 0,
            range: 0...100,
            step: 1,
            decimals: 0,
            suffix: ""
        ) { newValue in
            value.wrappedValue = newValue / 100
            actions.gradeRecipeChanged(recipe)
        }
    }

    private func slider(
        _ path: String, _ label: String, _ range: ClosedRange<Double>,
        step: Double, decimals: Int = 0, suffix: String = ""
    ) -> some View {
        GradeValueRow(
            label: label,
            value: recipe.value(for: path),
            defaultValue: GradeRecipe().value(for: path),
            range: range,
            step: step,
            decimals: decimals,
            suffix: suffix
        ) { newValue in
            recipe.setValue(newValue, for: path)
            activePresetID = ""
            actions.gradeRecipeChanged(recipe)
        }
    }

    private func fold<Content: View>(
        _ title: String, isOpen: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GradeFold(title: title, open: isOpen, content: content)
    }

    private func setLUT(_ path: String) {
        recipe.lut.path = path
        activePresetID = ""
        actions.gradeRecipeChanged(recipe)
    }

    // MARK: - 保存预设

    private var savePresetSheet: some View {
        VStack(spacing: 16) {
            Text("保存调色预设")
                .font(.skin(13, .semibold))
                .foregroundStyle(SkinColor.text1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("预设名称", text: $saveName)
                .textFieldStyle(.plain)
                .font(.skin(11.5))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SkinColor.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(SkinColor.hairline, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Spacer()
                SkinButton("取消", kind: .secondary, height: 28) {
                    saveOpen = false
                }
                SkinButton("保存", kind: .primary, height: 28) {
                    actions.gradePresetSaved(saveName, recipe)
                    saveOpen = false
                    saveName = ""
                }
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(SkinColor.surface1)
    }
}

// MARK: - 行控件

private struct GradeValueRow: View {
    let label: String
    let value: Double
    let defaultValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let suffix: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.skin(11.5))
                    .foregroundStyle(SkinColor.text2)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(text)
                    .font(.skin(10.5).monospacedDigit())
                    .foregroundStyle(dirty ? SkinColor.accent : SkinColor.text3)
                    .lineLimit(1)
            }

            SkinSlider(
                value: Binding(get: { value }, set: { onChange($0) }),
                range: range,
                step: step,
                dirty: dirty
            )
        }
        .frame(height: 44)
    }

    private var dirty: Bool { abs(value - defaultValue) > 1e-9 }

    private var text: String {
        var text = String(format: "%.\(decimals)f", value)
        if decimals > 0, text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if range.lowerBound < 0, value > 0 { text = "+" + text }
        return text + suffix
    }
}

private struct GradeFold<Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(SkinMotion.state) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.skin(11.5, .medium))
                        .foregroundStyle(SkinColor.text2)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(SkinColor.text4)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 0) { content }
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            SkinHairline()
        }
    }
}

private struct GradeProgressPill: View {
    let phase: RenderPhase

    var body: some View {
        HStack(spacing: 9) {
            Text(phase.label)
                .font(.skin(10.5, .medium))
                .foregroundStyle(SkinColor.text2)
                .lineLimit(1)

            Text(phase.index == 0 ? "…" : "\(phase.index)/\(max(phase.total, 1))")
                .font(.skin(9.5).monospacedDigit())
                .foregroundStyle(SkinColor.text3)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SkinColor.hairlineStrong)
                    Capsule()
                        .fill(SkinColor.accent)
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: 3)
            }
            .frame(width: 74, height: 3)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(SkinColor.surface1.opacity(0.94))
                .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(SkinColor.hairlineStrong, lineWidth: 1)
        )
    }

    private var fraction: CGFloat {
        guard phase.index > 0, phase.total > 0 else { return 0.38 }
        return CGFloat(min(1, Double(phase.index) / Double(phase.total)))
    }
}
