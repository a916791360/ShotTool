import AppKit

/// 捕获链路验证：真的截一张图下来，检查尺寸是否 1:1、画面里是否真有内容。
///
/// 为什么要查「内容」：没有屏幕录制权限时，ScreenCaptureKit 不一定报错，
/// 而是安静地返回一张空桌面图。只检查「有没有拿到图」会漏掉这种情况。
@MainActor
enum CaptureTest {

    static func run() -> Int32 {
        let contexts = ScreenGeometry.displayContexts()
        print("捕获测试 · \(contexts.count) 块屏 · 权限 \(ScreenCaptureService.hasPermission() ? "已授予" : "未授予")\n")

        guard ScreenCaptureService.hasPermission() else {
            print("没有屏幕录制权限，跳过。")
            return 1
        }

        var result: Result<[CGDirectDisplayID: DisplayFrame], Error>?
        Task { @MainActor in
            do {
                result = .success(
                    try await ScreenCaptureService.captureAllDisplays(contexts: contexts)
                )
            } catch {
                result = .failure(error)
            }
        }

        let deadline = Date().addingTimeInterval(60)
        while result == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let result else {
            print("超时：60 秒内没有拿到截图。")
            return 1
        }

        switch result {
        case .failure(let error):
            print("失败：\(error.localizedDescription)")
            return 1
        case .success(let frames):
            return report(frames: frames, contexts: contexts)
        }
    }

    private static func report(
        frames: [CGDirectDisplayID: DisplayFrame],
        contexts: [DisplayContext]
    ) -> Int32 {
        let directory = URL(fileURLWithPath: "/tmp/shottool-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var failures = 0

        for context in contexts {
            guard let frame = frames[context.displayID] else {
                print("显示 \(context.displayID)：没有拿到帧")
                failures += 1
                continue
            }

            let expectedWidth = Int((context.cgRect.width * context.scale).rounded())
            let expectedHeight = Int((context.cgRect.height * context.scale).rounded())
            let sizeOK = frame.image.width == expectedWidth && frame.image.height == expectedHeight

            let stats = thumbnailStats(frame.image)
            let hasContent = stats.stddev > 0.01

            let url = directory.appendingPathComponent("display-\(context.displayID).png")
            let saved = ImageOutput.save(frame.image, to: url)

            print("显示器 \(context.displayID)")
            print("  实际像素      \(frame.image.width) × \(frame.image.height)")
            print("  期望像素      \(expectedWidth) × \(expectedHeight)  \(sizeOK ? "一致" : "不一致")")
            print("  倍率 / 逻辑尺寸  \(context.scale)x / \(context.cgRect.width) × \(context.cgRect.height) pt")
            print("  画面标准差    \(String(format: "%.4f", stats.stddev))  \(hasContent ? "有内容" : "疑似空图")")
            print("  已保存        \(saved ? url.path : "保存失败")")
            print("")

            if !sizeOK { failures += 1 }
            if !hasContent { failures += 1 }
        }

        print(failures == 0 ? "全部通过。" : "有 \(failures) 项异常。")
        return failures == 0 ? 0 : 1
    }

    /// 缩到 64×64 后算亮度标准差，用来判断「是不是一张纯色图」。
    private static func thumbnailStats(_ image: CGImage) -> (mean: Double, stddev: Double) {
        let side = 64
        var buffer = [UInt8](repeating: 0, count: side * side * 4)

        guard let context = CGContext(
            data: &buffer,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0)
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0

        for index in stride(from: 0, to: buffer.count, by: 4) {
            let value = Double(buffer[index]) / 255.0
            sum += value
            sumOfSquares += value * value
            count += 1
        }

        let mean = sum / Double(count)
        let variance = max(0, sumOfSquares / Double(count) - mean * mean)
        return (mean, variance.squareRoot())
    }
}
