import Foundation

enum PreviewData {
    static let windowPhoto = PhotoItem(
        id: "window-still",
        filename: "window-still.jpg",
        asset: "window-still",
        film: "柯达 Portra 400",
        paper: "柯达 Supra Endura",
        dimensions: "1600×1200",
        isRaw: true,
        favorite: true,
        color: .yellow,
        isGraded: true
    )

    static let coastPhoto = PhotoItem(
        id: "coast-dusk",
        filename: "coast-dusk.jpg",
        asset: "coast-dusk",
        film: "富士 C200",
        paper: "富士 Crystal Archive",
        dimensions: "1800×1013",
        isRaw: false,
        favorite: false,
        color: .red,
        isGraded: false
    )

    static let portraitPhoto = PhotoItem(
        id: "portrait-shade",
        filename: "portrait-shade.jpg",
        asset: "portrait-shade",
        film: "柯达 Gold 200",
        paper: "柯达 Portra Endura",
        dimensions: "1200×1600",
        isRaw: true,
        favorite: true,
        color: nil,
        isGraded: false
    )

    static let ceramicPhoto = PhotoItem(
        id: "ceramic-still",
        filename: "ceramic-still.jpg",
        asset: "ceramic-still",
        film: "柯达 Ektar 100",
        paper: "柯达 Ultra Endura",
        dimensions: "1600×1600",
        isRaw: false,
        favorite: false,
        color: .blue,
        isGraded: true
    )

    static let gradientTwo = PhotoItem(
        id: "gradient-2",
        filename: "gradient_2.png",
        asset: "gradient-2",
        film: "柯达 Portra 400",
        paper: "柯达 Supra Endura",
        dimensions: "1200×800",
        isRaw: false,
        favorite: true,
        color: .yellow,
        isGraded: false
    )

    static let gradientOne = PhotoItem(
        id: "gradient-1",
        filename: "gradient_1.png",
        asset: "gradient-1",
        film: "富士 C200",
        paper: "富士 Crystal Archive",
        dimensions: "1200×800",
        isRaw: false,
        favorite: false,
        color: nil,
        isGraded: false
    )

    static let gradientZero = PhotoItem(
        id: "gradient-0",
        filename: "gradient_0.png",
        asset: "gradient-0",
        film: "柯达 Vision3 500T",
        paper: "柯达 2383 电影印片",
        dimensions: "1200×800",
        isRaw: false,
        favorite: true,
        color: nil,
        isGraded: false
    )

    static let chartPhoto = PhotoItem(
        id: "color-chart",
        filename: "3_pipeline_color_digital_management.png",
        asset: "color-chart",
        film: "柯达 Ektar 100",
        paper: "柯达 Ektacolor Edge",
        dimensions: "1181×311",
        isRaw: false,
        favorite: false,
        color: .blue,
        isGraded: false
    )

    static let photos: [PhotoItem] = [
        windowPhoto, coastPhoto, portraitPhoto, ceramicPhoto,
        gradientTwo, gradientOne, gradientZero, chartPhoto,
    ]

    static let library = LibrarySnapshot(
        folderCount: 1,
        photoCount: photos.count,
        sectionTitle: "全部照片",
        sectionCount: "\(photos.count) 张照片",
        folders: [
            FolderItem(id: "all", name: "全部照片", count: photos.count, isCurrent: true),
            FolderItem(id: "sf-ui-demo", name: "sf_ui_demo", count: photos.count, isCurrent: false),
        ],
        photos: photos,
        statusMessage: "照片库已就绪"
    )

    // MARK: - 预设

