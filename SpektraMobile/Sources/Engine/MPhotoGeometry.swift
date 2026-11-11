import CoreGraphics
import CoreImage
import Foundation

/// 裁切与校正几何。只对交接图做像素重排，不参与显影/调色算法。
/// 变换顺序：90° 旋转 → 镜像 → 水平/透视校正 → 归一化裁切。
/// 镜像定义在旋转后的画面坐标系里，所以「水平翻转」永远是屏幕上的左右翻转。
struct MPhotoGeometry: Codable, Equatable {
    struct Crop: Codable, Equatable {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 1
        var height: Double = 1

        static let full = Crop()

        var isFull: Bool {
            abs(x) < 1e-6 && abs(y) < 1e-6
                && abs(width - 1) < 1e-6 && abs(height - 1) < 1e-6
        }

        var clamped: Crop {
            var value = self
            value.width = min(max(value.width, 0.02), 1)
            value.height = min(max(value.height, 0.02), 1)
            value.x = min(max(value.x, 0), 1 - value.width)
            value.y = min(max(value.y, 0), 1 - value.height)
            return value
        }
    }

    /// 0...3，顺时针 90° 的次数。
    var quarterTurns = 0
    var flippedH = false
    var flippedV = false
    /// 水平纠正，单位度，-45...45。
    var straighten = 0.0
    /// 透视纠正，-100...100。
    var perspectiveV = 0.0
    var perspectiveH = 0.0
    var crop = Crop.full

    var isIdentity: Bool {
        quarterTurns % 4 == 0 && !flippedH && !flippedV
            && abs(straighten) < 1e-6
            && abs(perspectiveV) < 1e-6 && abs(perspectiveH) < 1e-6
            && crop.isFull
    }

    var hasCrop: Bool { !crop.isFull }

    func normalized() -> MPhotoGeometry {
        var value = self
        value.quarterTurns = ((value.quarterTurns % 4) + 4) % 4
        value.straighten = min(max(value.straighten, -45), 45)
        value.perspectiveV = min(max(value.perspectiveV, -100), 100)
        value.perspectiveH = min(max(value.perspectiveH, -100), 100)
        value.crop = value.crop.clamped
        return value
    }

    /// 只保留方向与校正，裁切回到全幅：裁切页的取景预览用。
    func withoutCrop() -> MPhotoGeometry {
        var value = self
        value.crop = .full
        return value
    }

    /// 顺时针旋转 90°：裁切框跟着画面一起转，避免旋转后取景框错位。
    func rotatedClockwise() -> MPhotoGeometry {
        var value = self
        let old = crop
        value.quarterTurns = (quarterTurns + 1) % 4
        // 顺时针转 90° 后，画面坐标里的水平镜像等价于原来的垂直镜像。
        swap(&value.flippedH, &value.flippedV)
        value.crop = Crop(x: 1 - old.y - old.height, y: old.x,
                          width: old.height, height: old.width).clamped
        return value
    }

