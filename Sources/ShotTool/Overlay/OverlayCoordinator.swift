import AppKit

enum CapturePhase {
    /// 正在框选区域
    case selecting
    /// 选区已定，正在标注
    case annotating
}

/// 出图的几种方式，行为必须区分开，否则按钮用起来一样。
enum FinishMode {
    /// 复制到剪贴板（隐式，不打断）
    case copy
    /// 弹保存面板让用户选位置
    case save
    /// 钉在屏幕上
    case pin
}

/// 一次截图会话的临时状态。
final class CaptureSession {
    var phase: CapturePhase = .selecting

    /// CG 全局坐标下的选区
    var selection: CGRect?
    /// 拖动起点
    var anchor: CGPoint?
    /// 起始屏（不做跨屏拼接，和系统截图行为一致：选区锁在起始屏内）
    var originScreenID: CGDirectDisplayID?
    var isDragging = false
    var hoverWindow: WindowInfo?
    var cursorGlobal: CGPoint?

    // MARK: - 标注态

    var activeTool: AnnotationKind? = .rectangle
    /// 长截图模式：遮罩保留但背景透明，只在上面放一个控制按钮
    ///
    /// 这个做法来自 REA 对 iShot 的反编译：`-[MXClipView scrollScreenShot]` 里
    /// `window.setBackgroundColor(clearColor)` + `[self addSubview:autoScrollScreenShotButton]`，
    /// 而不是关掉遮罩再新建窗口（新建的窗口在 LSUIElement 应用里不会上屏）。
    var isLongShot = false
    /// 正在画的标注（跟手预览用）
    var draft: Annotation?
    /// 正在拖动的已有标注
    var draggingAnnotationID: UUID?
    var dragOrigin: CGPoint = .zero
    var dragOriginal: Annotation?

    /// 全局 pt → 选区内像素坐标
    func pixel(from global: CGPoint, scale: CGFloat) -> CGPoint {
        guard let selection else { return .zero }
        return CGPoint(
            x: (global.x - selection.minX) * scale,
            y: (global.y - selection.minY) * scale
        )
    }
}

@MainActor
final class OverlayCoordinator {

    static let shared = OverlayCoordinator()

    private var windows: [OverlayWindow] = []
    private var canvases: [SelectionCanvasView] = []
    private var frames: [CGDirectDisplayID: DisplayFrame] = [:]
    private var windowList: [WindowInfo] = []

    private(set) var session: CaptureSession?
    private(set) var isActive = false
    private(set) var annotations = AnnotationStore()

    /// 长截图期间由它接管交互，结束后置空
    private(set) var longShotController: LongShotController?
    /// 长截图时轮询鼠标位置判断是否停在按钮上。
    ///
    /// 用轮询而不是 mouseMoved 事件：实测在遮罩这个 `.screenSaver` 层级的 borderless 窗口上，
    /// 鼠标停在**子视图按钮**上时 mouseMoved 拿不到（tracking area 和局部监听都失灵）。
    /// 轮询 60ms 一次，开销可以忽略，但不依赖任何事件分发。
    private var longShotHoverTimer: Timer?
    private var lastLongShotHover: Bool?
    private var outsideTicks = 0
    /// 长截图期间的全局滚动监听（遮罩穿透后靠它记账）
    private var globalScrollMonitor: Any?

    /// 结束回调：成功给出裁剪后的图，取消给 nil
    var onFinish: ((CGImage?) -> Void)?
    var onPermissionRequired: (() -> Void)?

    private var cursorPushed = false

    private init() {}

    func frame(for displayID: CGDirectDisplayID) -> DisplayFrame? {
        frames[displayID]
    }

    var scale: CGFloat {
        guard let id = session?.originScreenID, let frame = frames[id] else {
            return NSScreen.main?.pixelScale ?? 1
        }
        return frame.scale
    }

    // MARK: - 生命周期