    static let films: [PresetItem] = [
        PresetItem(id: "kodak_ektar_100", name: "柯达 Ektar 100", meta: "彩色负片 · 100", brand: "柯达", kind: .negative, hue: 0.06),
        PresetItem(id: "kodak_portra_160", name: "柯达 Portra 160", meta: "彩色负片 · 160", brand: "柯达", kind: .negative, hue: 0.04),
        PresetItem(id: "kodak_portra_400", name: "柯达 Portra 400", meta: "彩色负片 · 400", brand: "柯达", kind: .negative, hue: 0.05),
        PresetItem(id: "kodak_portra_800", name: "柯达 Portra 800", meta: "彩色负片 · 800", brand: "柯达", kind: .negative, hue: 0.03),
        PresetItem(id: "kodak_portra_800_push1", name: "柯达 Portra 800 推一档", meta: "彩色负片 · 800 · 推一档", brand: "柯达", kind: .negative, hue: 0.02),
        PresetItem(id: "kodak_portra_800_push2", name: "柯达 Portra 800 推两档", meta: "彩色负片 · 800 · 推两档", brand: "柯达", kind: .negative, hue: 0.02),
        PresetItem(id: "kodak_gold_200", name: "柯达 Gold 200", meta: "彩色负片 · 200", brand: "柯达", kind: .negative, hue: 0.09),
        PresetItem(id: "kodak_ultramax_400", name: "柯达 UltraMax 400", meta: "彩色负片 · 400", brand: "柯达", kind: .negative, hue: 0.08),
        PresetItem(id: "kodak_vision3_50d", name: "柯达 Vision3 50D", meta: "电影负片 · 50 · 日光型", brand: "柯达", kind: .cinema, hue: 0.11),
        PresetItem(id: "kodak_vision3_250d", name: "柯达 Vision3 250D", meta: "电影负片 · 250 · 日光型", brand: "柯达", kind: .cinema, hue: 0.10),
        PresetItem(id: "kodak_verita_200d", name: "柯达 Verita 200D", meta: "彩色负片 · 200 · 日光型", brand: "柯达", kind: .negative, hue: 0.07),
        PresetItem(id: "kodak_vision3_200t", name: "柯达 Vision3 200T", meta: "电影负片 · 200 · 灯光型", brand: "柯达", kind: .cinema, hue: 0.12),
        PresetItem(id: "kodak_vision3_500t", name: "柯达 Vision3 500T", meta: "电影负片 · 500 · 灯光型", brand: "柯达", kind: .cinema, hue: 0.13),
        PresetItem(id: "fujifilm_pro_400h", name: "富士 Pro 400H", meta: "彩色负片 · 400", brand: "富士", kind: .negative, hue: 0.43),
        PresetItem(id: "fujifilm_c200", name: "富士 C200", meta: "彩色负片 · 200", brand: "富士", kind: .negative, hue: 0.45),
        PresetItem(id: "fujifilm_xtra_400", name: "富士 X-Tra 400", meta: "彩色负片 · 400", brand: "富士", kind: .negative, hue: 0.44),
        PresetItem(id: "kodak_ektachrome_100", name: "柯达 Ektachrome 100", meta: "彩色反转片 · 100", brand: "柯达", kind: .reversal, hue: 0.55),
        PresetItem(id: "kodak_kodachrome_64", name: "柯达 Kodachrome 64", meta: "彩色反转片 · 64", brand: "柯达", kind: .reversal, hue: 0.58),
        PresetItem(id: "fujifilm_velvia_100", name: "富士 Velvia 100", meta: "彩色反转片 · 100", brand: "富士", kind: .reversal, hue: 0.92),
        PresetItem(id: "fujifilm_provia_100f", name: "富士 Provia 100F", meta: "彩色反转片 · 100", brand: "富士", kind: .reversal, hue: 0.50),
    ]

    static let papers: [PresetItem] = [
        PresetItem(id: "kodak_ultra_endura", name: "柯达 Ultra Endura", meta: "彩色相纸 · 通用", brand: "柯达", kind: .paper, hue: 0.10),
        PresetItem(id: "kodak_endura_premier", name: "柯达 Endura Premier", meta: "彩色相纸 · 专业", brand: "柯达", kind: .paper, hue: 0.09),
        PresetItem(id: "kodak_ektacolor_edge", name: "柯达 Ektacolor Edge", meta: "彩色相纸 · 高反差", brand: "柯达", kind: .paper, hue: 0.08),
        PresetItem(id: "kodak_supra_endura", name: "柯达 Supra Endura", meta: "彩色相纸 · 人像", brand: "柯达", kind: .paper, hue: 0.07),
        PresetItem(id: "kodak_portra_endura", name: "柯达 Portra Endura", meta: "彩色相纸 · 人像", brand: "柯达", kind: .paper, hue: 0.06),
        PresetItem(id: "fujifilm_crystal_archive_typeii", name: "富士 Crystal Archive Type II", meta: "彩色相纸 · 存档", brand: "富士", kind: .paper, hue: 0.45),
        PresetItem(id: "kodak_2383", name: "柯达 2383 电影印片", meta: "电影印片 · 标准", brand: "柯达", kind: .paper, hue: 0.11),
        PresetItem(id: "kodak_2393", name: "柯达 2393 电影印片", meta: "电影印片 · 高光", brand: "柯达", kind: .paper, hue: 0.12),
    ]

