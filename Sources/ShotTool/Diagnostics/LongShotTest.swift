import AppKit

/// 长截图拼接的纯算法自检。
///
/// 不碰真实滚动，只验证「两张有重叠的图能不能正确拼回去」——
/// 这是长截图最容易错的地方（重叠高度算错 1px，整张图就错位）。
@MainActor
enum LongShotTest {

    static func run() -> Int32 {
        print("长截图拼接测试\n")

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  [通过] \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
                     : "  [失败] \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        let width = 400
        let fullHeight = 1400
        let overlapExpected = 200
        let frameHeight = 800

        guard let full = makeTestImage(width: width, height: fullHeight) else {
            print("测试图生成失败")
            return 1
        }

        // 帧 1：0 ..< 800
        // 帧 2：600 ..< 1400，与帧 1 重叠 200
        guard let frame1 = full.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight)),
              let frame2 = full.cropping(to: CGRect(
                x: 0,
                y: fullHeight - frameHeight,
                width: width,
                height: frameHeight
              ))
        else {
            print("切片失败")
            return 1
        }

        print("1. 输入")
        check("帧尺寸正确", frame1.width == width && frame1.height == frameHeight, "\(frame1.width)×\(frame1.height)")
        check("两帧预期重叠 \(overlapExpected)px", true)

        print("\n2. 拼接")
        guard let stitched = LongShotService.stitch([frame1, frame2]) else {
            check("拼接成功", false, "返回 nil")
            return 1
        }
        check("拼接成功", true)

        let expectedHeight = frameHeight + frameHeight - overlapExpected
        check(
            "总高度正确",
            stitched.height == expectedHeight,
            "实际 \(stitched.height)，期望 \(expectedHeight)"
        )
        check("宽度不变", stitched.width == width, "\(stitched.width)")

        print("\n3. 像素校验（拼接处有没有错位）")
        // 逐行比对：拼接结果应当和原图高度一致地对应
        if stitched.height == fullHeight {
            let diff = rowDiffRatio(stitched, full)
            check("与原图逐行一致", diff < 0.01, String(format: "差异 %.4f", diff))
        } else {
            // 高度对不上时，至少检查重叠区过渡是否连续
            check("高度与原图一致", false, "\(stitched.height) vs \(fullHeight)")
        }

        let dir = URL(fileURLWithPath: "/tmp/shottool-test", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = ImageOutput.save(stitched, to: dir.appendingPathComponent("longshot-stitched.png"))
        _ = ImageOutput.save(full, to: dir.appendingPathComponent("longshot-original.png"))

        // MARK: 重复内容场景（模拟聊天记录）
        //
        // 聊天界面每条消息结构高度相似，只靠"找最相似的横带"很容易匹配到错位置，
        // 拼出来就是内容重复、衔接错位。这里带先验重叠量再拼一次，验证改进是否有效。
        print("\n4. 重复内容场景（模拟聊天记录）")

        // 图高要正好被「帧高 + 一个步进」覆盖，否则最后一帧切不出来，
        // 期望高度就无从比较（第一版设 1600，只切出 2 帧、缺 224px，测试自己错了）
        let frameH = 800
        let stepPx = 576                 // 每帧滚动量
        let expected = frameH - stepPx   // 224
        let repeatHeight = frameH + stepPx   // 1376 = 2 帧正好覆盖

        guard let repeating = makeRepeatingImage(width: width, height: repeatHeight) else {
            check("重复内容测试图生成", false)
            return 1
        }

        var repeatedFrames: [CGImage] = []
        var offset = 0
        while offset + frameH <= repeatHeight {
            if let frame = repeating.cropping(to: CGRect(x: 0, y: offset, width: width, height: frameH)) {
                repeatedFrames.append(frame)
            }
            offset += stepPx
        }
        check("切出 \(repeatedFrames.count) 帧", repeatedFrames.count >= 2)

        guard let repeatedStitched = LongShotService.stitch(
            repeatedFrames,
            expectedOverlap: expected
        ) else {
            check("重复内容拼接成功", false, "返回 nil（宁可失败也不该拼错）")
            return 1
        }

        check("重复内容拼接成功", true)
        check(
            "高度正确",
            repeatedStitched.height == repeatHeight,
            "实际 \(repeatedStitched.height)，期望 \(repeatHeight)"
        )

        if repeatedStitched.height == repeatHeight {
            let repeatDiff = rowDiffRatio(repeatedStitched, repeating)
            check("逐行一致（没有重复/错位）", repeatDiff < 0.01, String(format: "差异 %.4f", repeatDiff))
        }

        _ = ImageOutput.save(repeatedStitched, to: dir.appendingPathComponent("longshot-repeated.png"))
        _ = ImageOutput.save(repeating, to: dir.appendingPathComponent("longshot-repeated-original.png"))

        // MARK: 无特征场景（匹配必然失败，验证「不失败」）
        //
        // 纯色 / 大片留白的页面里，图像匹配根本无从下手。
        // 这时必须靠滚动量硬拼——高度正确就算通过，内容有轻微重影可以接受。
        print("\n5. 无特征场景（匹配必失败，验证不中断）")

        guard let plain = makePlainImage(width: width, height: repeatHeight) else {
            check("无特征图生成", false)
            return 1
        }

        var plainFrames: [CGImage] = []
        offset = 0
        while offset + frameH <= repeatHeight {
            if let frame = plain.cropping(to: CGRect(x: 0, y: offset, width: width, height: frameH)) {
                plainFrames.append(frame)
            }
            offset += stepPx
        }

        guard let plainStitched = LongShotService.stitch(
            plainFrames,
            expectedOverlap: expected
        ) else {
            check("无特征也能拼出来", false, "返回 nil —— 这不该发生")
            return 1
        }

        check("无特征也能拼出来", true)
        check(
            "高度正确（按滚动量）",
            plainStitched.height == repeatHeight,
            "实际 \(plainStitched.height)，期望 \(repeatHeight)"
        )

        _ = ImageOutput.save(plainStitched, to: dir.appendingPathComponent("longshot-plain.png"))

        // MARK: 多帧 + 每段滚动量不同
        //
        // 真实使用中每段的滚动量不可能完全一致（系统加速、页面惯性）。
        // 这里模拟「第一段滚 500、第二段滚 700」，验证每段独立重叠能否正确拼接。
        print("\n6. 多帧、每段滚动量不同")

        let totalH = 2000
        guard let longImage = makeRepeatingImage(width: width, height: totalH) else {
            check("长图生成", false)
            return 1
        }

        // 三个窗口：0、500、1200；每帧高 800
        let starts = [0, 500, 1200]
        var multiFrames: [CGImage] = []
        for start in starts {
            if let frame = longImage.cropping(to: CGRect(x: 0, y: start, width: width, height: frameH)) {
                multiFrames.append(frame)
            }
        }
        check("切出 3 帧", multiFrames.count == 3, "\(multiFrames.count)")

        // 第 2 帧与第 1 帧重叠 800-500=300；第 3 帧与第 2 帧重叠 1300-1200=100
        let planned = [300, 100]
        if let multiStitched = LongShotService.stitch(multiFrames, plannedOverlaps: planned) {
            check("多帧拼接成功", true)
            check(
                "高度正确",
                multiStitched.height == totalH,
                "实际 \(multiStitched.height)，期望 \(totalH)"
            )
            if multiStitched.height == totalH {
                let d = rowDiffRatio(multiStitched, longImage)
                check("逐行一致", d < 0.01, String(format: "差异 %.4f", d))
            }
            _ = ImageOutput.save(multiStitched, to: dir.appendingPathComponent("longshot-multi.png"))
        } else {
            check("多帧拼接成功", false)
        }

        print("\n产物目录：\(dir.path)")

        print(failures == 0 ? "\n全部通过。" : "\n有 \(failures) 项异常。")
        return failures == 0 ? 0 : 1
    }

    /// 造一张「匹配必然失败」的图：大片浅色 + 随机噪点。
    /// 噪点互不相关，所以模板在任何位置都对不上，用来验证兜底路径。
    private static func makePlainImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var seed: UInt64 = 0x9E3779B97F4A7C15
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        for _ in 0..<(width * height / 30) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Int((seed >> 33) % UInt64(width))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = Int((seed >> 33) % UInt64(height))
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 2, height: 2))
        }
        return ctx.makeImage()
    }

    /// 造一张「结构重复但内容可区分」的图：每 200px 一个卡片，卡片内横线条数递增。
    /// 这模拟聊天记录——外形相似，细节不同。
    private static func makeRepeatingImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let blockHeight = 200
        var index = 0
        var y = 0
        while y < height {
            // 卡片底色（交替深浅，像不同的消息气泡）
            let shade = index % 2 == 0 ? 0.94 : 0.88
            ctx.setFillColor(CGColor(gray: shade, alpha: 1))
            ctx.fill(CGRect(x: 20, y: CGFloat(height - y - blockHeight + 10), width: CGFloat(width - 40), height: 180))

            // 卡片内横线条数随序号递增，作为区分特征
            ctx.setFillColor(CGColor(gray: 0.35, alpha: 0.9))
            let lines = 1 + (index % 5)
            for line in 0..<lines {
                let lineY = CGFloat(height - y - 30 - line * 22)
                ctx.fill(CGRect(x: 40, y: lineY, width: CGFloat(width - 120 - line * 20), height: 6))
            }

            // 左侧头像方块，位置固定
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(width - 60), y: CGFloat(height - y - 50), width: 30, height: 30))

            y += blockHeight
            index += 1
        }

        return ctx.makeImage()
    }

    /// 造一张有明显纵向特征的图：每 50px 一条横线 + 渐变，方便匹配算法找重叠。
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let colors = [CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1),
                      CGColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 1)]
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return nil }

        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: CGFloat(height)),
            options: []
        )

        // 每 50px 一条横线，线条带一点位置编码（越往下越粗）
        for y in stride(from: 0, to: height, by: 50) {
            let thickness = CGFloat(2 + (y / 50) % 4)
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 0.85))
            ctx.fill(CGRect(x: 0, y: CGFloat(height - y - Int(thickness)), width: CGFloat(width), height: thickness))
        }

        // 左侧竖条，防止纯横线导致匹配退化成任意位置
        for i in 0..<8 {
            let w = CGFloat(width) / 8
            ctx.setFillColor(CGColor(gray: 0.3 + Double(i) * 0.06, alpha: 0.5))
            ctx.fill(CGRect(x: CGFloat(i) * w, y: 0, width: w, height: 40))
        }

        return ctx.makeImage()
    }

    /// 两张同尺寸图逐行平均差异
    private static func rowDiffRatio(_ a: CGImage, _ b: CGImage) -> Double {
        guard let ga = gray(a), let gb = gray(b), ga.count == gb.count else { return 1 }
        var total = 0
        var count = 0
        for index in stride(from: 0, to: ga.count, by: 7) {
            total += abs(Int(ga[index]) - Int(gb[index]))
            count += 1
        }
        return count == 0 ? 1 : Double(total) / (Double(count) * 255)
    }

    private static func gray(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
