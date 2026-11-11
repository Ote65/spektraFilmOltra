import Foundation

/// 移动端展示目录：胶片 / 相纸取自 Swift 核心的 28 份配置，
/// 快速与专业页只用真实字段，id 与桌面 `EngineHost` 的映射表保持一致。
enum MobileCatalog {
    // MARK: - 胶片

    static let films: [MFilm] = [
        film("kodak_ektar_100", "柯达 Ektar 100", "柯达", "彩色负片", hue: 0.06, tone: .negative),
        film("kodak_portra_160", "柯达 Portra 160", "柯达", "彩色负片", hue: 0.04, tone: .negative),
        film("kodak_portra_400", "柯达 Portra 400", "柯达", "彩色负片", hue: 0.05, tone: .negative),
        film("kodak_portra_800", "柯达 Portra 800", "柯达", "彩色负片", hue: 0.03, tone: .negative),
        film("kodak_portra_800_push1", "柯达 Portra 800 推一档", "柯达", "彩色负片", hue: 0.02, tone: .negative),
        film("kodak_portra_800_push2", "柯达 Portra 800 推两档", "柯达", "彩色负片", hue: 0.02, tone: .negative),
        film("kodak_gold_200", "柯达 Gold 200", "柯达", "彩色负片", hue: 0.09, tone: .negative),
        film("kodak_ultramax_400", "柯达 UltraMax 400", "柯达", "彩色负片", hue: 0.08, tone: .negative),
        film("kodak_vision3_50d", "柯达 Vision3 50D", "柯达", "电影负片", hue: 0.11, tone: .cinema),
        film("kodak_vision3_250d", "柯达 Vision3 250D", "柯达", "电影负片", hue: 0.10, tone: .cinema),
        film("kodak_verita_200d", "柯达 Verita 200D", "柯达", "彩色负片", hue: 0.07, tone: .negative),
        film("kodak_vision3_200t", "柯达 Vision3 200T", "柯达", "电影负片", hue: 0.12, tone: .cinema),
        film("kodak_vision3_500t", "柯达 Vision3 500T", "柯达", "电影负片", hue: 0.13, tone: .cinema),
        film("fujifilm_pro_400h", "富士 Pro 400H", "富士", "彩色负片", hue: 0.43, tone: .negative),
        film("fujifilm_c200", "富士 C200", "富士", "彩色负片", hue: 0.45, tone: .negative),
        film("fujifilm_xtra_400", "富士 X-Tra 400", "富士", "彩色负片", hue: 0.44, tone: .negative),
        film("kodak_ektachrome_100", "柯达 Ektachrome 100", "柯达", "彩色反转片", hue: 0.55, tone: .reversal),
        film("kodak_kodachrome_64", "柯达 Kodachrome 64", "柯达", "彩色反转片", hue: 0.58, tone: .reversal),
        film("fujifilm_velvia_100", "富士 Velvia 100", "富士", "彩色反转片", hue: 0.92, tone: .reversal),
        film("fujifilm_provia_100f", "富士 Provia 100F", "富士", "彩色反转片", hue: 0.50, tone: .reversal),
    ]

    // MARK: - 相纸

    static let papers: [MPaper] = [
        paper("kodak_ultra_endura", "柯达 Ultra Endura", "柯达", warmth: 0.22, note: "浓郁 · 高反差"),
        paper("kodak_endura_premier", "柯达 Endura Premier", "柯达", warmth: 0.18, note: "专业 · 均衡"),
        paper("kodak_ektacolor_edge", "柯达 Ektacolor Edge", "柯达", warmth: 0.28, note: "暖黄 · 商业"),
        paper("kodak_supra_endura", "柯达 Supra Endura", "柯达", warmth: 0.10, note: "中性 · 高饱和"),
        paper("kodak_portra_endura", "柯达 Portra Endura", "柯达", warmth: 0.16, note: "暖调 · 肤色"),
        paper("fujifilm_crystal_archive_typeii", "富士 Crystal Archive Type II", "富士", warmth: 0.04, note: "冷调 · 干净"),
        paper("kodak_2383", "柯达 2383 电影印片", "柯达", warmth: 0.11, note: "电影 · 标准"),
        paper("kodak_2393", "柯达 2393 电影印片", "柯达", warmth: 0.12, note: "电影 · 高光"),
    ]