    static let presets = PresetCatalog(films: films, papers: papers)

    // MARK: - 快速控制

    static func axis(
        _ id: String, _ label: String, _ lo: Double, _ hi: Double,
        step: Double, decimals: Int, suffix: String = "", value: Double
    ) -> QuickAxis {
        QuickAxis(
            id: id, label: label, range: lo...hi, step: step, decimals: decimals,
            suffix: suffix, baseValue: 0, value: value, unavailableReason: nil
        )
    }

    static let quickGroups: [QuickGroup] = [
        QuickGroup(id: "light", title: "光调", axes: [
            axis("camera_exposure", "拍摄曝光", -3, 3, step: 0.1, decimals: 1, suffix: " EV", value: 0.3),
            axis("print_brightness", "印相明暗", -2, 2, step: 0.05, decimals: 2, suffix: " EV", value: 0),
            axis("tonal_contrast", "影调反差", -100, 100, step: 1, decimals: 0, value: 12),
        ], pad: nil),
        QuickGroup(id: "color", title: "色彩", axes: [
            axis("color_density", "色彩浓度", -100, 100, step: 1, decimals: 0, value: 8),
        ], pad: QuickPad(title: "印相色彩", x: -8, y: 0)),
        QuickGroup(id: "texture", title: "质感", axes: [
            axis("grain_amount", "颗粒强度", -100, 100, step: 1, decimals: 0, value: 0),
            axis("grain_size", "颗粒尺寸", -100, 100, step: 1, decimals: 0, value: 0),
            axis("halation_amount", "光晕强度", -100, 100, step: 1, decimals: 0, value: 0),
            axis("halation_scale", "光晕范围", -100, 100, step: 1, decimals: 0, value: 0),
            axis("diffusion", "光学柔化", -100, 100, step: 1, decimals: 0, value: 0),
            axis("scanner_clarity", "扫描清晰度", -100, 100, step: 1, decimals: 0, value: 0),
        ], pad: nil),
    ]

    // MARK: - 专业页

    static func slider(_ id: String, _ label: String, _ value: Double, _ text: String, dirty: Bool = false) -> ParamRow {
        ParamRow(id: id, label: label, control: .slider(value: value, valueText: text, dirty: dirty), isEnabled: true)
    }

    static func toggle(_ id: String, _ label: String, _ on: Bool) -> ParamRow {
        ParamRow(id: id, label: label, control: .toggle(isOn: on), isEnabled: true)
    }

    static func choice(_ id: String, _ label: String, _ text: String) -> ParamRow {
        ParamRow(id: id, label: label, control: .choice(text: text), isEnabled: true)
    }