    /// 方向变换后的画面尺寸（未裁切）。
    func orientedSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        quarterTurns % 2 == 0
            ? (max(1, sourceWidth), max(1, sourceHeight))
            : (max(1, sourceHeight), max(1, sourceWidth))
    }

    /// 校正后画面在归一化坐标里的外接矩形。
    /// 透视/旋转会把四角甩到原画幅之外，取景预览按这个外接框出图，
    /// 照片就会像主流修图 App 一样向外扩展，而不是被压回原来的比例。
    /// 最终输出仍以原画幅（裁切框）为准，外扩部分只用于取景展示。
    func warpBounds(sourceWidth: Int, sourceHeight: Int) -> CGRect {
        let oriented = orientedSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return warpBounds(orientedWidth: oriented.width, orientedHeight: oriented.height)
    }

    /// 已定向尺寸版本（GPU 路径的 CIImage 已经是旋转后的，不能再翻转一次）。
    func warpBounds(orientedWidth: Int, orientedHeight: Int) -> CGRect {
        guard abs(straighten) > 1e-6
            || abs(perspectiveV) > 1e-6 || abs(perspectiveH) > 1e-6 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let quad = warpQuad(width: Double(max(1, orientedWidth)),
                            height: Double(max(1, orientedHeight)))
        let xs = quad.map(\.x)
        let ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: minX, y: minY,
                      width: max(1e-6, maxX - minX), height: max(1e-6, maxY - minY))
    }

    /// 输出尺寸。`maxLongEdge > 0` 时等比压到该长边内（裁切预览用）。
    func outputSize(sourceWidth: Int, sourceHeight: Int, maxLongEdge: Int? = nil) -> (width: Int, height: Int) {
        let oriented = orientedSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        var width = max(1, Int((crop.width * Double(oriented.width)).rounded()))
        var height = max(1, Int((crop.height * Double(oriented.height)).rounded()))
        if let maxLongEdge, maxLongEdge > 0 {
            let longest = max(width, height)
            if longest > maxLongEdge {
                let scale = Double(maxLongEdge) / Double(longest)
                width = max(1, Int((Double(width) * scale).rounded()))
                height = max(1, Int((Double(height) * scale).rounded()))
            }
        }
        return (width, height)
    }

    // MARK: - 采样

    /// 归一化裁剪坐标 → 源图像归一化坐标。
    /// `warp` 是调用方每帧构造一次的逆单应矩阵：它只依赖几何参数，
    /// 绝不能回到逐采样点重建的老路（每帧数百万次 3×3 求逆）。
    private func sourcePoint(u: Double, v: Double, warp: MHomography) -> CGPoint {
        sourcePoint(oriented: warp.map(CGPoint(x: u, y: v)))
    }

    private func sourcePoint(oriented point: CGPoint) -> CGPoint {
        var u = point.x
        var v = point.y
        // 先把画面坐标反镜像，再反旋转：正向就是先转再翻，翻转方向始终跟着屏幕。
        if flippedH { u = 1 - u }
        if flippedV { v = 1 - v }
        switch quarterTurns % 4 {
        case 1: (u, v) = (v, 1 - u)
        case 2: (u, v) = (1 - u, 1 - v)
        case 3: (u, v) = (1 - v, u)
        default: break
        }
        return CGPoint(x: u, y: v)
    }

    private func inverseWarp(orientedWidth: Int, orientedHeight: Int) -> MHomography {
        guard abs(straighten) > 1e-6
            || abs(perspectiveV) > 1e-6 || abs(perspectiveH) > 1e-6 else {
            return .identity
        }
        let quad = warpQuad(width: Double(orientedWidth), height: Double(orientedHeight))
        return MHomography.unitSquareToQuad(quad)?.inverted ?? .identity
    }

    /// 单位方框 → 校正后的四边形。
    /// 透视把对应一侧**向外扩张**：源图该侧在输出中占得更宽，输出看到的就是该侧被放大，
    /// 也就是把"上窄下宽"这类透视拉直。外扩保证输出画布始终落在四边形内部，
    /// 不会出现黑边或边缘拖影；超出画布的部分自然被裁掉（与 Lightroom 一致）。
    /// 旋转需要单独放大保证四角被覆盖，透视本身不做整体缩放。
    private func warpQuad(width: Double, height: Double) -> [CGPoint] {
        let pv = perspectiveV / 100
        let ph = perspectiveH / 100
        let top = 1 + max(pv, 0) * 0.45
        let bottom = 1 + max(-pv, 0) * 0.45
        let right = 1 + max(ph, 0) * 0.45
        let left = 1 + max(-ph, 0) * 0.45

        var points = [
            CGPoint(x: 0.5 - top / 2, y: 0.5 - left / 2),
            CGPoint(x: 0.5 + top / 2, y: 0.5 - right / 2),
            CGPoint(x: 0.5 + bottom / 2, y: 0.5 + right / 2),
            CGPoint(x: 0.5 - bottom / 2, y: 0.5 + left / 2),
        ]

        let angle = straighten * .pi / 180
        let cosA = cos(angle)
        let sinA = sin(angle)
        for index in points.indices {
            let px = (points[index].x - 0.5) * width
            let py = (points[index].y - 0.5) * height
            let rx = px * cosA - py * sinA
            let ry = px * sinA + py * cosA
            points[index] = CGPoint(x: 0.5 + rx / width, y: 0.5 + ry / height)
        }

        // 只补偿旋转：旋转会把四角甩到画幅外，必须放大到刚好覆盖。
        let absSin = abs(sinA)
        let rotScale = max(cosA + (height / width) * absSin,
                           cosA + (width / height) * absSin)
        for index in points.indices {
            points[index] = CGPoint(
                x: 0.5 + (points[index].x - 0.5) * rotScale,
                y: 0.5 + (points[index].y - 0.5) * rotScale
            )
        }
        return points
    }

    /// 缩小时超采样次数，避免小裁切框预览出现锯齿。
    /// `maxGrid` 用来在拖动期把超采样降到 1（成本直接除以 9）。
    private func sampleGrid(
        sourceWidth: Int, sourceHeight: Int,
        outputWidth: Int, outputHeight: Int, maxGrid: Int
    ) -> Int {
        let scaleX = crop.width * Double(sourceWidth) / Double(max(1, outputWidth))
        let scaleY = crop.height * Double(sourceHeight) / Double(max(1, outputHeight))
        let factor = max(scaleX, scaleY)
        return min(max(1, maxGrid), max(1, Int(ceil(factor - 0.001))))
    }

    // MARK: - ImageRGB

    /// `shouldCancel` 每行检查一次；被取消时原样返回输入图，调用方必须自行丢弃结果
    /// （用 `MCancelFlag` 判断是否已被取代）。
    func apply(
        to image: ImageRGB, maxGrid: Int = 3, shouldCancel: () -> Bool = { false }
    ) -> ImageRGB {
        guard !isIdentity, image.width > 1, image.height > 1 else { return image }
        let oriented = orientedSize(sourceWidth: image.width, sourceHeight: image.height)
        let output = outputSize(sourceWidth: image.width, sourceHeight: image.height)
        let grid = sampleGrid(sourceWidth: oriented.width, sourceHeight: oriented.height,
                              outputWidth: output.width, outputHeight: output.height,
                              maxGrid: maxGrid)
        let sampleCount = Double(grid * grid)
        let sourceWidth = image.width
        let sourceHeight = image.height
        var result = [Float](repeating: 0, count: output.width * output.height * 3)
        let geometry = self
        let warp = inverseWarp(orientedWidth: oriented.width, orientedHeight: oriented.height)
        let stepX = crop.width * Double(sourceWidth) / Double(output.width)
        let stepY = crop.height * Double(sourceHeight) / Double(output.height)
        // 列 / 行的归一化采样坐标提到内层循环之外：每像素只做一次映射。
        let columnU = (0..<output.width).map {
            crop.x + (Double($0) + 0.5) / Double(output.width) * crop.width
        }
        let rowV = (0..<output.height).map {
            crop.y + (Double($0) + 0.5) / Double(output.height) * crop.height
        }
        // 校正后画布四角可能落在源图外（两个方向同时透视时），与 GPU 预览一致填黑。
        let outsideIsBlack = abs(straighten) > 1e-6
            || abs(perspectiveV) > 1e-6 || abs(perspectiveH) > 1e-6
        var cancelled = false

        image.data.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { destination in
                rowLoop: for y in 0..<output.height {
                    if shouldCancel() {
                        cancelled = true
                        break rowLoop
                    }
                    let v = rowV[y]
                    for x in 0..<output.width {
                        let point = geometry.sourcePoint(u: columnU[x], v: v, warp: warp)
                        let baseX = point.x * Double(sourceWidth) - 0.5
                        let baseY = point.y * Double(sourceHeight) - 0.5
                        let index = (y * output.width + x) * 3
                        if grid == 1 {
                            let sampled = Self.sample(
                                source, width: sourceWidth, height: sourceHeight,
                                x: baseX, y: baseY, outsideIsBlack: outsideIsBlack)
                            destination[index] = Float(sampled.0)
                            destination[index + 1] = Float(sampled.1)
                            destination[index + 2] = Float(sampled.2)
                            continue
                        }
                        var sumR = 0.0
                        var sumG = 0.0
                        var sumB = 0.0
                        for sy in 0..<grid {
                            for sx in 0..<grid {
                                let offsetX = (Double(sx) + 0.5) / Double(grid) - 0.5
                                let offsetY = (Double(sy) + 0.5) / Double(grid) - 0.5
                                let sampled = Self.sample(
                                    source, width: sourceWidth, height: sourceHeight,
                                    x: baseX + offsetX * stepX, y: baseY + offsetY * stepY,
                                    outsideIsBlack: outsideIsBlack)
                                sumR += sampled.0
                                sumG += sampled.1
                                sumB += sampled.2
                            }
                        }
                        destination[index] = Float(sumR / sampleCount)
                        destination[index + 1] = Float(sumG / sampleCount)
                        destination[index + 2] = Float(sumB / sampleCount)
                    }
                }
            }
        }
        if cancelled { return image }
        return ImageRGB(width: output.width, height: output.height, data: result)
    }

    private static func sample(
        _ data: UnsafeBufferPointer<Float>, width: Int, height: Int, x: Double, y: Double,
        outsideIsBlack: Bool = false
    ) -> (Double, Double, Double) {
        if outsideIsBlack,
           x < -0.5 || x > Double(width) - 0.5 || y < -0.5 || y > Double(height) - 0.5 {
            return (0, 0, 0)
        }
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)
        let i00 = (y0 * width + x0) * 3
        let i10 = (y0 * width + x1) * 3
        let i01 = (y1 * width + x0) * 3
        let i11 = (y1 * width + x1) * 3
        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy
        let r = Double(data[i00]) * w00 + Double(data[i10]) * w10
            + Double(data[i01]) * w01 + Double(data[i11]) * w11
        let g = Double(data[i00 + 1]) * w00 + Double(data[i10 + 1]) * w10
            + Double(data[i01 + 1]) * w01 + Double(data[i11 + 1]) * w11
        let b = Double(data[i00 + 2]) * w00 + Double(data[i10 + 2]) * w10
            + Double(data[i01 + 2]) * w01 + Double(data[i11 + 2]) * w11
        return (r, g, b)
    }

    // MARK: - GPU 取景预览

    /// 用 Core Image（Metal 后端）生成取景预览：几何变换全在 GPU，单帧 1–2ms。
    /// 这是裁切页拖动时唯一走的路径——不再对像素做 CPU 重采样。
    /// 预览始终是「全幅 + 校正」，裁切框只是叠加在本页 UI 上的取景框。
    func previewCIImage(from snapshot: CIImage, maxLongEdge: Int) -> CIImage {
        var image = snapshot
        // 1. 定向：与 `sourcePoint(oriented:)` 同一语义，先旋转再镜像（翻转跟着屏幕）。
        switch quarterTurns % 4 {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        if flippedH { image = image.oriented(.upMirrored) }
        if flippedV { image = image.oriented(.downMirrored) }
        // 定向后把 extent 归零，后面所有坐标都从画布原点算。
        let oriented = image.extent
        image = image.transformed(
            by: CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))

        // 2. 输出画布：按校正后的外接框，而不是原画幅。
        //    透视/旋转把四角甩出去时，画面会像主流修图 App 一样向外扩展。
        let orientedWidth = max(1, Double(oriented.width))
        let orientedHeight = max(1, Double(oriented.height))
        let bounds = warpBounds(sourceWidth: Int(orientedWidth), sourceHeight: Int(orientedHeight))
        let contentWidth = orientedWidth * bounds.width
        let contentHeight = orientedHeight * bounds.height
        let scale = min(1, Double(maxLongEdge) / max(contentWidth, contentHeight))
        let outWidth = max(1, Int((contentWidth * scale).rounded()))
        let outHeight = max(1, Int((contentHeight * scale).rounded()))
        let canvas = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)

        // 3. 没有水平/透视校正时只缩放。
        guard abs(straighten) > 1e-6
            || abs(perspectiveV) > 1e-6 || abs(perspectiveH) > 1e-6 else {
            return image
                .transformed(by: CGAffineTransform(
                    scaleX: CGFloat(outWidth) / oriented.width,
                    y: CGFloat(outHeight) / oriented.height))
                .cropped(to: canvas)
        }

        // 4. 单应：把源图四角送到 `warpQuad` 算出的位置（相对外接框）。
        //    `warpQuad` 是 y-down 归一化坐标，CI 是 y-up，这里统一换成画布坐标。
        let quad = warpQuad(width: orientedWidth, height: orientedHeight)
        guard quad.count == 4, let filter = CIFilter(name: "CIPerspectiveTransform") else {
            return image.cropped(to: canvas)
        }
        let targets = quad.map { point in
            CGPoint(
                x: (point.x - bounds.minX) / bounds.width * CGFloat(outWidth),
                y: (1 - (point.y - bounds.minY) / bounds.height) * CGFloat(outHeight)
            )
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: targets[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: targets[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: targets[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: targets[3]), forKey: "inputBottomLeft")
        guard let warped = filter.outputImage else { return image.cropped(to: canvas) }
        // perspScale 保证四边形覆盖整个画布，`cropped` 后 extent 恰好等于画布。
        return warped.cropped(to: canvas)
    }

    /// GPU 路径出 CGImage（供 SwiftUI 显示）。
    func previewImage(
        from snapshot: CIImage, maxLongEdge: Int, context: CIContext
    ) -> CGImage? {
        let output = previewCIImage(from: snapshot, maxLongEdge: maxLongEdge)
        // 用整数矩形出图：小数 extent 会让 CI 多做一次对齐重采样。
        let extent = output.extent
        let rect = CGRect(x: extent.minX.rounded(), y: extent.minY.rounded(),
                          width: extent.width.rounded(), height: extent.height.rounded())
        return context.createCGImage(output, from: rect)
    }

    // MARK: - CGImage（预览、原片）

    /// 预览与裁切页都是 8-bit 屏幕图；与导出走同一套几何映射，避免取景框对不上。
    /// `maxLongEdge` 会先把源图降采样再进几何，拖动期不必处理整幅快照。
    func apply(to image: CGImage, maxLongEdge: Int? = nil, maxGrid: Int = 3,
               shouldCancel: () -> Bool = { false }) -> CGImage? {
        guard !isIdentity else { return image }
        guard let source = MRGBACopy.read(image, maxLongEdge: maxLongEdge) else { return nil }
        return apply(buffer: source, maxLongEdge: maxLongEdge,
                     maxGrid: maxGrid, shouldCancel: shouldCancel)
    }

    /// 裁切页取景预览：源缓冲已经解好，拖动刻度时不重复读图。
    /// 单应矩阵每帧只构造一次（`warp`），每像素只做一次映射；
    /// `maxGrid = 1` 时跳过超采样（拖动期快帧用），`shouldCancel` 取消时返回 nil。
    func apply(buffer: MRGBACopy.Buffer, maxLongEdge: Int? = nil, maxGrid: Int = 3,
               shouldCancel: () -> Bool = { false }) -> CGImage? {
        let source = buffer
        if isIdentity {
            return MRGBACopy.makeImage(pixels: source.pixels,
                                       width: source.width, height: source.height)
        }
        let oriented = orientedSize(sourceWidth: source.width, sourceHeight: source.height)
        var output = outputSize(sourceWidth: source.width, sourceHeight: source.height)
        if let maxLongEdge, maxLongEdge > 0 {
            output = self.outputSize(sourceWidth: source.width, sourceHeight: source.height,
                                     maxLongEdge: maxLongEdge)
        }
        guard output.width > 0, output.height > 0 else { return nil }
        let grid = sampleGrid(sourceWidth: oriented.width, sourceHeight: oriented.height,
                              outputWidth: output.width, outputHeight: output.height,
                              maxGrid: maxGrid)
        let sampleCount = Double(grid * grid)
        var pixels = [UInt8](repeating: 255, count: output.width * output.height * 4)
        let geometry = self
        let sourceWidth = source.width
        let sourceHeight = source.height
        let warp = inverseWarp(orientedWidth: oriented.width, orientedHeight: oriented.height)
        let stepX = crop.width * Double(sourceWidth) / Double(output.width)
        let stepY = crop.height * Double(sourceHeight) / Double(output.height)
        let columnU = (0..<output.width).map {
            crop.x + (Double($0) + 0.5) / Double(output.width) * crop.width
        }
        let rowV = (0..<output.height).map {
            crop.y + (Double($0) + 0.5) / Double(output.height) * crop.height
        }
        let outsideIsBlack = abs(straighten) > 1e-6
            || abs(perspectiveV) > 1e-6 || abs(perspectiveH) > 1e-6
        var cancelled = false

        source.pixels.withUnsafeBufferPointer { input in
            pixels.withUnsafeMutableBufferPointer { destination in
                rowLoop: for y in 0..<output.height {
                    if shouldCancel() {
                        cancelled = true
                        break rowLoop
                    }
                    let v = rowV[y]
                    for x in 0..<output.width {
                        let point = geometry.sourcePoint(u: columnU[x], v: v, warp: warp)
                        let baseX = point.x * Double(sourceWidth) - 0.5
                        let baseY = point.y * Double(sourceHeight) - 0.5
                        let index = (y * output.width + x) * 4
                        if grid == 1 {
                            let sampled = Self.sample(
                                input, width: sourceWidth, height: sourceHeight,
                                x: baseX, y: baseY, outsideIsBlack: outsideIsBlack)
                            destination[index] = UInt8(min(max(sampled.0, 0), 255).rounded())
                            destination[index + 1] = UInt8(min(max(sampled.1, 0), 255).rounded())
                            destination[index + 2] = UInt8(min(max(sampled.2, 0), 255).rounded())
                            destination[index + 3] = 255
                            continue
                        }
                        var sumR = 0.0
                        var sumG = 0.0
                        var sumB = 0.0
                        for sy in 0..<grid {
                            for sx in 0..<grid {
                                let offsetX = (Double(sx) + 0.5) / Double(grid) - 0.5
                                let offsetY = (Double(sy) + 0.5) / Double(grid) - 0.5
                                let sampled = Self.sample(
                                    input, width: sourceWidth, height: sourceHeight,
                                    x: baseX + offsetX * stepX, y: baseY + offsetY * stepY,
                                    outsideIsBlack: outsideIsBlack)
                                sumR += sampled.0
                                sumG += sampled.1
                                sumB += sampled.2
                            }
                        }
                        destination[index] = UInt8(min(max(sumR / sampleCount, 0), 255).rounded())
                        destination[index + 1] = UInt8(min(max(sumG / sampleCount, 0), 255).rounded())
                        destination[index + 2] = UInt8(min(max(sumB / sampleCount, 0), 255).rounded())
                        destination[index + 3] = 255
                    }
                }
            }
        }
        if cancelled { return nil }
        return MRGBACopy.makeImage(pixels: pixels, width: output.width, height: output.height)
    }

    private static func sample(
        _ data: UnsafeBufferPointer<UInt8>, width: Int, height: Int, x: Double, y: Double,
        outsideIsBlack: Bool = false
    ) -> (Double, Double, Double) {
        if outsideIsBlack,
           x < -0.5 || x > Double(width) - 0.5 || y < -0.5 || y > Double(height) - 0.5 {
            return (0, 0, 0)
        }
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)
        let i00 = (y0 * width + x0) * 4
        let i10 = (y0 * width + x1) * 4
        let i01 = (y1 * width + x0) * 4
        let i11 = (y1 * width + x1) * 4
        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy
        let r = Double(data[i00]) * w00 + Double(data[i10]) * w10
            + Double(data[i01]) * w01 + Double(data[i11]) * w11
        let g = Double(data[i00 + 1]) * w00 + Double(data[i10 + 1]) * w10
            + Double(data[i01 + 1]) * w01 + Double(data[i11 + 1]) * w11
        let b = Double(data[i00 + 2]) * w00 + Double(data[i10 + 2]) * w10
            + Double(data[i01 + 2]) * w01 + Double(data[i11 + 2]) * w11
        return (r, g, b)
    }
}

