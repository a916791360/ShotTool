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

    /// 长截图新引擎及交互悬浮条
    private var longCaptureService: LongCaptureService?
    private var longShotHUDController: LongShotHUDController?
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
        longShotHUDController?.close()
        longShotHUDController = nil
        longCaptureService?.cancel()
        longCaptureService = nil
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

        // 1. 查找选区中心所在的屏幕与 displayID
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let screen = ScreenGeometry.screen(containing: center) ?? NSScreen.main ?? NSScreen.screens[0]
        let displayID = screen.displayID

        // 2. 获取该屏幕初始的截屏图像作为首屏 fallback
        guard let displayFrame = frames[displayID] else {
            NSLog("[ShotTool] 无法获取显示器 \(displayID) 的首屏帧")
            cancel()
            return
        }

        // 3. 计算选区在当前显示器局部的 CG 坐标（左上角原点）
        let screenRect = ScreenGeometry.cgRect(of: screen)
        let localSelection = CGRect(
            x: selection.minX - screenRect.minX,
            y: selection.minY - screenRect.minY,
            width: selection.width,
            height: selection.height
        )

        // 4. 构建首屏快照模型
        let snapshot = ScreenSnapshot(
            screen: screen,
            displayID: displayID,
            image: displayFrame.image
        )

        // 5. 排除自身遮罩窗口
        let excludedIDs = windows.map { CGWindowID($0.windowNumber) }

        // 6. 初始化 LongCaptureService (来自 LongCaptureEngine)
        let service = LongCaptureService(
            snapshot: snapshot,
            selection: localSelection,
            excludedWindowIDs: excludedIDs
        )
        self.longCaptureService = service

        // 7. 标记状态并设置遮罩穿透
        session.isLongShot = true
        setOverlayWindowsIgnoreMouse(true)
        refresh()

        // 8. 创建并展示交互悬浮条
        let hud = LongShotHUDController()
        hud.onFinish = { [weak self] in
            self?.finishLongShot()
        }
        hud.onCancel = { [weak self] in
            self?.cancelLongShot()
        }

        service.onStatus = { [weak hud] text, isError in
            DispatchQueue.main.async {
                if !isError {
                    hud?.updateStatus(screenCount: 1, heightPx: 0)
                }
            }
        }

        service.onPreviewSegment = { [weak hud] segment, frameCount in
            DispatchQueue.main.async {
                hud?.updateStatus(screenCount: frameCount, heightPx: segment.previewTop + segment.previewHeight)
            }
        }

        hud.show(near: selection, on: screen)
        self.longShotHUDController = hud

        // 9. 启动 60fps 流采集，并主动释放应用激活状态，让下层窗口即刻获得滚动焦点
        installGlobalScrollMonitor()
        service.start()
        NSApp.deactivate()
        NSLog("[ShotTool] 60fps 长截图引擎已启动，选区: \(Int(selection.width))x\(Int(selection.height))")
    }

    func finishLongShot() {
        removeGlobalScrollMonitor()
        guard let longCaptureService else { return }
        longShotHUDController?.showFinishing()
        longCaptureService.finish { [weak self] result in
            guard let self else { return }
            self.longShotHUDController?.close()
            self.longShotHUDController = nil
            self.longCaptureService = nil
            self.teardown()

            switch result {
            case .success(let image):
                ImageOutput.copyToPasteboard(image)
                NSSound(named: "Glass")?.play()
                NSLog("[ShotTool] 长截图完成，尺寸: \(image.width)x\(image.height)")
            case .failure(let error):
                NSLog("[ShotTool] 长截图失败: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "长截图未成功"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
            self.onFinish?(nil)
        }
    }

    func cancelLongShot() {
        removeGlobalScrollMonitor()
        longCaptureService?.cancel()
        longCaptureService = nil
        longShotHUDController?.close()
        longShotHUDController = nil
        cancel()
    }

    /// 长截图期间让遮罩不接收鼠标事件：滚动事件直达下面的页面
    private func setOverlayWindowsIgnoreMouse(_ ignore: Bool) {
        for window in windows {
            window.ignoresMouseEvents = ignore
        }
    }

    private func installGlobalScrollMonitor() {
        removeGlobalScrollMonitor()
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            guard let self, self.session?.isLongShot == true else { return }
        }
    }

    private func removeGlobalScrollMonitor() {
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
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
        longShotHUDController?.close()
        longShotHUDController = nil
        longCaptureService?.cancel()
        longCaptureService = nil
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