    static let proPages: [ParamPage] = [
        ParamPage(id: "light", title: "光影", groups: [
            ParamGroup(id: "light.exposure", title: "曝光", rows: [
                slider("print_exposure", "亮度", 1.0, "1.00"),
                toggle("print_exposure_compensation", "自动亮度补偿", true),
                slider("film_gamma_factor", "明暗对比", 1.0, "1.00"),
                slider("developer_exhaustion", "高光柔和度", 0, "0.00"),
                slider("exposure_compensation_ev", "曝光补偿", 0, "+0.0 EV"),
                toggle("auto_exposure", "自动测光", false),
                choice("auto_exposure_method", "测光方式", "平均测光"),
            ]),
            ParamGroup(id: "light.print", title: "印相", rows: [
                toggle("white_correction", "白场校正", true),
                slider("white_level", "白场", 0.95, "0.950"),
                toggle("black_correction", "黑场校正", true),
                slider("black_level", "黑场", 0.01, "0.010"),
                toggle("glare_active", "启用眩光", false),
                slider("glare_percent", "眩光", 0, "0.00"),
                slider("glare_roughness", "眩光粗糙度", 0, "0.00"),
                slider("preflash_exposure", "预闪曝光", 0, "0.000"),
            ]),
        ]),
        ParamPage(id: "color", title: "色彩", groups: [
            ParamGroup(id: "color.balance", title: "白平衡", rows: [
                slider("print_y_filter_shift", "冷暖", 0, "0"),
                slider("print_m_filter_shift", "绿与品红", 0, "0"),
                choice("print_illuminant", "印相光源", "日光"),
            ]),
            ParamGroup(id: "color.density", title: "浓度", rows: [
                toggle("couplers_active", "启用成色剂", true),
                slider("inhibition_interlayer", "颜色浓度", 1.0, "1.00"),
                slider("inhibition_samelayer", "层次反差", 1.0, "1.00"),
                slider("coupler_amount", "成色剂强度", 1.0, "1.00"),
                slider("diffusion_size_um", "染色扩散", 0, "0"),
            ]),
            ParamGroup(id: "color.separation", title: "分色", rows: [
                slider("gamma_factor_red", "红色反差", 1.0, "1.00"),
                slider("gamma_factor_green", "绿色反差", 1.0, "1.00"),
                slider("gamma_factor_blue", "蓝色反差", 1.0, "1.00"),
            ]),
            ParamGroup(id: "color.preflash", title: "预闪", rows: [
                slider("preflash_y", "预闪冷暖", 0, "0"),
                slider("preflash_m", "预闪品红", 0, "0"),
            ]),
        ]),
        ParamPage(id: "film", title: "胶片", groups: [
            ParamGroup(id: "film.model", title: "型号", rows: [
                choice("film_stock", "胶片", "柯达 Portra 400"),
                choice("print_paper", "相纸", "柯达 Supra Endura"),
            ]),
            ParamGroup(id: "film.grain", title: "颗粒", rows: [
                toggle("grain_active", "启用颗粒", true),
                slider("particle_area_um2", "颗粒粗细", 0.22, "0.22"),
                slider("grain_blur", "颗粒柔和", 0, "0.00"),
                slider("blur_dye_clouds_um", "染料云", 0, "0.00"),
            ]),
            ParamGroup(id: "film.halation", title: "光晕", rows: [
                toggle("halation_active", "启用光晕", true),
                slider("halation_amount", "高光红晕", 0.35, "0.35"),
                slider("scatter_amount", "高光辉光", 0.3, "0.30"),
                slider("halation_spatial_scale", "红晕扩散", 1.0, "1.00"),
                slider("boost_ev", "高光提亮", 1.0, "1.0"),
                slider("protect_ev", "高光保护", 2.0, "2.0"),
            ]),
            ParamGroup(id: "film.develop", title: "显影", rows: [
                toggle("chemistry_active", "启用显影曲线", true),
                slider("gamma_factor", "显影反差", 1.0, "1.00"),
                slider("gamma_factor_fast", "快层反差", 1.0, "1.00"),
                slider("gamma_factor_slow", "慢层反差", 1.0, "1.00"),
            ]),
        ]),
        ParamPage(id: "frame", title: "画面", groups: [
            ParamGroup(id: "frame.sharp", title: "清晰", rows: [
                slider("lens_blur", "镜头柔化", 0, "0.00"),
                slider("lens_blur_um", "拍摄柔化", 0, "0.0"),
                toggle("camera_diffusion_active", "启用柔光", false),
                slider("diffusion_strength", "柔光强度", 0, "0.00"),
                choice("diffusion_filter", "柔光类型", "Pro-Mist"),
            ]),
            ParamGroup(id: "frame.compose", title: "构图", rows: [
                slider("film_format_mm", "画幅", 35, "35"),
                slider("white_padding", "白边", 0.08, "0.080"),
            ]),
            ParamGroup(id: "frame.output", title: "输出", rows: [
                choice("output_color_space", "输出色彩空间", "Display P3"),
                choice("saving_color_space", "保存色彩空间", "ProPhoto RGB"),
                toggle("saving_cctf", "保存时写入亮度编码", false),
            ]),
        ]),
        ParamPage(id: "input", title: "输入", groups: [
            ParamGroup(id: "input.raw", title: "RAW 解码", rows: [
                choice("raw_white_balance", "白平衡", "原始"),
                slider("raw_temperature", "色温", 5500, "5500"),
                slider("raw_tint", "色调", 1.0, "1.00"),
                toggle("raw_lens_correction", "镜头校正", true),
            ]),
            ParamGroup(id: "input.image", title: "输入", rows: [
                choice("input_color_space", "色彩空间", "ProPhoto RGB"),
                toggle("input_cctf_decoding", "CCTF 解码", true),
                toggle("input_crop", "裁切", false),
                slider("upscale_factor", "放大", 1.0, "1.00"),
            ]),
        ]),
        ParamPage(id: "advanced", title: "高级", groups: [
            ParamGroup(id: "advanced.pipeline", title: "流程", rows: [
                choice("input_gamut", "输入色域压缩", "关闭"),
                choice("output_gamut", "输出色域压缩", "柔化"),
                toggle("warmup", "保留中间结果", true),
            ]),
            ParamGroup(id: "advanced.special", title: "实验", rows: [
                slider("special_factor", "实验系数", 0, "0.00"),
                toggle("special_toggle", "启用实验分支", false),
            ]),
        ]),
    ]

