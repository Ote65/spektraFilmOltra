import SwiftUI
import AppKit

/// 导出设置面板：格式 / 长边 / 目录 / 文件名模板。
/// 只提供 Swift 实际能写出的格式，不伪造压缩选项。
struct ExportSettingsSheet: View {
    let photo: PhotoItem
    let notice: String?
    let onCancel: () -> Void
    let onExport: (ExportSettings) -> Void

    @State private var format: ExportFormat
    @State private var longEdgeText: String
    @State private var directory: URL?
    @State private var template: String

    init(
        photo: PhotoItem,
        notice: String? = nil,
        initial: ExportSettings = ExportSettings(),
        onCancel: @escaping () -> Void,
        onExport: @escaping (ExportSettings) -> Void
    ) {
        self.photo = photo
        self.notice = notice
        self.onCancel = onCancel
        self.onExport = onExport
        _format = State(initialValue: initial.format)
        _longEdgeText = State(initialValue: String(initial.longEdge))
        _directory = State(initialValue: initial.directory)
        _template = State(initialValue: initial.filenameTemplate)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("导出设置")
                    .font(.skin(13, .semibold))
                    .foregroundStyle(SkinColor.text1)
                Spacer()
                Text(photo.filename)
                    .font(.skin(10.5))
                    .foregroundStyle(SkinColor.text4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            SkinHairline()

            VStack(spacing: 14) {
                fieldRow("格式") {
                    Picker("", selection: $format) {
                        ForEach(ExportFormat.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 230, alignment: .leading)
                }

                fieldRow("长边像素") {
                    HStack(spacing: 6) {
                        TextField("0 = 原尺寸", text: $longEdgeText)
                            .textFieldStyle(.plain)
                            .font(.skin(11.5).monospacedDigit())
                            .padding(.horizontal, 8)
                            .frame(width: 110, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(SkinColor.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(SkinColor.hairline, lineWidth: 1)
                            )
                        Text("px")
                            .font(.skin(10.5))
                            .foregroundStyle(SkinColor.text4)
                    }
                }

                fieldRow("目录") {
                    Button(action: chooseDirectory) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .medium))
                            Text(directory?.lastPathComponent ?? "与原文件相同")
                                .font(.skin(11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(SkinColor.text2)
                        .padding(.horizontal, 9)
                        .frame(width: 230, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(SkinColor.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(SkinColor.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                fieldRow("文件名") {
                    TextField("{name}-spektra", text: $template)
                        .textFieldStyle(.plain)
                        .font(.skin(11.5))
                        .padding(.horizontal, 8)
                        .frame(width: 230, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(SkinColor.surface2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(SkinColor.hairline, lineWidth: 1)
                        )
                }

                HStack {
                    Text("可用变量：{name} 原文件名 · {film} 胶片 · {paper} 相纸")
                        .font(.skin(9.5))
                        .foregroundStyle(SkinColor.text4)
                    Spacer()
                }

                HStack {
                    Text("TIFF 使用 Deflate · EXR 不压缩 · 仅导出 RAW 显影结果")
                        .font(.skin(9.5))
                        .foregroundStyle(SkinColor.text4)
                    Spacer()
                }

                if let notice, !notice.isEmpty {
                    HStack {
                        Text(notice)
                            .font(.skin(9.5))
                            .foregroundStyle(SkinColor.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            SkinHairline()

            HStack(spacing: 8) {
                Spacer()
                SkinButton("取消", kind: .secondary, height: 28, action: onCancel)
                SkinButton("导出", kind: .primary, height: 28) {
                    var settings = ExportSettings(
                        format: format,
                        longEdge: max(0, Int(longEdgeText) ?? 0),
                        directory: directory,
                        filenameTemplate: template
                    )
                    if settings.filenameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
                        settings.filenameTemplate = "{name}-spektra"
                    }
                    onExport(settings)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
        }
        .frame(width: 420)
        .background(SkinColor.surface1)
    }

    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.skin(11.5))
                .foregroundStyle(SkinColor.text2)
                .frame(width: 66, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK {
            directory = panel.url
        }
    }
}
