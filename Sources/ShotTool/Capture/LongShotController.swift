import AppKit

/// 长截图控制器（半自动模式）。
///
/// **由用户自己滚鼠标**，我们只负责抓帧和拼接。
///
/// 为什么不用自动滚：Electron 类应用（钉钉、飞书、VS Code）会丢弃合成的滚动事件，
/// 实测同一个程序在 Safari 上能滚、在钉钉上完全没反应。而用户自己滚产生的是**真实事件**，
/// 任何应用都无法拒绝。这是唯一 100% 可靠的路径。
///
/// 交互：框选 → 在选区里滚鼠标 → 每次滚动停下后自动抓一段 → 滚完按回车出图，Esc 取消。
@MainActor
final class LongShotController {

    private let selection: CGRect
    private let scale: CGFloat

    /// 第一帧（进入时就已经在视野里的部分）
    private var initialFrame: CGImage?
    /// 之后每次滚动停下抓到的一帧
    private var frames: [CGImage] = []
    /// 每帧相对上一帧的重叠（像素）；-1 表示滚动量不可信，交给图像搜索
    private var plannedOverlaps: [Int] = []
    /// 自上次抓帧以来累积的滚动量（像素）
    private var pendingScroll: CGFloat = 0

    /// 滚动停下多久算「停稳」。太短会抓到惯性中的画面，太长用户觉得卡。
    private let settleDelay: TimeInterval = 0.35

    private var settleTask: Task<Void, Never>?
    private var isFinishing = false
    /// 上一次抓帧的时刻，用来节流
    private var lastCaptureAt: TimeInterval = 0
    /// 抓帧最小间隔。抓一帧本身要 80ms 左右，设太小会排队。
    private let minCaptureInterval: TimeInterval = 0.15
    /// 同一时刻只允许一个抓帧任务，否则连续滚动时帧序会乱
    private var isCapturing = false

    var onChange: (() -> Void)?
    var onFinish: ((CGImage?) -> Void)?

    var frameCount: Int { frames.count }

    var statusText: String {
        if frames.isEmpty {
            return "在选区里慢慢滚动 · 每停一下记一屏 · 滚完按回车"
        }
        return "已拼 \(frames.count + (initialFrame == nil ? 0 : 1)) 屏 · 滚完按回车"
    }

    init(selection: CGRect, scale: CGFloat) {
        self.selection = selection
        self.scale = scale
    }

    // MARK: - 生命周期

    func start() {
        guard LongShotService.hasAccessibility() else {
            promptAccessibility()
            onFinish?(nil)
            return
        }

        // 先抓当前视野作为第一帧
        Task { @MainActor in
            initialFrame = try? await LongShotService.captureRegion(selection: selection, scale: scale)
            onChange?()
        }
    }

    /// 全局滚动监听喂进来，单位已是像素
    func addScrollPixels(_ pixels: CGFloat) {
        guard !isFinishing else { return }
        pendingScroll += pixels

        // ★ 滚动**过程中**就持续抓，不能等停下。
        // 之前是「每次滚动都重置防抖计时器」，用户一口气滚到底时中间一次都没抓，
        // 只抓到最后一帧 —— 实测就是这样丢了聊天记录中间整整一大段。
        // 两个条件任一满足就抓：
        // ① 距上次抓帧够久了（时间节流）
        // ② 累积滚动量已经超过一屏的 40%（量节流）—— 快速滚动时单靠时间会漏，
        //    因为抓一帧本身要 80ms，这段时间用户又滚出去了
        let now = Date().timeIntervalSince1970
        let frameHeightPx = selection.height * scale
        if now - lastCaptureAt >= minCaptureInterval
            || abs(pendingScroll) > frameHeightPx * 0.4 {
            lastCaptureAt = now
            triggerCapture()
        }

        // 停下后再补一帧，抓住最后落定的画面
        scheduleSettle()
    }

    private func triggerCapture() {
        guard !isCapturing, !isFinishing else { return }
        isCapturing = true
        Task { @MainActor in
            await captureOnce()
            isCapturing = false
        }
    }

