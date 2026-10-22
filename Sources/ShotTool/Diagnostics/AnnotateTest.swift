import AppKit

/// 标注合成的自检。
///
/// 重点验证两件肉眼容易看漏的事：
/// 1. 标注有没有真的画进图里（不是空合成）
/// 2. 有没有上下翻转（CGContext 默认原点在左下，很容易画成镜像）
@MainActor
enum AnnotateTest {

    static func run() -> Int32 {
        print("标注合成测试\n")

        guard ScreenCaptureService.hasPermission() else {
            print("没有屏幕录制权限，跳过。")
            return 1
        }

        var frames: [CGDirectDisplayID: DisplayFrame]?
        var failure: Error?

        Task { @MainActor in
            do {
                frames = try await ScreenCaptureService.captureAllDisplays(
                    contexts: ScreenGeometry.displayContexts()
                )
            } catch {
                failure = error
            }
        }

        let deadline = Date().addingTimeInterval(60)
        while frames == nil && failure == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if let failure {
            print("抓屏失败：\(failure.localizedDescription)")
            return 1
        }
        guard let frames, let frame = frames.values.first else {
            print("没有拿到画面")
            return 1
        }

        // 固定裁一块 1600×1000 像素（够放下测试标注）
        let width = 1600
        let height = 1000
        let cropRect = CGRect(x: 0, y: 0, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))

        guard let base = frame.image.cropping(to: cropRect.integral) else {
            print("裁剪失败")
            return 1
        }

        // 矩形边框：左边框 x=100，纵向从 100 到 200
        let annotations: [Annotation] = [
            Annotation(
                kind: .rectangle,
                start: CGPoint(x: 100, y: 100),
                end: CGPoint(x: 300, y: 200),
                style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 28)
            ),
            Annotation(
                kind: .arrow,
                start: CGPoint(x: 400, y: 400),
                end: CGPoint(x: 700, y: 150),
                style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 28)
            ),
            Annotation(
                kind: .text,
                start: CGPoint(x: 100, y: 600),
                end: CGPoint(x: 100, y: 600),
                text: "合成测试",
                style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 36)
            ),
            // 三条不同长度的箭头，用来对比头部是否随长度变化
            Annotation(
                kind: .arrow,
                start: CGPoint(x: 100, y: 720),
                end: CGPoint(x: 190, y: 740),
                style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 28)
            ),
            Annotation(
                kind: .arrow,
                start: CGPoint(x: 100, y: 800),
                end: CGPoint(x: 430, y: 780),
                style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 28)
            ),
            Annotation(
                kind: .arrow,
                start: CGPoint(x: 100, y: 900),
                end: CGPoint(x: 1100, y: 860),
                style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 28)
            )
        ]

        let result = AnnotationRenderer.composite(base: base, annotations: annotations, scale: 1)

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  [通过] \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
                     : "  [失败] \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        print("1. 尺寸")
        check(
            "合成后尺寸不变",
            result.width == base.width && result.height == base.height,
            "\(result.width)×\(result.height)"
        )

        print("\n2. 标注是否落在正确位置（同时能发现上下翻转）")
        // 左边框中心点：矩形 rec(100,100)-(300,200) 的左边框
        let edge = pixel(result, x: 100, y: 150)
        check("左边框在 y=150 处是红色", isRed(edge), "rgb\(edge)")

        // 矩形内部：应该是原图，不是红线
        let inside = pixel(result, x: 200, y: 150)
        check("矩形内部没有被填充", !isRed(inside), "rgb\(inside)")

        // 上下翻转检测：如果 CTM 翻错，红线会跑到 y = height-150 附近
        let mirrored = pixel(result, x: 100, y: height - 150)
        check("下半部分对称位置没有红线（说明没翻转）", !isRed(mirrored), "rgb\(mirrored)")

        print("\n3. 箭头与文字")
        let arrowBody = pixel(result, x: 550, y: 275)
        check("箭头线段中部有红色像素", isRed(arrowBody), "rgb\(arrowBody)")

        let textArea = diffRatio(result, base, in: CGRect(x: 95, y: 590, width: 200, height: 60))
        check("文字区域有改动", textArea > 0.01, String(format: "%.3f", textArea))

        print("\n4. 整体差异")
        let overall = diffRatio(result, base, in: CGRect(x: 0, y: 0, width: width, height: height))
        check("合成图与原图存在差异", overall > 0.001, String(format: "%.4f", overall))

        let directory = URL(fileURLWithPath: "/tmp/shottool-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = directory.appendingPathComponent("annotated.png")
        let saved = ImageOutput.save(result, to: out)
        let raw = directory.appendingPathComponent("annotated-base.png")
        _ = ImageOutput.save(base, to: raw)

        print("\n产物：\(saved ? out.path : "保存失败")")
        print("       \(raw.path)（原始裁切，用于对比）")
        print(failures == 0 ? "\n全部通过。" : "\n有 \(failures) 项异常。")
        return failures == 0 ? 0 : 1
    }

    // MARK: - 工具

    private static func rgbaBuffer(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (buffer, width, height)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    /// buffer 的行序与视觉上下一致：第 0 行就是最上面一行，
    /// 所以左上原点的 y 可以直接当行号用（这里曾经多翻了一次，导致误判成镜像）。
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> String {
        let (data, width, height) = rgbaBuffer(image)
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let index = (clampedY * width + clampedX) * 4
        guard index + 2 < data.count else { return "越界" }
        return "\(data[index]),\(data[index + 1]),\(data[index + 2])"
    }

    private static func isRed(_ rgb: String) -> Bool {
        let parts = rgb.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return parts[0] > 140 && parts[1] < 100 && parts[2] < 100
    }

    /// 两图在指定区域的差异像素占比
    private static func diffRatio(_ a: CGImage, _ b: CGImage, in rect: CGRect) -> Double {
        let (da, wa, ha) = rgbaBuffer(a)
        let (db, wb, hb) = rgbaBuffer(b)
        guard wa == wb, ha == hb else { return 0 }

        let minX = max(0, Int(rect.minX))
        let maxX = min(wa, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(ha, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return 0 }

        var changed = 0
        var total = 0

        for y in minY..<maxY {
            for x in minX..<maxX {
                let index = (y * wa + x) * 4
                guard index + 3 < da.count, index + 3 < db.count else { continue }
                total += 1
                let delta = abs(Int(da[index]) - Int(db[index]))
                    + abs(Int(da[index + 1]) - Int(db[index + 1]))
                    + abs(Int(da[index + 2]) - Int(db[index + 2]))
                if delta > 24 { changed += 1 }
            }
        }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }
}
