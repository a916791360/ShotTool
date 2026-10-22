import AppKit
import ApplicationServices

/// 长截图（滚动截图）。
///
/// 三个步骤：注入滚轮事件 → 逐帧抓取 → 按重叠区拼接。
///
/// 需要「辅助功能」权限（发送滚轮事件），这和屏幕录制是两个独立授权。
enum LongShotService {

    struct Options {
        /// 选区（CG 全局 pt，左上原点）
        var selection: CGRect
        /// pt → px
        var scale: CGFloat
        var maxFrames: Int = 40
        /// 每帧滚动距离占选区高度的比例。小一点重叠更多、拼接更稳，但帧数变多
        var scrollRatio: CGFloat = 0.75
    }

    enum LongShotError: LocalizedError {
        case noAccessibility
        case noFrames
        case stitchFailed

        var errorDescription: String? {
            switch self {
            case .noAccessibility:
                return "长截图需要「辅助功能」权限，用来模拟滚轮。请在系统设置 → 隐私与安全性 → 辅助功能里勾选 ShotTool。"
            case .noFrames:
                return "一帧都没抓到。"
            case .stitchFailed:
                return "拼接失败：相邻两帧找不到重叠区域，可能页面滚动时内容变了。"
            }
        }
    }

    // MARK: - 辅助功能权限

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 主流程