    func begin() {
        guard !isActive else { return }
        guard ScreenCaptureService.hasPermission() else {
            onPermissionRequired?()
            return
        }

        Task { @MainActor in
            do {
                let started = Date()
                let contexts = ScreenGeometry.displayContexts()
                let captured = try await ScreenCaptureService.captureAllDisplays(contexts: contexts)
                NSLog("[ShotTool] 抓屏完成 \(captured.count) 屏，耗时 \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                self.frames = captured
                self.windowList = WindowEnumerator.onScreenWindows(
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )
                self.presentOverlays()
            } catch {
                self.frames = [:]
                self.report(error)
                self.onFinish?(nil)
            }
        }
    }

    private func presentOverlays() {
        session = CaptureSession()
        annotations = AnnotationStore()
        isActive = true

        let cursorCG = ScreenGeometry.cgPoint(
            fromNS: NSEvent.mouseLocation,
            primaryHeight: ScreenGeometry.primaryHeight
        )
        session?.cursorGlobal = cursorCG

        for screen in NSScreen.screens {
            guard frames[screen.displayID] != nil else { continue }

            let window = OverlayWindow(screen: screen)
            let canvas = SelectionCanvasView(screen: screen)
            canvas.displayID = screen.displayID
            canvas.displayOrigin = ScreenGeometry.cgOrigin(of: screen)
            canvas.coordinator = self
            window.contentView = canvas

            windows.append(window)
            canvases.append(canvas)
            window.orderFrontRegardless()
        }

        NSCursor.crosshair.push()
        cursorPushed = true

        let keyWindow = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        if let content = keyWindow?.contentView {
            keyWindow?.makeFirstResponder(content)
        }

        updateHover(at: cursorCG)
        refresh()
        NSLog("[ShotTool] 遮罩已显示 \(windows.count) 个窗口，屏数 \(NSScreen.screens.count)，帧数 \(frames.count)")
    }

    private func teardown() {
        guard isActive else { return }
        isActive = false
        session = nil
        removeGlobalScrollMonitor()

        for window in windows {
            window.ignoresMouseEvents = false
            (window.contentView as? SelectionCanvasView)?.setAccessibilityElement(true)
            window.orderOut(nil)
        }
        windows.removeAll()
        canvases.removeAll()
        frames.removeAll()
        windowList.removeAll()

        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }

    func refresh() {
        for canvas in canvases {
            canvas.needsDisplay = true
        }
    }

    // MARK: - 框选阶段

    func beginDrag(at global: CGPoint) {
        guard let session else { return }
        session.anchor = global
        session.selection = CGRect(origin: global, size: .zero)
        session.isDragging = true
        session.originScreenID = ScreenGeometry.screen(containing: global)?.displayID
        session.cursorGlobal = global
        refresh()
    }

    func updateDrag(at global: CGPoint) {
        guard let session, let anchor = session.anchor else { return }

        guard
            let screenID = session.originScreenID,
            let screen = NSScreen.screens.first(where: { $0.displayID == screenID })
        else { return }

        let bounds = ScreenGeometry.cgRect(of: screen)
        let snap: CGFloat = 8

        var x = min(max(global.x, bounds.minX), bounds.maxX)
        var y = min(max(global.y, bounds.minY), bounds.maxY)
        if abs(x - bounds.minX) <= snap { x = bounds.minX }
        if abs(x - bounds.maxX) <= snap { x = bounds.maxX }
        if abs(y - bounds.minY) <= snap { y = bounds.minY }
        if abs(y - bounds.maxY) <= snap { y = bounds.maxY }

        session.selection = CGRect(corner: anchor, corner: CGPoint(x: x, y: y))
        session.cursorGlobal = global
        refresh()
    }

    func endDrag() {
        guard let session else { return }
        session.isDragging = false

        // 框选够大 → 进入标注态，不再直接出图
        if let selection = session.selection, selection.width >= 3, selection.height >= 3 {
            session.phase = .annotating
            session.anchor = nil
            session.cursorGlobal = nil
            refresh()
            NSLog("[ShotTool] 选区已定 \(Int(selection.width))x\(Int(selection.height))pt，进入标注态")
            return
        }

        // 单击没拖动：落在哪个窗口上就以该窗口为选区
        if let hovered = session.hoverWindow {
            session.selection = hovered.bounds
            session.phase = .annotating
            session.originScreenID = ScreenGeometry.screen(
                containing: CGPoint(x: hovered.bounds.midX, y: hovered.bounds.midY)
            )?.displayID
            refresh()
            return
        }

        cancel()
    }

    func updateHover(at global: CGPoint) {
        guard let session else { return }
        session.cursorGlobal = global

        guard session.phase == .selecting, !session.isDragging else {
            refresh()
            return
        }

        session.hoverWindow = WindowEnumerator.topmostWindow(at: global, in: windowList)
        refresh()
    }

    // MARK: - 标注阶段

    /// 在标注态按下鼠标。返回 true 表示这次按下被标注逻辑消费了。
    @discardableResult
    func beginAnnotation(at global: CGPoint) -> Bool {
        guard let session, session.phase == .annotating, let selection = session.selection else {
            return false
        }
        let scale = self.scale
        let pixel = session.pixel(from: global, scale: scale)

        // 选区外不处理（工具条由画布单独判）
        guard selection.contains(global) else { return false }

        // 1. 先判断是否点中已有标注 → 选中并可拖动
        let tolerance = 6 * scale
        if let hitID = annotations.hitTest(pixel, tolerance: tolerance),
           let original = annotations.items.first(where: { $0.id == hitID }) {
            annotations.select(hitID)
            session.draggingAnnotationID = hitID
            session.dragOrigin = pixel
            session.dragOriginal = original
            annotations.beginInteraction()
            refresh()
            return true
        }

        // 2. 没点中 → 取消选中，用当前工具画新的
        guard let tool = session.activeTool else {
            annotations.select(nil)
            refresh()
            return true
        }

        if tool == .text {
            // 文字位置交给画布上的输入框
            session.draft = Annotation(kind: .text, start: pixel, end: pixel, text: nil)
            refresh()
            return true
        }

        session.draft = Annotation(
            kind: tool,
            start: pixel,
            end: pixel,
            style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 28)
        )
        refresh()
        return true
    }