    // MARK: - 快速页

    static let quickGroups: [MQuickGroup] = [
        MQuickGroup(id: "light", title: "光调", axes: [
            MQuickAxis(id: "camera_exposure", label: "拍摄曝光", group: "光调",
                       range: -3...3, step: 0.1, decimals: 1, suffix: " EV", base: 0, value: 0),
            MQuickAxis(id: "print_brightness", label: "印相明暗", group: "光调",
                       range: -2...2, step: 0.05, decimals: 2, suffix: "", base: 0, value: 0),
            MQuickAxis(id: "tonal_contrast", label: "影调反差", group: "光调",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
            // 单向轴：0 = 胶片原始肩部，向右逐步延长高光肩部（物理量是显影疲劳，
            // 专业页同名参数 0–1；快速页只开放到 0.6，避免拖满就发灰）。
            MQuickAxis(id: "highlight_softening", label: "高光柔和", group: "光调",
                       range: 0...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
        ]),
        MQuickGroup(id: "color", title: "色彩", axes: [
            MQuickAxis(id: "color_density", label: "色彩浓度", group: "色彩",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
            MQuickAxis(id: "temperature", label: "印相冷暖", group: "色彩",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
        ]),
        MQuickGroup(id: "texture", title: "质感", axes: [
            MQuickAxis(id: "grain_amount", label: "颗粒强度", group: "质感",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
            MQuickAxis(id: "grain_size", label: "颗粒尺寸", group: "质感",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
            MQuickAxis(id: "scanner_clarity", label: "扫描清晰度", group: "质感",
                       range: -100...100, step: 1, decimals: 0, suffix: "", base: 0, value: 0),
        ]),
    ]

    // MARK: - 专业页

    static let proPages: [MProPage] = [
        MProPage(id: "tone", title: "光调", groups: [
            MProGroup(id: "tone-camera", title: "拍摄", rows: [
                slider("exposure_compensation_ev", "曝光补偿", 0, -5...5, 0.1, 1, " EV"),
                toggle("auto_exposure", "自动曝光", true),
                choice("auto_exposure_method", "测光方式", [
                    MProOption(value: "center_weighted", label: "中央重点"),
                    MProOption(value: "average", label: "平均值"),
                    MProOption(value: "median", label: "中位数"),
                    MProOption(value: "partial", label: "局部"),
                    MProOption(value: "matrix", label: "矩阵"),
                    MProOption(value: "multi_zone", label: "多区"),
                    MProOption(value: "highlight_weighted", label: "高光优先"),
                ], "center_weighted"),
                slider("camera_lens_blur_um", "拍摄柔化", 0, 0...10, 0.1, 1, " µm"),
            ]),
            MProGroup(id: "tone-print", title: "印相", rows: [
                slider("print_exposure", "印相曝光", 1, 0.25...4, 0.01, 2, "×"),
                toggle("print_exposure_compensation", "自动亮度补偿", true),
                toggle("normalize_print_exposure", "曝光归一", true),
                slider("film_density_curve_gamma", "明暗对比", 1, 0.5...1.8, 0.01, 2, "×"),
                slider("gamma_factor", "影调反差", 1, 0.5...2.0, 0.01, 2, "×"),
                slider("developer_exhaustion", "高光柔和", 0, 0...1, 0.01, 2, ""),
                slider("gamma_factor_fast", "快层反差", 1, 0.5...2.0, 0.01, 2, "×"),
                slider("gamma_factor_slow", "慢层反差", 1, 0.5...2.0, 0.01, 2, "×"),
            ]),
            MProGroup(id: "tone-preflash", title: "预闪", rows: [
                slider("preflash_exposure", "预闪曝光", 0, 0...0.3, 0.005, 3, ""),
                slider("preflash_y_filter_shift", "预闪冷暖", 0, -40...40, 1, 0, " CC"),
                slider("preflash_m_filter_shift", "预闪品红", 0, -40...40, 1, 0, " CC"),
            ]),
        ]),
        MProPage(id: "color", title: "色彩", groups: [
            MProGroup(id: "color-balance", title: "印相滤色", rows: [
                slider("print_y_filter_shift", "Y 偏移", 0, -60...60, 1, 0, " CC"),
                slider("print_m_filter_shift", "M 偏移", 0, -60...60, 1, 0, " CC"),
                choice("print_illuminant", "印相光源", [
                    MProOption(value: "TH-KG3", label: "TH-KG3"),
                    MProOption(value: "D50", label: "D50"),
                    MProOption(value: "D55", label: "D55"),
                    MProOption(value: "D65", label: "D65"),
                    MProOption(value: "A", label: "A"),
                    MProOption(value: "Kinoton 75P", label: "Kinoton 75P"),
                ], "TH-KG3"),
            ]),
            MProGroup(id: "color-couplers", title: "浓度", rows: [
                toggle("couplers_active", "启用成色剂", true),
                slider("inhibition_interlayer", "颜色浓度", 1, 0.0...1.5, 0.01, 2, ""),
                slider("inhibition_samelayer", "层次反差", 1, 0.0...1.5, 0.01, 2, ""),
                slider("coupler_amount", "成色剂强度", 1, 0...1.5, 0.01, 2, ""),
                slider("diffusion_size_um", "染色扩散", 20, 0...30, 1, 0, ""),
            ]),
            MProGroup(id: "color-split", title: "分色", rows: [
                slider("gamma_factor_red", "红色反差", 1, 0.5...2.0, 0.01, 2, "×"),
                slider("gamma_factor_green", "绿色反差", 1, 0.5...2.0, 0.01, 2, "×"),
                slider("gamma_factor_blue", "蓝色反差", 1, 0.5...2.0, 0.01, 2, "×"),
            ]),
            MProGroup(id: "color-diffusion", title: "柔光镜", rows: [
                toggle("camera_diffusion_active", "启用柔光", false),
                slider("camera_diffusion_strength", "柔光强度", 0.5, 0...2, 0.01, 2, ""),
                choice("camera_diffusion_family", "柔光类型", [
                    MProOption(value: "black_pro_mist", label: "Black Pro-Mist"),
                    MProOption(value: "glimmerglass", label: "Glimmerglass"),
                    MProOption(value: "pro_mist", label: "Pro-Mist"),
                    MProOption(value: "cinebloom", label: "CineBloom"),
                ], "black_pro_mist"),
                slider("camera_diffusion_spatial_scale", "柔光范围", 1, 0...3, 0.05, 2, "×"),
                slider("camera_diffusion_halo_warmth", "光晕暖度", 0, -1.5...1.5, 0.05, 2, ""),
            ]),
            MProGroup(id: "color-enlarger-diffusion", title: "印相柔光", rows: [
                toggle("enlarger_diffusion_active", "启用印相柔光", false),
                slider("enlarger_diffusion_strength", "印相柔光强度", 0.5, 0...2, 0.01, 2, ""),
                slider("enlarger_diffusion_spatial_scale", "印相柔光范围", 1, 0...3, 0.05, 2, "×"),
            ]),
            MProGroup(id: "color-glare", title: "印相眩光", rows: [
                toggle("print_glare_active", "启用印相眩光", true),
                slider("print_glare_percent", "眩光比例", 0.03, 0...1, 0.01, 2, ""),
                slider("print_glare_roughness", "眩光粗糙", 0.7, 0...1, 0.01, 2, ""),
                slider("print_glare_blur", "眩光模糊", 0.5, 0...2, 0.01, 2, " px"),
            ]),
        ]),
        MProPage(id: "film", title: "胶片", groups: [
            MProGroup(id: "film-format", title: "片基", rows: [
                slider("film_format_mm", "胶片格式", 35, 8...120, 1, 0, " mm"),
            ]),
            MProGroup(id: "film-grain", title: "颗粒", rows: [
                toggle("grain_active", "启用颗粒", true),
                toggle("grain_sublayers_active", "分层颗粒", true),
                slider("particle_area_um2", "颗粒尺寸", 0.2, 0.02...0.8, 0.01, 2, " µm"),
                slider("grain_density_min", "密度地板", 0.03, 0.005...0.08, 0.001, 3, ""),
                slider("grain_uniformity", "颗粒均匀度", 0.97, 0.90...0.995, 0.001, 3, ""),
                slider("grain_blur", "颗粒柔和", 0.65, 0...1.5, 0.01, 2, " px"),
                slider("grain_dye_clouds", "染料云", 1, 0...2, 0.05, 2, " µm"),
            ]),
            MProGroup(id: "film-halation", title: "光晕", rows: [
                toggle("halation_active", "启用光晕", true),
                slider("halation_amount", "高光红晕", 1, 0...2, 0.01, 2, ""),
                slider("halation_scatter_amount", "高光辉光", 1, 0...2, 0.01, 2, ""),
                slider("halation_scatter_scale", "辉光范围", 1, 0...3, 0.05, 2, "×"),
                slider("halation_spatial_scale", "红晕扩散", 1, 0...3, 0.05, 2, "×"),
                slider("halation_boost_ev", "高光提亮", 0, 0...4, 0.1, 1, " EV"),
                slider("halation_boost_range", "提亮范围", 0.3, 0...1, 0.01, 2, ""),
                slider("halation_protect_ev", "高光保护", 4, 0...6, 0.1, 1, " EV"),
                slider("halation_n_bounces", "反射次数", 3, 1...5, 1, 0, ""),
                slider("halation_bounce_decay", "反射衰减", 0.5, 0...1, 0.01, 2, ""),
                toggle("halation_renormalize", "光晕归一", true),
            ]),
            MProGroup(id: "film-glare", title: "胶片眩光", rows: [
                toggle("film_glare_active", "启用胶片眩光", true),
                slider("film_glare_percent", "眩光比例", 0.03, 0...1, 0.01, 2, ""),
                slider("film_glare_roughness", "眩光粗糙", 0.7, 0...1, 0.01, 2, ""),
                slider("film_glare_blur", "眩光模糊", 0.5, 0...2, 0.01, 2, " px"),
            ]),
        ]),
        MProPage(id: "detail", title: "细节", groups: [
            MProGroup(id: "detail-scan", title: "扫描", rows: [
                slider("scanner_lens_blur", "镜头模糊", 0, 0...2, 0.01, 2, ""),
                slider("scanner_unsharp_amount", "扫描锐化", 0.7, 0...2, 0.01, 2, ""),
                slider("scanner_unsharp_sigma", "锐化半径", 0.7, 0...3, 0.01, 2, " px"),
            ]),
            MProGroup(id: "detail-levels", title: "黑白场", rows: [
                toggle("white_correction", "白场校正", false),
                slider("white_level", "白场", 0.98, 0.75...1.0, 0.005, 3, ""),
                toggle("black_correction", "黑场校正", false),
                slider("black_level", "黑场", 0.01, 0.001...0.08, 0.001, 3, ""),
            ]),
            MProGroup(id: "detail-film", title: "底片", rows: [
                toggle("scan_film", "查看底片", false),
            ]),
            MProGroup(id: "detail-input", title: "输入", rows: [
                choice("white_balance", "白平衡", [
                    MProOption(value: "as_shot", label: "相机设定"),
                    MProOption(value: "daylight", label: "日光"),
                    MProOption(value: "tungsten", label: "钨丝灯"),
                    MProOption(value: "custom", label: "自定义"),
                ], "as_shot"),
                slider("white_balance_temperature", "色温", 5500, 1000...10000, 100, 0, " K"),
                slider("white_balance_tint", "色调", 1.0, 0.5...2.0, 0.01, 2, ""),
                toggle("lens_correction", "镜头校正", true),
                toggle("crop", "裁切", false),
                slider("crop_center_x", "裁切中心 X", 0.5, 0...1, 0.01, 2, ""),
                slider("crop_center_y", "裁切中心 Y", 0.5, 0...1, 0.01, 2, ""),
                slider("crop_size_x", "裁切宽", 0.1, 0.1...1, 0.01, 2, ""),
                slider("crop_size_y", "裁切高", 0.1, 0.1...1, 0.01, 2, ""),
                slider("upscale_factor", "放大", 1.0, 1...4, 0.05, 2, "×"),
                toggle("input_gamut_compress", "输入色域压缩", true),
            ]),
            MProGroup(id: "detail-output", title: "输出", rows: [
                choice("output_gamut_compress", "输出色域压缩", [
                    MProOption(value: "cam16ucs", label: "CAM16-UCS"),
                    MProOption(value: "oklch", label: "OkLCh"),
                    MProOption(value: "oklrab", label: "OkLrAB"),
                    MProOption(value: "jzazbz", label: "JzAzBz"),
                    MProOption(value: "aces_rgc", label: "ACES RGC"),
                ], "cam16ucs"),
            ]),
        ]),
    ]

    // MARK: - 查询

    static func film(id: String) -> MFilm? { films.first { $0.id == id } }
    static func paper(id: String) -> MPaper? { papers.first { $0.id == id } }

    static func filmName(_ stock: String) -> String { film(id: stock)?.name ?? stock }
    static func paperName(_ stock: String) -> String { paper(id: stock)?.name ?? stock }

    static func proRow(_ id: String) -> MProRow? {
        for page in proPages {
            for group in page.groups {
                if let row = group.rows.first(where: { $0.id == id }) { return row }
            }
        }
        return nil
    }

    // MARK: - 构造

    private enum FilmTone { case negative, cinema, reversal }

    private static func film(
        _ id: String, _ name: String, _ brand: String, _ kind: String,
        hue: Double, tone: FilmTone
    ) -> MFilm {
        let saturation: Double
        let brightness: Double
        switch tone {
        case .negative: saturation = 0.42; brightness = 0.56
        case .cinema: saturation = 0.26; brightness = 0.36
        case .reversal: saturation = 0.50; brightness = 0.50
        }
        return MFilm(id: id, name: name, brand: brand, kind: kind,
                     hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func paper(
        _ id: String, _ name: String, _ brand: String,
        warmth: Double, note: String
    ) -> MPaper {
        MPaper(id: id, name: name, brand: brand, warmth: warmth, note: note)
    }

    private static func slider(
        _ id: String, _ label: String, _ base: Double,
        _ range: ClosedRange<Double>, _ step: Double, _ decimals: Int, _ suffix: String
    ) -> MProRow {
        MProRow(id: id, label: label,
                control: .slider(value: base, base: base, range: range,
                                 step: step, decimals: decimals, suffix: suffix))
    }

    private static func toggle(_ id: String, _ label: String, _ on: Bool) -> MProRow {
        MProRow(id: id, label: label, control: .toggle(isOn: on))
    }

    private static func choice(_ id: String, _ label: String,
                               _ options: [MProOption], _ value: String) -> MProRow {
        MProRow(id: id, label: label, control: .choice(options: options, value: value))
    }
}