    static let histogram: HistogramData = {
        func curve(_ center: Double, _ spread: Double, _ gain: Double) -> [Double] {
            (0..<56).map { i in
                let x = Double(i) / 55.0
                let main = exp(-pow((x - center) / spread, 2))
                let toe = 0.20 * exp(-pow((x - 0.06) / 0.16, 2))
                return min(1.0, max(0.0, (main + toe) * gain))
            }
        }
        return HistogramData(
            red: curve(0.58, 0.16, 1.05),
            green: curve(0.48, 0.19, 0.95),
            blue: curve(0.38, 0.22, 0.88)
        )
    }()

    static func proPages(film: String, paper: String) -> [ParamPage] {
        proPages.map { page in
            ParamPage(
                id: page.id,
                title: page.title,
                groups: page.groups.map { group in
                    ParamGroup(
                        id: group.id,
                        title: group.title,
                        rows: group.rows.map { row in
                            switch row.id {
                            case "film_stock":
                                return choice("film_stock", "胶片", film)
                            case "print_paper":
                                return choice("print_paper", "相纸", paper)
                            default:
                                return row
                            }
                        }
                    )
                }
            )
        }
    }

    static func editor(for photo: PhotoItem) -> EditorSnapshot {
        let strip = [photo] + photos.filter { $0.id != photo.id }.prefix(3)
        let paperName = photo.paper ?? "柯达 Supra Endura"
        let filmID = films.first(where: { $0.name == photo.film })?.id ?? "kodak_portra_400"
        let paperID = papers.first(where: { $0.name == paperName })?.id ?? "kodak_supra_endura"
        return EditorSnapshot(
            photo: photo,
            filmName: photo.film,
            paperName: paperName,
            filmstrip: Array(strip),
            quickGroups: quickGroups,
            proPages: proPages(film: photo.film, paper: paperName),
            histogram: histogram,
            dirtyCount: 4,
            currentFilmID: filmID,
            currentPaperID: paperID,
            stripCount: photos.count
        )
    }

    static func grade(for photo: PhotoItem) -> GradeSnapshot {
        GradeSnapshot(
            photo: photo,
            handoffMeta: "\(photo.dimensions) · \(photo.film) · 16-bit ProPhoto 线性交接图"
        )
    }
}

struct PreviewDataSource: SpektraSkinDataSource {
    var library: LibrarySnapshot { PreviewData.library }
    var presets: PresetCatalog { PreviewData.presets }

    func editor(for photoID: PhotoItem.ID) -> EditorSnapshot {
        let photo = PreviewData.photos.first(where: { $0.id == photoID }) ?? PreviewData.windowPhoto
        return PreviewData.editor(for: photo)
    }

    func grade(for photoID: PhotoItem.ID) -> GradeSnapshot {
        let photo = PreviewData.photos.first(where: { $0.id == photoID }) ?? PreviewData.windowPhoto
        return PreviewData.grade(for: photo)
    }
}