    func updateAnnotation(at global: CGPoint, constrainAspect: Bool = false) {
        guard let session, session.phase == .annotating else { return }
        let scale = self.scale

        if session.draggingAnnotationID != nil {
            guard let original = session.dragOriginal else { return }
            let pixel = session.pixel(from: global, scale: scale)
            var moved = original
            moved.translate(
                dx: pixel.x - session.dragOrigin.x,
                dy: pixel.y - session.dragOrigin.y
            )
            annotations.replace(moved)
            session.dragOriginal = moved
            session.dragOrigin = pixel
            refresh()
            return
        }

        guard var draft = session.draft else { return }
        var end = session.pixel(from: global, scale: scale)

        // 按住 Shift：矩形出正方形、椭圆出正圆。
        // 长边取绝对值最大的那一维，并保留原来的拖动方向（往左上拖也是正方形）。
        if constrainAspect, draft.kind == .rectangle || draft.kind == .ellipse {
            end = squareCorner(from: draft.start, to: end)
        }

        draft.end = end
        session.draft = draft
        refresh()
    }

    private func squareCorner(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let size = max(abs(dx), abs(dy))
        return CGPoint(
            x: start.x + (dx < 0 ? -size : size),
            y: start.y + (dy < 0 ? -size : size)
        )
    }

    func endAnnotation() {
        guard let session else { return }

        if session.draggingAnnotationID != nil {
            session.draggingAnnotationID = nil
            session.dragOriginal = nil
            refresh()
            return
        }

        guard let draft = session.draft else { return }

        if draft.kind == .text {
            // 文字：保留 draft 等画布弹输入框，endAnnotation 不清
            return
        }

        session.draft = nil

        // 太小的拖拽视为误触，不生成标注
        let box = draft.boundingBox
        if box.width < 4 && box.height < 4 {
            refresh()
            return
        }

        annotations.add(draft)
        refresh()
    }

    var pendingTextPoint: CGPoint? {
        guard let draft = session?.draft, draft.kind == .text else { return nil }
        return draft.start
    }

