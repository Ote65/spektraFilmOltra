import SwiftUI

// MARK: - 导出面板

/// 导出面板：居中浮卡、四个圆角、无顶部横条。
/// 选项按参考图排成「标签 + 下拉行」；保存动画只走「转圈 → 对勾」两拍，不显示进度条。
struct MExportSheet: View {
    let filename: String
    let phaseLabel: String
    /// 原图真实长边，用于「最大可用尺寸」的具体像素数。
    var originalLongEdge: Int = 0
    /// 原片还没读完时不能导出：`session.export` 会以 `.busy` 立刻失败。
    var canExport: Bool = true
    /// 读取已经失败（而不是仍在读取），副标题需要给出失败提示而不是「正在读取原片…」。
    var readFailed: Bool = false
    let onClose: () -> Void
    let onReturnHome: () -> Void
    /// 相册写入是后台静默的，失败时用调用方的 toast 说明「文件已在 App 内」。
    var onNote: (String) -> Void = { _ in }
    let onExport: (Int, Int, Double, Bool, @escaping (Result<URL, Error>) -> Void) -> Void

    /// 指针指向 `formats` 的下标；初始值来自设置里的默认导出格式。
    @State private var formatIndex = MobileSettings.defaultExportFormatIndex
    /// 0 最大可用尺寸、1 2048、2 4096。
    @State private var edgeIndex = MobileSettings.defaultExportEdgeIndex
    /// 0 100%、1 95%、2 90%、3 80%。
    @State private var qualityIndex = MobileSettings.defaultExportQualityIndex
    /// 本次导出是否合成水印；初始值跟随设置里的水印开关。
    @State private var addWatermark = MWatermarkStore.load().enabled
    /// 设置里关闭「导出时添加水印」后，导出面板不再给出这个勾选。
    @State private var watermarkAvailable = MWatermarkStore.load().enabled
    @State private var showMore = false
    @State private var phase: MExportPhase = .idle
    /// 完成对勾的入场动画开关。
    @State private var donePop = false
    @Environment(\.mSafeInsets) private var insets

    private enum MExportPhase {
        case idle
        case exporting
        case done
    }

    private struct Format {
        /// 引擎档位：0 sRGB TIFF16、1 ProPhoto TIFF16、2 ACES EXR、3 JPEG。
        let id: Int
        let title: String
        let space: String
        let bitDepth: String
    }

    private let formats: [Format] = [
        Format(id: 3, title: "JPEG", space: "sRGB", bitDepth: "8-bit"),
        Format(id: 0, title: "TIFF · sRGB 16-bit", space: "sRGB", bitDepth: "16-bit"),
        Format(id: 1, title: "TIFF · ProPhoto 16-bit", space: "ProPhoto RGB", bitDepth: "16-bit 线性"),
        Format(id: 2, title: "EXR · ACES half", space: "ACES2065-1", bitDepth: "16-bit half"),
    ]
    private let qualityValues = [100, 95, 90, 80]

    private var format: Format { formats[min(max(formatIndex, 0), formats.count - 1)] }
    private var isJPEG: Bool { format.id == 3 }

    /// 居中浮卡：收窄成小窗，左右留白更足。
    private var cardWidth: CGFloat { min(insets.size.width - 64, 330) }