    /// 每次滚动都重置防抖计时；停下 settleDelay 后才真正抓帧
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled, !isFinishing else { return }
            triggerCapture()
        }
    }

    private func captureOnce() async {
        guard !isFinishing else { return }
        guard let frame = try? await LongShotService.captureRegion(
            selection: selection,
            scale: scale
        ) else { return }

        // 和上一帧一样说明没真滚（或滚回去了），不记。
        // 注意**不要**清零 pendingScroll：这段滚动还没被用掉，留到下一次一起算。
        let previous = frames.last ?? initialFrame
        if let previous, LongShotService.framesAreSame(previous, frame) {
            return
        }

        let frameHeightPx = CGFloat(frame.height)
        let scrolledPx = abs(pendingScroll)

        // 滚动太少不记，继续累积。
        // 否则会抓出大量重叠 95% 的冗余帧（实测 25 段里一堆「滚动 0px/2px」），
        // 既拖慢拼接，又让匹配因为「几乎全重叠、没有唯一性」而变难。
        // 累积到一屏的 15% 再记，每段都有实质新内容。
        guard scrolledPx >= frameHeightPx * 0.15 else { return }
        pendingScroll = 0

        // 滚动量合理（没超出一屏）就用它算重叠，否则标 -1 交给图像搜索
        let plausible = scrolledPx > 20 && scrolledPx < frameHeightPx * 0.95
        let overlap = plausible
            ? max(24, Int((frameHeightPx - scrolledPx).rounded()))
            : -1

        plannedOverlaps.append(overlap)
        frames.append(frame)
        NSLog("[ShotTool] 抓第 \(frames.count) 段：滚动 \(Int(scrolledPx))px\(plausible ? "" : "（不可信）")，重叠 \(overlap)")
        onChange?()
    }

    // MARK: - 结束

    func finish() {
        NSLog("[ShotTool] 长截图 finish：段数 \(frames.count)")
        guard !isFinishing else { return }
        isFinishing = true
        settleTask?.cancel()
        settleTask = nil

        var all: [CGImage] = []
        if let initialFrame { all.append(initialFrame) }
        all.append(contentsOf: frames)

        guard all.count > 1 else {
            onFinish?(nil)
            reportNoScroll()
            return
        }

        let expectedOverlap = all[0].height * 28 / 100
        guard let stitched = LongShotService.stitch(
            all,
            plannedOverlaps: plannedOverlaps,
            expectedOverlap: expectedOverlap
        ) else {
            onFinish?(nil)
            reportStitchFailure(frameCount: all.count)
            return
        }

        NSLog("[ShotTool] 拼接 \(all.count) 帧 → \(stitched.width)x\(stitched.height)")
        onFinish?(stitched)
    }

    func cancel() {
        NSLog("[ShotTool] 长截图 cancel")
        guard !isFinishing else { return }
        isFinishing = true
        settleTask?.cancel()
        settleTask = nil
        onFinish?(nil)
    }

    // MARK: - 提示

    private func reportNoScroll() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "没有检测到滚动"
        alert.informativeText = """
        在选区里滚动鼠标滚轮，每停一次会自动记录一段，滚完按回车出图。

        如果没有反应，请确认鼠标在选区内、且这块内容本身可以滚动。
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func reportStitchFailure(frameCount: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        NSLog("[ShotTool] 拼接失败：\(frameCount) 帧，stitch 返回 nil")
        alert.messageText = "拼接失败"
        alert.informativeText = """
        抓到 \(frameCount) 段，但相邻两段找不到可靠的重叠位置。

        可能是滚动时画面在变（加载、弹窗、动画）。慢一点滚、每滚一下停一下，成功率会高很多。
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func promptAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "长截图需要「辅助功能」权限"
        alert.informativeText = """
        这个权限用来监听你的滚动动作，不会读取你敲了什么键。

        请在「系统设置 → 隐私与安全性 → 辅助功能」里勾选 ShotTool，然后重新截一次。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            LongShotService.requestAccessibility()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