    /// 画布上的文字输入框提交后回填
    func commitText(_ text: String, at pixelPoint: CGPoint) {
        session?.draft = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            refresh()
            return
        }
        annotations.add(Annotation(
            kind: .text,
            start: pixelPoint,
            end: pixelPoint,
            text: trimmed,
            style: AnnotationStyle(color: .systemRed, lineWidth: 4, fontSize: 28)
        ))
        refresh()
    }

    func clearPendingText() {
        session?.draft = nil
        refresh()
    }

    func setActiveTool(_ tool: AnnotationKind?) {
        session?.activeTool = tool
        refresh()
    }

    // MARK: - 工具条

    func handleToolbar(_ id: ToolbarID) {
        switch id {
        case .tool(let kind):
            session?.activeTool = (session?.activeTool == kind) ? nil : kind
        case .undo:
            annotations.undo()
        case .redo:
            annotations.redo()
        case .copy:
            finish(mode: .copy)
            return
        case .save:
            finish(mode: .save)
            return
        case .pin:
            finish(mode: .pin)
            return
        case .longShot:
            startLongShot()
            return
        case .close:
            cancel()
            return
        }
        refresh()
    }

    // MARK: - 长截图

    func startLongShot() {
        guard let session, let selection = session.selection else { return }
        let pixelScale = scale

        guard LongShotService.hasAccessibility() else {
            teardown()
            promptAccessibility()
            onFinish?(nil)
            return
        }

        // 关键：不 teardown。
        // iShot 的做法是保留遮罩视图、把窗口背景设透明，然后把按钮 addSubview 到遮罩上。
        // 新建窗口在「应用没有任何自己的窗口」的状态下不会上屏，这条弯路已经走过。
        session.isLongShot = true
        NSLog("[ShotTool] 长截图模式，选区 \(Int(selection.width))x\(Int(selection.height))pt")

        let controller = LongShotController(selection: selection, scale: pixelScale)
        controller.onChange = { [weak self] in
            self?.refresh()
        }
        controller.onFinish = { [weak self] image in
            guard let self else { return }
            self.longShotController = nil
            self.teardown()
            if let image {
                ImageOutput.copyToPasteboard(image)
                NSSound(named: "Glass")?.play()
                NSLog("[ShotTool] 长截图完成 \(image.width)x\(image.height)")
            }
            self.onFinish?(nil)
        }
        longShotController = controller
        // 长截图要靠鼠标悬停驱动，应用必须是激活状态才收得到 mouseMoved
        NSApp.activate(ignoringOtherApps: true)

        // 让遮罩对辅助功能"透明"。
        // 遮罩是全屏、`.screenSaver` 层级，`AXUIElementCopyElementAtPosition` 按坐标查到的
        // 最上层元素永远是它自己 —— 一个不可滚的视图，所以兜底翻页必然报
        // 「鼠标下没有可滚动元素」。关掉它的辅助功能可见性才能查到下面的真实元素。
        for window in windows {
            (window.contentView as? SelectionCanvasView)?.setAccessibilityElement(false)
        }

        // ★ 方案 B 的核心：遮罩穿透。
        // 滚动完全交给用户自己滚，事件走真实路径直达下面的应用 ——
        // 这是唯一能保证在任何应用（包括钉钉这类 Electron 应用）上滚动的做法。
        // 我们不注入任何滚动事件，只用全局监听记录「滚了多少」，用来算拼接重叠。
        setOverlayWindowsIgnoreMouse(true)
        installGlobalScrollMonitor()

        controller.start()
        refresh()
    }

    // MARK: - 长截图滚动（照 iShot 的做法）

    /// 遮罩收到滚动事件：先记账，再转发给下面的页面。
    ///
    /// `-[MXClipView scrollWheel:]` 就是这套：`DAT_1001dde20 += deltaY` 记累积量，
    /// 最后 `[handler handleMouseEvent:event]` 转发。这样拿到的滚动量是**真实发生**的，
    /// 而不是「我注入了多少」——系统加速、页面到边界都能反映出来。
    func handleLongShotScroll(_ event: NSEvent) {
        guard session?.isLongShot == true, let controller = longShotController else { return }

        // 单位：注入的是 `units: .pixel` 事件，实测 `scrollingDeltaY` 就是注入的像素值（1:1），
        // 不能再乘 scale（乘了就翻倍，实测 1612px 超过整帧高度）。
        // 注意 `hasPreciseScrollingDeltas` 对这个事件返回 true，不能用它区分单位。
        let delta = event.scrollingDeltaY
        controller.addScrollPixels(delta)
        NSLog("[ShotTool] 记账 delta=\(Int(delta))")

        // 转发给下面的窗口。
        //
        // 不要用「临时穿透 + cg.post」：那条路走不通。穿透要等下一个 runloop 周期才生效，
        // 而 post 是立即投递的，事件会再次落回遮罩、被防回环标志吞掉 —— 页面根本不滚。
        // （这就是日志里「帧数 0、状态 bottom」的原因）
        // 直接投递给鼠标下的进程最稳。
        guard let cg = event.cgEvent else { return }
        if let pid = windowPIDUnderMouse() {
            cg.postToPid(pid)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "未知"
            NSLog("[ShotTool] 滚动已转发给 \(name)（pid \(pid)）")
        } else {
            NSLog("[ShotTool] 找不到鼠标下的目标窗口，滚动没有转发")
        }
    }

    /// 鼠标下面最上层的外部窗口进程
    private func windowPIDUnderMouse() -> pid_t? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let mouse = ScreenGeometry.cgPoint(
            fromNS: NSEvent.mouseLocation,
            primaryHeight: ScreenGeometry.primaryHeight
        )

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

            // 只要普通窗口层。不放宽这个条件会经常命中输入法候选框、tooltip、
            // 各种浮层（layer != 0），把滚动投给它们等于没滚。
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            // 太小的窗口（图标、状态项）不可能是滚动目标
            guard w >= 120, h >= 120 else { continue }

            if CGRect(x: x, y: y, width: w, height: h).contains(mouse) {
                return pid
            }
        }
        return nil
    }

    /// 长截图期间让遮罩不接收鼠标事件：
    /// 轮询用的是全局鼠标位置，不需要遮罩收事件；而滚动事件必须能落到下面的页面。
    private func setOverlayWindowsIgnoreMouse(_ ignore: Bool) {
        for window in windows {
            window.ignoresMouseEvents = ignore
        }
    }

    /// 全局滚动监听：遮罩穿透后收不到 scrollWheel，改用全局监听记账。
    /// 这对应 iShot 的 `CGEventTapCreate`。
    private func installGlobalScrollMonitor() {
        removeGlobalScrollMonitor()
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, let controller = self.longShotController else { return }

            // 单位换算，这里是重复内容的根源：
            // - 触控板/妙控鼠标（hasPreciseScrollingDeltas）：delta 是**点**
            // - 传统滚轮：delta 是**行**，一行约 10pt
            // 而重叠量是按**像素**算的，@2x 屏 1pt = 2px。
            // 之前按 1:1 记账，重叠被算小一半，多出来的部分就是「同一段内容重复」。
            // 单位：触控板/妙控鼠标（precise）给的是**点**，滚轮给的是**行**。
            // 而重叠按像素算，@2x 屏 1pt = 2px —— 不换算就是重叠算大一倍，
            // 多出来的部分就是重复内容（实测拼 8 帧高度 2155，实际该 2600+）。
            let points: CGFloat = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 10
            controller.addScrollPixels(points * self.scale)
        }
    }

    private func removeGlobalScrollMonitor() {
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
    }

    private func promptAccessibility() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "长截图需要「辅助功能」权限"
        alert.informativeText = """
        这个权限只用来模拟滚轮事件做自动滚动，不会读取你敲了什么键。

        请点「打开系统设置」，在「隐私与安全性 → 辅助功能」里勾选 ShotTool，然后重新截一次。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            LongShotService.requestAccessibility()
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 键盘

    func nudgeSelection(dx: CGFloat, dy: CGFloat, resize: Bool) {
        guard let session, var selection = session.selection else { return }
        if resize {
            selection.size.width = max(1, selection.width + dx)
            selection.size.height = max(1, selection.height + dy)
        } else {
            selection.origin.x += dx
            selection.origin.y += dy
        }
        session.selection = selection
        refresh()
    }

    func deleteSelectedAnnotation() {
        annotations.removeSelected()
        refresh()
    }

    func cancel() {
        teardown()
        onFinish?(nil)
    }

    /// 出图。标注在导出时合成，不靠截屏（否则会把遮罩和工具条拍进去）。
    func finish(mode: FinishMode) {
        guard let session, let selection = session.selection,
              selection.width >= 1, selection.height >= 1
        else {
            cancel()
            return
        }

        guard var image = crop(selection) else {
            cancel()
            return
        }

        if !annotations.isEmpty {
            image = AnnotationRenderer.composite(
                base: image,
                annotations: annotations.items,
                scale: 1   // 标注坐标本身是选区内像素，一比一合成
            )
        }

        // teardown 会清掉 session，所以这些值必须先取出来
        let pixelScale = scale
        let selectionOrigin = selection.origin

        // 先收遮罩再弹面板 / 贴图，否则会被覆盖层盖住
        teardown()

        switch mode {
        case .copy:
            onFinish?(image)

        case .save:
            let saved = ImageOutput.saveWithPanel(image)
            if saved != nil {
                NSSound(named: "Glass")?.play()
            }
            // 传 nil 表示「不需要再复制」，和取消共用同一个回调
            onFinish?(nil)

        case .pin:
            PinManager.shared.pin(image, at: selectionOrigin, pixelScale: pixelScale)
            NSSound(named: "Pop")?.play()
            onFinish?(nil)
        }
    }

    // MARK: - 出图基础

    private func crop(_ globalRect: CGRect) -> CGImage? {
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)

        let screen = NSScreen.screens.first {
            ScreenGeometry.cgRect(of: $0).contains(center)
        } ?? NSScreen.screens.first {
            ScreenGeometry.cgRect(of: $0).intersects(globalRect)
        }

        guard let screen, let frame = frames[screen.displayID] else { return nil }

        let local = globalRect.offsetBy(dx: -frame.cgRect.minX, dy: -frame.cgRect.minY)

        let pixelRect = CGRect(
            x: (local.minX * frame.scale).rounded(),
            y: (local.minY * frame.scale).rounded(),
            width: (local.width * frame.scale).rounded(),
            height: (local.height * frame.scale).rounded()
        )

        let imageBounds = CGRect(
            x: 0, y: 0,
            width: frame.image.width,
            height: frame.image.height
        )
        let safe = pixelRect.intersection(imageBounds)
        guard !safe.isNull, safe.width >= 1, safe.height >= 1 else { return nil }

        return frame.image.cropping(to: safe.integral)
    }

    // MARK: - 自测入口

    func demoSelection(_ rect: CGRect) {
        guard isActive, let session else { return }
        session.selection = rect
        session.isDragging = false
        session.hoverWindow = nil
        session.phase = .annotating
        // 自测路径也要定起始屏，否则 scale 会退化成 1，长截图的重叠量会算错
        session.originScreenID = ScreenGeometry.screen(
            containing: CGPoint(x: rect.midX, y: rect.midY)
        )?.displayID
        refresh()
    }

    /// 摆几条示例标注，验证渲染与合成
    func demoAnnotations() {
        guard isActive, let selection = session?.selection else { return }
        let w = selection.width * scale
        let h = selection.height * scale

        annotations.add(Annotation(
            kind: .rectangle,
            start: CGPoint(x: w * 0.06, y: h * 0.10),
            end: CGPoint(x: w * 0.42, y: h * 0.34)
        ))
        annotations.add(Annotation(
            kind: .arrow,
            start: CGPoint(x: w * 0.46, y: h * 0.52),
            end: CGPoint(x: w * 0.74, y: h * 0.22)
        ))
        annotations.add(Annotation(
            kind: .ellipse,
            start: CGPoint(x: w * 0.52, y: h * 0.60),
            end: CGPoint(x: w * 0.86, y: h * 0.84)
        ))
        annotations.add(Annotation(
            kind: .text,
            start: CGPoint(x: w * 0.06, y: h * 0.40),
            end: CGPoint(x: w * 0.06, y: h * 0.40),
            text: "这里文案要改"
        ))
        annotations.select(nil)
        refresh()
    }

    // MARK: - 提示

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