    var body: some View {
        ZStack {
            // scrim：导出进行中不允许点空白关闭，防止半途丢上下文。
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture {
                    guard phase != .exporting else { return }
                    withAnimation(MMotion.pill) { onClose() }
                }
                .transition(.opacity)

            card
                .transition(.scale(0.94).combined(with: .opacity))
        }
        // 截图验收：等原片读完再自动开跑导出（原片没读完时 export 会以 .busy 立刻失败）
        .onChange(of: canExport) { _, ready in
            guard ready, DebugLaunch.exportAutoStart, phase == .idle else { return }
            beginExport()
        }
        .task {
            guard canExport, DebugLaunch.exportAutoStart, phase == .idle else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if phase == .idle { beginExport() }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            Text(subtitle)
                .font(.mSans(12, .medium))
                .foregroundStyle(phase == .done ? MColor.brass : MColor.text3)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 20)

            switch phase {
            case .idle:
                optionRows
            case .exporting, .done:
                statusBlock
            }
        }
        .padding(.bottom, 14)
        .frame(width: cardWidth)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                    .fill(MColor.surface1.opacity(0.92))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: MRadius.sheet, style: .continuous)
                .strokeBorder(MColor.hairlineStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 26, y: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                guard phase != .exporting else { return }
                MHaptic.light()
                withAnimation(MMotion.pill) { onClose() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MColor.text2)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MColor.surface3))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(phase == .exporting)
            .opacity(phase == .exporting ? 0.35 : 1)
            .accessibilityLabel("关闭")

            Spacer(minLength: 0)

            Text(phaseTitle)
                .font(.mSans(15, .semibold))
                .foregroundStyle(MColor.text1)
                .lineLimit(1)

            Spacer(minLength: 0)

            confirmButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private var confirmButton: some View {
        Button {
            switch phase {
            case .idle:
                beginExport()
            case .exporting:
                break
            case .done:
                withAnimation(MMotion.pill) { onReturnHome() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(phase == .exporting ? MColor.surface3 : MColor.brass)
                switch phase {
                case .exporting:
                    // 进行中的转圈只留在卡片中央，右上角退成禁用态，避免两个转圈抢视线。
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MColor.text4)
                case .idle:
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canExport ? MColor.brassInk : MColor.text4)
                case .done:
                    Image(systemName: "house.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MColor.brassInk)
                }
            }
            .frame(width: 32, height: 32)
            .opacity(phase == .idle && !canExport ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(phase == .exporting || (phase == .idle && !canExport))
        .accessibilityLabel(phase == .done ? "完成并返回" : "确认导出")
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: return "导出设置"
        case .exporting: return "正在导出"
        case .done: return "导出完成"
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle:
            if canExport { return "副本将保存到设备" }
            return readFailed ? "原片读取失败，请返回重试" : "正在读取原片…"
        case .exporting:
            return phaseLabel.isEmpty ? "正在印相…" : phaseLabel
        case .done:
            return "副本已保存到设备"
        }
    }

    // MARK: 选项

    private var optionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("文件类型") { formatField }
            field("尺寸") { edgeField }
            field("图像品质") { qualityField }
            if watermarkAvailable {
                watermarkOption
            }

            hairline

            moreOptions
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var formatField: some View {
        Menu {
            ForEach(Array(formats.enumerated()), id: \.offset) { item in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { formatIndex = item.offset }
                } label: {
                    if item.offset == formatIndex {
                        Label(item.element.title, systemImage: "checkmark")
                    } else {
                        Text(item.element.title)
                    }
                }
            }
        } label: {
            fieldChrome {
                Text(format.title)
                    .font(.mSans(13.5, .medium))
                    .foregroundStyle(MColor.text1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .accessibilityLabel("文件类型")
        .accessibilityValue(format.title)
    }

    private var edgeField: some View {
        Menu {
            ForEach(0..<3, id: \.self) { index in
                Button {
                    MHaptic.tick()
                    withAnimation(MMotion.state) { edgeIndex = index }
                } label: {
                    if index == edgeIndex {
                        Label(edgeTitle(index), systemImage: "checkmark")
                    } else {
                        Text(edgeTitle(index))
                    }
                }
            }
        } label: {
            fieldChrome {
                VStack(alignment: .leading, spacing: 1) {
                    Text(edgeTitle(edgeIndex))
                        .font(.mSans(13.5, .medium))
                        .foregroundStyle(MColor.text1)
                        .lineLimit(1)
                    Text(edgeMeta)
                        .mMeta(9, color: MColor.text3)
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .accessibilityLabel("尺寸")
        .accessibilityValue(edgeTitle(edgeIndex))
    }

    @ViewBuilder
    private var qualityField: some View {
        if isJPEG {
            Menu {
                ForEach(Array(qualityValues.enumerated()), id: \.offset) { item in
                    Button {
                        MHaptic.tick()
                        withAnimation(MMotion.state) { qualityIndex = item.offset }
                    } label: {
                        if item.offset == qualityIndex {
                            Label("\(item.element)%", systemImage: "checkmark")
                        } else {
                            Text("\(item.element)%")
                        }
                    }
                }
            } label: {
                fieldChrome {
                    Text("\(qualityValues[min(qualityIndex, qualityValues.count - 1)])%")
                        .font(.mSans(13.5, .medium).monospacedDigit())
                        .foregroundStyle(MColor.text1)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .accessibilityLabel("图像品质")
        } else {
            fieldChrome(chevron: false) {
                HStack(spacing: 7) {
                    Text("无损")
                        .font(.mSans(13.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Text("· \(format.bitDepth)")
                        .mMeta(9.5, color: MColor.text3)
                }
            }
            .accessibilityLabel("图像品质")
            .accessibilityValue("无损")
        }
    }

    /// 单次导出的水印开关：取消勾选就不合成水印，其余参数仍走设置里的水印配置。
    private var watermarkOption: some View {
        Button {
            MHaptic.tick()
            withAnimation(MMotion.state) { addWatermark.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: addWatermark ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(addWatermark ? MColor.brass : MColor.text3)
                Text("添加水印")
                    .font(.mSans(12.5, .medium))
                    .foregroundStyle(MColor.text1)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加水印")
        .accessibilityValue(addWatermark ? "开启" : "关闭")
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                MHaptic.tick()
                withAnimation(MMotion.state) { showMore.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("更多选项")
                        .font(.mSans(12.5, .medium))
                        .foregroundStyle(MColor.text2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MColor.text3)
                        .rotationEffect(.degrees(showMore ? 90 : 0))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                VStack(spacing: 8) {
                    infoRow("文件名", filename)
                    infoRow("色彩空间", format.space)
                    infoRow("位深", format.bitDepth)
                    infoRow("输出长边", edgeMeta)
                    infoRow("保存位置", "相册 · 文件 App")
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 保存动画只走两拍：转圈 → 对勾。不放进度条，也不再展开选项行。
    private var statusBlock: some View {
        Group {
            switch phase {
            case .exporting:
                ProgressView()
                    .tint(MColor.text2)
                    .scaleEffect(1.15)
                    .transition(.opacity.combined(with: .scale(0.7)))
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MColor.brassInk)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(MColor.brass))
                    .scaleEffect(donePop ? 1 : 0.55)
                    .opacity(donePop ? 1 : 0)
                    .onAppear {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                            donePop = true
                        }
                    }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 组件

    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.mSans(11, .medium))
                .foregroundStyle(MColor.text3)
            content()
        }
    }

    private func fieldChrome<Content: View>(
        chevron: Bool = true, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MColor.text3)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                .fill(MColor.surface2.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MRadius.control, style: .continuous)
                .strokeBorder(MColor.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .mMeta(10, color: MColor.text3)
            Spacer(minLength: 0)
            Text(value)
                .font(.mSans(10.5, .medium))
                .foregroundStyle(MColor.text2)
                .lineLimit(1)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(MColor.hairline)
            .frame(height: 1)
    }

    // MARK: 行为

    private func edgeTitle(_ index: Int) -> String {
        index == 0 ? "最大可用尺寸" : (index == 1 ? "2048 px" : "4096 px")
    }

    private var edgeMeta: String {
        switch edgeIndex {
        case 0:
            return originalLongEdge > 0 ? "原图长边 \(originalLongEdge) px" : "按原图长边"
        case 1:
            return "长边 2048 px"
        default:
            return "长边 4096 px"
        }
    }

    private func beginExport() {
        guard phase == .idle, canExport else { return }
        MHaptic.medium()
        donePop = false
        withAnimation(MMotion.state) { phase = .exporting }
        let quality = isJPEG ? Double(qualityValues[min(qualityIndex, qualityValues.count - 1)]) / 100 : 0.95
        onExport(format.id, edgeIndex, quality, addWatermark && watermarkAvailable) { result in
            switch result {
            case .success(let url):
                // 默认保存到相册：成功不打扰，失败/被拒时必须告诉用户文件还在 App 内。
                PhotoLibraryExport.save(url) { outcome in
                    switch outcome {
                    case .saved:
                        break
                    case .denied:
                        onNote("未授权相册 · 文件已导出到 App 内")
                    case .failed:
                        onNote("相册写入失败 · 文件已导出到 App 内")
                    }
                }
                withAnimation(MMotion.state) { phase = .done }
            case .failure:
                withAnimation(MMotion.state) { phase = .idle }
            }
        }
    }
}