// MARK: - 单应矩阵

/// 二维投影映射：(x, y) → (a x + b y + c, d x + e y + f) / (g x + h y + 1)。
struct MHomography {
    var a = 1.0
    var b = 0.0
    var c = 0.0
    var d = 0.0
    var e = 1.0
    var f = 0.0
    var g = 0.0
    var h = 0.0

    static let identity = MHomography()

    func map(_ point: CGPoint) -> CGPoint {
        let w = g * point.x + h * point.y + 1
        guard abs(w) > 1e-12 else { return point }
        return CGPoint(
            x: (a * point.x + b * point.y + c) / w,
            y: (d * point.x + e * point.y + f) / w
        )
    }

    var inverted: MHomography? {
        let determinant = a * (e - f * h) - b * (d - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 1e-12 else { return nil }
        let ia = (e - f * h) / determinant
        let ib = (c * h - b) / determinant
        let ic = (b * f - c * e) / determinant
        let id = (f * g - d) / determinant
        let ie = (a - c * g) / determinant
        let iff = (c * d - a * f) / determinant
        let ig = (d * h - e * g) / determinant
        let ih = (b * g - a * h) / determinant
        let ii = (a * e - b * d) / determinant
        guard abs(ii) > 1e-12 else { return nil }
        return MHomography(
            a: ia / ii, b: ib / ii, c: ic / ii,
            d: id / ii, e: ie / ii, f: iff / ii,
            g: ig / ii, h: ih / ii
        )
    }

    /// 单位方框四角（左上、右上、右下、左下）→ 任意凸四边形。
    static func unitSquareToQuad(_ quad: [CGPoint]) -> MHomography? {
        guard quad.count == 4 else { return nil }
        let x0 = quad[0].x, y0 = quad[0].y
        let x1 = quad[1].x, y1 = quad[1].y
        let x2 = quad[2].x, y2 = quad[2].y
        let x3 = quad[3].x, y3 = quad[3].y

        let sx = x0 - x1 + x2 - x3
        let sy = y0 - y1 + y2 - y3
        if abs(sx) < 1e-12 && abs(sy) < 1e-12 {
            return MHomography(
                a: x1 - x0, b: x3 - x0, c: x0,
                d: y1 - y0, e: y3 - y0, f: y0,
                g: 0, h: 0
            )
        }

        let px = x1 - x2
        let py = y1 - y2
        let qx = x3 - x2
        let qy = y3 - y2
        let rx = x0 - x1 + x2 - x3
        let ry = y0 - y1 + y2 - y3
        let determinant = px * qy - qx * py
        guard abs(determinant) > 1e-12 else { return nil }
        let g = (rx * qy - qx * ry) / determinant
        let h = (px * ry - rx * py) / determinant

        return MHomography(
            a: x1 * (g + 1) - x0,
            b: x3 * (h + 1) - x0,
            c: x0,
            d: y1 * (g + 1) - y0,
            e: y3 * (h + 1) - y0,
            f: y0,
            g: g,
            h: h
        )
    }
}

// MARK: - RGBA8 缓冲

/// 预览图按固定的 RGBA8 布局读写，避免不同 CGImage 位深/字节序带来的差异。
enum MRGBACopy {
    struct Buffer {
        let width: Int
        let height: Int
        var pixels: [UInt8]
    }

    static func makeImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = pixels
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// 读取成 RGBA8 缓冲。`maxLongEdge` 不为空时在绘制阶段直接降采样，
    /// 裁切取景用压缩快照，拖动时不必反复处理整幅交接图。
    static func read(_ image: CGImage, maxLongEdge: Int? = nil) -> Buffer? {
        var width = image.width
        var height = image.height
        guard width > 0, height > 0 else { return nil }
        if let maxLongEdge, maxLongEdge > 0, max(width, height) > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }
        return Buffer(width: width, height: height, pixels: pixels)
    }
}