    static func capture(
        options: Options,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> CGImage {
        guard hasAccessibility() else { throw LongShotError.noAccessibility }

        let scrollPixels = max(40, options.selection.height * options.scale * options.scrollRatio)

        // 抓一帧的工具：抓全屏再裁选区（复用现有链路，保证和普通截图一致）
        func grabFrame() async throws -> CGImage? {
            let contexts = await ScreenGeometry.displayContexts()
            let frames = try await ScreenCaptureService.captureAllDisplays(contexts: contexts, timeout: 5)

            let center = CGPoint(x: options.selection.midX, y: options.selection.midY)
            guard let context = contexts.first(where: { $0.cgRect.contains(center) }),
                  let frame = frames[context.displayID] else { return nil }

            let local = options.selection.offsetBy(
                dx: -frame.cgRect.minX,
                dy: -frame.cgRect.minY
            )
            let pixelRect = CGRect(
                x: (local.minX * frame.scale).rounded(),
                y: (local.minY * frame.scale).rounded(),
                width: (local.width * frame.scale).rounded(),
                height: (local.height * frame.scale).rounded()
            )
            let imageBounds = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
            let safe = pixelRect.intersection(imageBounds)
            guard !safe.isNull, safe.width >= 1, safe.height >= 1 else { return nil }
            return frame.image.cropping(to: safe.integral)
        }

        var collected: [CGImage] = []

        // 先把视图滚回顶部，避免从半截开始
        for _ in 0..<30 {
            scroll(by: scrollPixels * 3, at: options.selection)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 350_000_000)

        var previous: CGImage?

        for index in 0..<options.maxFrames {
            guard let frame = try await grabFrame() else { break }

            if let previous, framesAreSame(previous, frame) {
                // 两帧完全一样 = 已经滚不动了
                break
            }

            collected.append(frame)
            onProgress?(collected.count)

            // 第一帧抓完再开始滚，避免开头少一段
            if index + 1 < options.maxFrames {
                scroll(by: -scrollPixels, at: options.selection)
                try await Task.sleep(nanoseconds: 420_000_000)
            }
            previous = frame
        }

        guard !collected.isEmpty else { throw LongShotError.noFrames }
        guard collected.count > 1 else { return collected[0] }

        guard let stitched = stitch(collected) else { throw LongShotError.stitchFailed }
        return stitched
    }

    // MARK: - 单帧抓取

    /// 抓取指定区域（CG 全局 pt）的一帧。交互式长截图靠它逐帧取样。
    static func captureRegion(selection: CGRect, scale: CGFloat) async throws -> CGImage? {
        let contexts = await ScreenGeometry.displayContexts()
        let frames = try await ScreenCaptureService.captureAllDisplays(contexts: contexts, timeout: 5)

        let center = CGPoint(x: selection.midX, y: selection.midY)
        guard let context = contexts.first(where: { $0.cgRect.contains(center) }),
              let frame = frames[context.displayID] else { return nil }

        let local = selection.offsetBy(dx: -frame.cgRect.minX, dy: -frame.cgRect.minY)
        let pixelRect = CGRect(
            x: (local.minX * frame.scale).rounded(),
            y: (local.minY * frame.scale).rounded(),
            width: (local.width * frame.scale).rounded(),
            height: (local.height * frame.scale).rounded()
        )
        let imageBounds = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        let safe = pixelRect.intersection(imageBounds)
        guard !safe.isNull, safe.width >= 1, safe.height >= 1 else { return nil }
        return frame.image.cropping(to: safe.integral)
    }

    // MARK: - 滚动注入

    /// 滚动一次（自动滚动用）。
    ///
    /// 两个关键点，都是被实测逼出来的：
    /// 1. **必须发完整阶段序列**（began → changed → ended）。只发一个孤立的 changed 事件，
    ///    Electron / CEF 类应用（钉钉、飞书、VS Code 这类）会当无效事件丢掉。
    /// 2. **直接投递到目标进程**（`postToPid`），不经过遮罩。
    ///    之前是「注入到 HID → 遮罩收到 → 遮罩转发」，多一道手，字段容易在重新投递时丢失。
    ///
    /// - Parameter amount: 正数向上滚（看上面的内容），负数向下滚
    static func scroll(by amount: CGFloat, at selection: CGRect, targetPID: pid_t? = nil) {
        let center = CGPoint(x: selection.midX, y: selection.midY)

        // 完整序列：began(0) → changed(amount) → ended(0)
        send(phase: 1, delta: 0, at: center, pid: targetPID)
        send(phase: 2, delta: amount, at: center, pid: targetPID)
        send(phase: 4, delta: 0, at: center, pid: targetPID)
    }

    private static func send(phase: Int64, delta: CGFloat, at point: CGPoint, pid: pid_t?) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: Int32(delta),
                  wheel2: 0,
                  wheel3: 0
              ) else { return }

        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(delta))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(delta))
        event.location = point

        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// 鼠标下面的目标进程（滚动该发给谁）
    ///
    /// 优先用辅助功能取：`AXUIElementCopyElementAtPosition` 返回**视觉上最上层**的元素，
    /// 比 `CGWindowListCopyWindowInfo` 猜窗口层级准得多（实测后者会把滚动投给被遮挡的应用）。
    /// 取不到再退回窗口列表。
    static func windowPIDUnderMouse() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mouse = ScreenGeometry.cgPoint(
            fromNS: NSEvent.mouseLocation,
            primaryHeight: ScreenGeometry.primaryHeight
        )

        // ① 辅助功能：最准
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            system,
            Float(mouse.x),
            Float(mouse.y),
            &element
        ) == .success, let element {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid != ownPID {
                return pid
            }
        }

        // ② 退回窗口列表
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                pid != ownPID,
                let raw = info[kCGWindowBounds as String] as? [String: Any],
                let x = (raw["X"] as? NSNumber)?.doubleValue,
                let y = (raw["Y"] as? NSNumber)?.doubleValue,
                let w = (raw["Width"] as? NSNumber)?.doubleValue,
                let h = (raw["Height"] as? NSNumber)?.doubleValue
            else { continue }

            // 只要普通窗口层：放宽会命中输入法候选框、tooltip、各种浮层
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0, w >= 120, h >= 120 else { continue }

            if CGRect(x: x, y: y, width: w, height: h).contains(mouse) {
                return pid
            }
        }
        return nil
    }

    // MARK: - 辅助功能兜底滚动

    /// 用辅助功能直接让鼠标下的可滚动元素翻一页。
    ///
    /// 作为合成滚动事件的兜底：有些应用不接受合成事件，但 AX 动作一定能生效。
    /// 代价是滚多少不完全可控（按页/按行），所以只在注入无效时用。
    static func axScrollPage(at point: CGPoint, down: Bool) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            system,
            Float(point.x),
            Float(point.y),
            &element
        )
        guard result == .success, var target = element else {
            NSLog("[ShotTool] AX 按坐标取元素失败，错误码 \(result.rawValue)")
            return false
        }

        // 不同应用暴露的滚动动作名不一样，挨个试
        let actions = down
            ? ["AXScrollDownByPage", "AXScrollDown", "AXScrollDownByLine"]
            : ["AXScrollUpByPage", "AXScrollUp", "AXScrollUpByLine"]

        // 命中的往往是文字/图片，不是滚动容器，往上找
        for _ in 0..<8 {
            for action in actions where supports(target, action: action) {
                if AXUIElementPerformAction(target, action as CFString) == .success {
                    return true
                }
            }

            var parent: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(target, kAXParentAttribute as CFString, &parent) == .success,
                let value = parent,
                CFGetTypeID(value) == AXUIElementGetTypeID()
            else { break }
            target = unsafeDowncast(value, to: AXUIElement.self)
        }

        // 记下最终停在哪一层，便于排查（role 能看出是不是根本没进内容区）
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
        NSLog("[ShotTool] AX 找不到可滚动元素，最终 role=\(role as? String ?? "未知")")
        return false
    }

    private static func supports(_ element: AXUIElement, action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return false }
        return (names as? [String])?.contains(action) ?? false
    }

    // MARK: - 帧比较

    /// 两帧是否可视为相同（用来判定「滚不动了」）
    static func framesAreSame(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let ratio = diffRatio(a, b)
        return ratio < 0.001
    }

    private static func diffRatio(_ a: CGImage, _ b: CGImage) -> Double {
        guard let ga = grayscale(a), let gb = grayscale(b),
              ga.width == gb.width, ga.height == gb.height else { return 1 }

        let step = 8
        var changed = 0
        var total = 0
        let width = ga.width
        let height = ga.height

        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let index = y * width + x
                total += 1
                if abs(Int(ga.pixels[index]) - Int(gb.pixels[index])) > 12 {
                    changed += 1
                }
            }
        }
        return total == 0 ? 1 : Double(changed) / Double(total)
    }

    // MARK: - 拼接

    private struct Gray {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private static func grayscale(_ image: CGImage) -> Gray? {
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
        return Gray(pixels: buffer, width: width, height: height)
    }

    /// 找下半帧相对上半帧的重叠高度（像素）。找不到返回 nil。
    ///
    /// `expected` 是按滚动距离推算出来的重叠量。**有它的时候只在附近搜**——
    /// 聊天记录、列表这类页面有大量相似行，全范围搜索很容易在错误位置匹配上，
    /// 表现就是长图里内容重复、衔接错位（用户实测踩到的正是这个）。
    private static func findOverlap(
        upper: Gray,
        lower: Gray,
        maxSearch: Int,
        expected: Int? = nil,
        bandHeightOverride: Int? = nil
    ) -> Int? {
        guard upper.width == lower.width else { return nil }

        let width = upper.width
        let bandHeight = min(bandHeightOverride ?? 160, upper.height / 2)
        guard bandHeight > 8 else { return nil }

        let searchLimit = min(maxSearch, lower.height - bandHeight)
        guard searchLimit > 2 else { return nil }

        // 搜索区间：有先验就在期望值附近，没有才全范围
        var minOffset = 4
        var maxOffset = searchLimit
        if let expected {
            // expected 是「重叠高度」，offset 是模板在下面那张里的起始行，差一个模板高度。
            //
            // 有先验时只做**小幅微调**（±48px）：滚动量现在是遮罩记账的真实值，很准，
            // 匹配只用来修正惯性/加速带来的小误差。范围放太宽（试过 ±50%）会匹配到错位置，
            // 实测把重叠 314 拉到了 470，拼出来少 156px 内容。
            let expectedOffset = expected - bandHeight
            // 范围给到 ±1/3（至少 60px）：滚动量本身可能有误差，
            // 而且滚动量是跨设备算的（滚轮/触控板系数不完全一致），
            // 给窄了匹配不到，给宽了又容易误匹配。
            let margin = max(60, expected / 3)
            minOffset = max(4, expectedOffset - margin)
            maxOffset = min(searchLimit, expectedOffset + margin)
            guard maxOffset > minOffset else { return nil }
        }

        let step = 6
        let columns = Array(stride(from: 0, to: width, by: step))
        let bandTop = upper.height - bandHeight

        var bestOffset = -1
        var bestScore = Int.max

        for offset in minOffset...maxOffset {
            var score = 0
            var row = 0

            while row < bandHeight {
                let upperRow = (bandTop + row) * width
                let lowerRow = (offset + row) * width
                for column in columns {
                    score += abs(Int(upper.pixels[upperRow + column]) - Int(lower.pixels[lowerRow + column]))
                }
                if score > bestScore { break }   // 提前剪枝
                row += 1
            }

            if score < bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        // 平均每像素差要足够小。有先验时更严——宁可少拼一帧，也不要拼错位。
        let samples = bandHeight * columns.count
        let threshold = expected != nil ? 7 : 12
        guard samples > 0, bestScore / samples < threshold else { return nil }
        guard bestOffset >= 0 else { return nil }

        return min(bestOffset + bandHeight, upper.height)
    }

    /// 拼接。
    ///
    /// `plannedOverlaps` 是每段实际测到的重叠（由遮罩累计的真实滚动量算出），
    /// 图像匹配只在这个值 ±40px 内微调，**匹配不上也照拼**。
    /// 这是 iShot 的做法：它在 `scrollWheel:` 里累积 deltaY，按滚动量拼，从不依赖匹配成功。
    /// 归一化互相关（NCC）：用来验证候选重叠是否真的对齐了。
    ///
    /// 取值 [-1, 1]，越接近 1 越像。screen-stitch 的算法链里
    /// 「phase correlation + validate with overlap NCC」的后半句就是这一步。
    /// 作用是挡住相位相关在**周期性图案**上的误判 —— 重复卡片、表格行这类内容，
    /// 相位相关会在周期倍数处给出假峰值。
    private static func normalizedCrossCorrelation(upper: Gray, lower: Gray, overlap: Int) -> Float {
        guard overlap > 8, overlap < upper.height else { return -1 }
        let width = upper.width

        var sumU: Float = 0
        var sumL: Float = 0
        var sumUU: Float = 0
        var sumLL: Float = 0
        var sumUL: Float = 0
        var count: Float = 0

        let upperTop = upper.height - overlap
        for y in stride(from: 0, to: overlap, by: 2) {
            let uRow = (upperTop + y) * width
            let lRow = y * width
            for x in stride(from: 0, to: width, by: 4) {
                let u = Float(upper.pixels[uRow + x])
                let l = Float(lower.pixels[lRow + x])
                sumU += u
                sumL += l
                sumUU += u * u
                sumLL += l * l
                sumUL += u * l
                count += 1
            }
        }
        guard count > 0 else { return -1 }

        let meanU = sumU / count
        let meanL = sumL / count
        let cov = sumUL / count - meanU * meanL
        let varU = sumUU / count - meanU * meanU
        let varL = sumLL / count - meanL * meanL
        return cov / max(sqrt(varU * varL), 1e-6)
    }

    /// 多带投票匹配。
    ///
    /// 取三条不同高度的横带独立匹配，多数一致才接受。
    /// 聊天记录这类相似内容，单条带很容易匹配到错误位置；三条同时错的概率小得多。
    private static func findOverlapRobust(
        upper: Gray,
        lower: Gray,
        maxSearch: Int,
        expected: Int?
    ) -> Int? {
        let heights = [60, 110, 150]
        var votes: [Int] = []
        for height in heights {
            if let result = findOverlap(
                upper: upper,
                lower: lower,
                maxSearch: maxSearch,
                expected: expected,
                bandHeightOverride: height
            ) {
                votes.append(result)
            }
        }
        guard votes.count >= 2 else { return nil }
        votes.sort()
        return votes[votes.count / 2]
    }

    static func stitch(
        _ frames: [CGImage],
        plannedOverlaps: [Int]? = nil,
        expectedOverlap: Int? = nil
    ) -> CGImage? {
        stitchOnce(frames, plannedOverlaps: plannedOverlaps, expectedOverlap: expectedOverlap)
    }

    private static func stitchOnce(
        _ frames: [CGImage],
        plannedOverlaps: [Int]?,
        expectedOverlap: Int?
    ) -> CGImage? {
        guard let first = frames.first else { return nil }
        let width = first.width

        // 每帧相对上一帧的重叠高度
        // 上一段匹配出来的重叠。用户滚动速度是稳定的，
        // 所以某段匹配失败时，沿用上一段的结果远比「帧高一半」这种瞎猜靠谱。
        var previousOverlap: Int? = expectedOverlap
        var overlaps: [Int] = []
        for index in 1..<frames.count {
            guard let upper = grayscale(frames[index - 1]),
                  let lower = grayscale(frames[index]) else { return nil }

            // 搜索上限要覆盖「几乎整屏重叠」的情况。
            // 原来取 `帧高 * 3/4`，但用户小幅滚动时重叠可以到 94%（实测 986/1050），
            // 真实位置落在 836 行、而上限只有 787 —— **根本搜不到，必然匹配失败**。
            // 这就是「日志里 6 段未匹配上、结果整段重复」的直接原因。
            let maxSearch = max(60, upper.height - 20)
            // 这一段的目标重叠：优先用实测滚动量，其次用统一推算值。
            // -1 是「辅助功能翻页、滚动量未知」的标记，走全范围搜索。
            // 优先级：实测滚动量 > 上一段的重叠 > 理论值
            let hint: Int? = {
                if let plannedOverlaps, index - 1 < plannedOverlaps.count {
                    let value = plannedOverlaps[index - 1]
                    if value >= 0 { return value }
                }
                return previousOverlap
            }()

            // 匹配成功就用匹配值（修正小误差），匹配不上就用滚动量算出来的值（不中断拼接）；
            // 连滚动量都没有（AX 翻页）就取帧高一半当保守值，无论如何不在这里失败。
            var matched: Int? = nil

            // ① 相位相关优先（业界标准，参考 screen-stitch 的算法链）。
            //    它直接从像素算位移，不受滚动量单位换算影响；
            //    PSR + NCC 双重验证挡掉假峰值。
            if let shift = PhaseCorrelator.verticalShift(
                prevPixels: upper.pixels,
                nextPixels: lower.pixels,
                width: upper.width,
                height: min(upper.height, lower.height),
                maxShift: upper.height - 32
            ) {
                let candidate = upper.height - shift
                let score = normalizedCrossCorrelation(
                    upper: upper, lower: lower, overlap: candidate
                )
                if candidate > 24 && candidate < upper.height - 8 && score > 0.45 {
                    matched = candidate
                }
            }

            // ② 相位相关拿不到时，用实测滚动量做中心微调
            //    （滚动量可能因设备单位有偏差，所以只做参考不做主）
            if matched == nil, let hint, hint > 0 {
                matched = findOverlapRobust(
                    upper: upper,
                    lower: lower,
                    maxSearch: maxSearch,
                    expected: hint
                )
            }

            // ③ 都不行，退回无先验的模板匹配
            if matched == nil {
                matched = findOverlapRobust(
                    upper: upper,
                    lower: lower,
                    maxSearch: maxSearch,
                    expected: nil
                )
            }

            let fallback = lower.height / 2
            let rawOverlap = matched ?? hint ?? fallback

            // 一定要夹在合法区间内。否则某一段算出越界值（比如恰好等于帧高），
            // 后面的 `guard overlap < upper.height - 8` 会让**整个拼接**放弃，
            // 实测 8 帧时就是这样触发的（4 帧那次没问题）。
            let overlap = max(24, min(rawOverlap, upper.height - 24))
            if let matched {
                previousOverlap = matched
            } else {
                NSLog("[ShotTool] 第 \(index) 段未匹配上，沿用重叠 \(overlap)px")
            }
            // 重叠太大（说明几乎没滚动）或太小（说明漏了内容）都不可靠
            // 已 clamp 到 [24, upper.height-24]，这里不再让单段拖垮整体
            overlaps.append(overlap)
        }

        // 总高度
        var totalHeight = first.height
        for (index, frame) in frames.enumerated() where index > 0 {
            totalHeight += frame.height - overlaps[index - 1]
        }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 不翻转坐标系：CGImage 直接 draw 是正立的，
        // 第 i 帧「从顶部算的偏移」换算成左下原点的 y。
        var topOffset = 0
        for (index, frame) in frames.enumerated() {
            if index > 0 {
                topOffset += frames[index - 1].height - overlaps[index - 1]
            }
            let y = totalHeight - topOffset - frame.height
            ctx.draw(frame, in: CGRect(x: 0, y: y, width: width, height: frame.height))
        }

        return ctx.makeImage()
    }
}
