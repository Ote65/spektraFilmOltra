import Foundation

/// 与 numpy `fftconvolve(mode="same")` 对齐的 2D 卷积。
/// 本机 CLT 的 SDK 与编译器版本不匹配，`import Accelerate` 会触发 SwiftBridging 模块冲突，
/// 因此通过 `dlopen` 调用 Accelerate 的 Double 精度复数 FFT（`vDSP_fft_zipD`）。
enum FFTConvolution {
    /// 与 Accelerate `DSPSplitComplex` 内存布局一致（两个指针）。
    struct SplitComplexD {
        var realp: UnsafeMutablePointer<Double>?
        var imagp: UnsafeMutablePointer<Double>?
    }

    private static let forwardDirection: Int32 = 1
    private static let inverseDirection: Int32 = -1
    private static let radix2: Int32 = 0
    private static let lock = NSLock()
    private static var setups: [Int: UnsafeMutableRawPointer] = [:]

    private static let createSetup: ((UInt32, Int32) -> UnsafeMutableRawPointer?)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_LAZY
        ), let symbol = dlsym(handle, "vDSP_create_fftsetupD") else { return nil }
        typealias Function = @convention(c) (UInt32, Int32) -> UnsafeMutableRawPointer?
        return unsafeBitCast(symbol, to: Function.self)
    }()

    private static let fftZip: ((UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, UInt32, Int32) -> Void)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Accelerate.framework/Accelerate", RTLD_LAZY
        ), let symbol = dlsym(handle, "vDSP_fft_zipD") else { return nil }
        typealias Function = @convention(c) (
            UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, UInt32, Int32
        ) -> Void
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }

    private static func setup(_ length: Int) -> UnsafeMutableRawPointer? {
        let log2n = Int(log2(Double(length)))
        lock.lock()
        defer { lock.unlock() }
        if let existing = setups[log2n] { return existing }
        guard let created = createSetup?(UInt32(log2n), radix2) else { return nil }
        setups[log2n] = created
        return created
    }

    static func fft2D(_ re: inout [Double], _ im: inout [Double], width: Int, height: Int, inverse: Bool) {
        let direction = inverse ? inverseDirection : forwardDirection
        var currentWidth = width
        var currentHeight = height
        transformRows(&re, &im, width: currentWidth, height: currentHeight, direction: direction)
        (currentWidth, currentHeight) = transpose(&re, &im, width: currentWidth, height: currentHeight)
        transformRows(&re, &im, width: currentWidth, height: currentHeight, direction: direction)
        _ = transpose(&re, &im, width: currentWidth, height: currentHeight)
        if inverse {
            let scale = 1.0 / Double(width * height)
            for i in 0..<re.count { re[i] *= scale }
            for i in 0..<im.count { im[i] *= scale }
        }
    }

    private static func transformRows(_ re: inout [Double], _ im: inout [Double],
                                      width: Int, height: Int, direction: Int32) {
        guard let setup = setup(width), let fftZip else { return }
        let log2n = UInt32(log2(Double(width)))
        re.withUnsafeMutableBufferPointer { reBuffer in
            im.withUnsafeMutableBufferPointer { imBuffer in
                guard let reBase = reBuffer.baseAddress, let imBase = imBuffer.baseAddress else { return }
                for y in 0..<height {
                    var split = SplitComplexD(
                        realp: reBase.advanced(by: y * width),
                        imagp: imBase.advanced(by: y * width)
                    )
                    withUnsafeMutablePointer(to: &split) { pointer in
                        fftZip(setup, UnsafeMutableRawPointer(pointer), 1, log2n, direction)
                    }
                }
            }
        }
    }

    private static func transpose(_ re: inout [Double], _ im: inout [Double],
                                  width: Int, height: Int) -> (Int, Int) {
        var transposedRe = [Double](repeating: 0, count: re.count)
        var transposedIm = [Double](repeating: 0, count: im.count)
        for y in 0..<height {
            let source = y * width
            for x in 0..<width {
                let target = x * height + y
                transposedRe[target] = re[source + x]
                transposedIm[target] = im[source + x]
            }
        }
        re = transposedRe
        im = transposedIm
        return (height, width)
    }

    /// 对单通道图像做 `same` 卷积（与 numpy `fftconvolve(mode="same")` 一致）。
    static func convolveSame(image: [Double], width: Int, height: Int,
                             kernel: [Double], kernelWidth: Int, kernelHeight: Int) -> [Double] {
        let fftWidth = nextPowerOfTwo(width + kernelWidth - 1)
        let fftHeight = nextPowerOfTwo(height + kernelHeight - 1)
        let total = fftWidth * fftHeight
        var imageRe = [Double](repeating: 0, count: total)
        var imageIm = [Double](repeating: 0, count: total)
        var kernelRe = [Double](repeating: 0, count: total)
        var kernelIm = [Double](repeating: 0, count: total)
        for y in 0..<height {
            for x in 0..<width { imageRe[y * fftWidth + x] = image[y * width + x] }
        }
        for y in 0..<kernelHeight {
            for x in 0..<kernelWidth { kernelRe[y * fftWidth + x] = kernel[y * kernelWidth + x] }
        }
        fft2D(&imageRe, &imageIm, width: fftWidth, height: fftHeight, inverse: false)
        fft2D(&kernelRe, &kernelIm, width: fftWidth, height: fftHeight, inverse: false)
        for i in 0..<total {
            let re = imageRe[i] * kernelRe[i] - imageIm[i] * kernelIm[i]
            let im = imageRe[i] * kernelIm[i] + imageIm[i] * kernelRe[i]
            imageRe[i] = re
            imageIm[i] = im
        }
        fft2D(&imageRe, &imageIm, width: fftWidth, height: fftHeight, inverse: true)
        let startX = (kernelWidth - 1) / 2
        let startY = (kernelHeight - 1) / 2
        var output = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let source = (y + startY) * fftWidth
            let target = y * width
            for x in 0..<width { output[target + x] = imageRe[source + x + startX] }
        }
        return output
    }
}
