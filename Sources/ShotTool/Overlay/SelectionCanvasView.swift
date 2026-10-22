import AppKit

/// 一块屏的遮罩画布。自己用 CGContext 画，不用 SwiftUI ——
/// 覆盖窗对鼠标事件和重绘时机要求很高，自绘比声明式视图可控。
///
/// `isFlipped = true` 是刻意选的：翻转后视图坐标原点在左上，和 CG 全局坐标方向一致，
/// 屏内局部坐标 = 全局坐标 - 屏原点，一次减法就够了。
@MainActor
final class SelectionCanvasView: NSView {

    let screen: NSScreen
    var displayID: CGDirectDisplayID = 0
    /// 本屏在 CG 全局坐标下的左上角原点
    var displayOrigin: CGPoint = .zero
    weak var coordinator: OverlayCoordinator?

    private let dimAlpha: CGFloat = 0.35
    /// 上一次绘制算出的工具条布局，mouseDown 时拿来做命中检测
    private var toolbar: ToolbarLayout?

    private var textField: NSTextField?
    private var textPixelPoint: CGPoint?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 坐标

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: displayOrigin.x + local.x, y: displayOrigin.y + local.y)
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func selectionInView() -> CGRect? {
        guard let selection = coordinator?.session?.selection else { return nil }
        return selection.offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)
    }

    private var phase: CapturePhase {
        coordinator?.session?.phase ?? .selecting
    }

    // MARK: - 事件

    override func mouseDown(with event: NSEvent) {
        // 长截图模式：画布上的点击一律不处理。
        // 控制按钮是子视图，它自己收事件；画布要是照常走框选逻辑，
        // 用户随便点一下就会把长截图「重新框选」掉，表现就是「一进长截图就直接结束」。
        if coordinator?.session?.isLongShot == true { return }

        let local = localPoint(event)
        let global = globalPoint(event)

        // 工具条优先：它可能压在选区外
        if phase == .annotating, let toolbar, let hit = toolbar.hitTest(local) {
            coordinator?.handleToolbar(hit)
            return
        }

        switch phase {
        case .selecting:
            coordinator?.beginDrag(at: global)

        case .annotating:
            let consumed = coordinator?.beginAnnotation(at: global) ?? false
            // 文字工具：按下就弹输入框
            if consumed, let pending = coordinator?.pendingTextPoint {
                beginTextInput(at: local, pixelPoint: pending)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if coordinator?.session?.isLongShot == true { return }

        let global = globalPoint(event)
        switch phase {
        case .selecting:
            coordinator?.updateDrag(at: global)
        case .annotating:
            // 按住 Shift 从按下那一刻生效，拖到一半松开也能恢复自由比例
            coordinator?.updateAnnotation(
                at: global,
                constrainAspect: event.modifierFlags.contains(.shift)
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        if coordinator?.session?.isLongShot == true { return }

        switch phase {
        case .selecting:
            coordinator?.endDrag()
        case .annotating:
            coordinator?.endAnnotation()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.updateHover(at: globalPoint(event))
    }

    /// 长截图时滚动事件先到遮罩：记录滚动量，再转发给下面的页面。
    /// 这是 iShot 的做法（`-[MXClipView scrollWheel:]` 里累积 deltaY + `handleMouseEvent:` 转发），
    /// 好处是滚动量是**真实发生**的，不靠估算。
    override func scrollWheel(with event: NSEvent) {
        if coordinator?.session?.isLongShot == true {
            coordinator?.handleLongShotScroll(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // 长截图模式只认 Esc / 回车，其余按键不管
        if coordinator?.session?.isLongShot == true {
            switch Int(event.keyCode) {
            case 53:
                coordinator?.longShotController?.cancel()
            case 36, 76:
                coordinator?.longShotController?.finish()
            default:
                break
            }
            return
        }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1

        // ⌘Z / ⌘⇧Z
        if command {
            switch Int(event.keyCode) {
            case 6:   // z
                if shift {
                    coordinator?.annotations.redo()
                } else {
                    coordinator?.annotations.undo()
                }
                coordinator?.refresh()
                return
            case 51, 117:  // delete
                coordinator?.deleteSelectedAnnotation()
                return
            default:
                break
            }
        }

        switch Int(event.keyCode) {
        case 53:                    // Esc
            if textField != nil {
                cancelTextInput()
            } else if phase == .annotating {
                if coordinator?.annotations.selectedID != nil {
                    coordinator?.annotations.select(nil)
                    coordinator?.refresh()
                } else {
                    coordinator?.cancel()
                }
            } else {
                coordinator?.cancel()
            }

        case 36, 76:                // Return / Enter
            if phase == .annotating {
                coordinator?.finish(mode: shift ? .save : .copy)
            }

        case 51, 117:               // Delete
            coordinator?.deleteSelectedAnnotation()

        // 数字键切工具，右手不用离开鼠标
        case 18: coordinator?.setActiveTool(.rectangle)
        case 19: coordinator?.setActiveTool(.ellipse)
        case 20: coordinator?.setActiveTool(.arrow)
        case 21: coordinator?.setActiveTool(.text)

        case 123:                   // ←
            nudge(dx: -step, dy: 0, option: event.modifierFlags.contains(.option))
        case 124:                   // →
            nudge(dx: step, dy: 0, option: event.modifierFlags.contains(.option))
        case 125:                   // ↓
            nudge(dx: 0, dy: step, option: event.modifierFlags.contains(.option))
        case 126:                   // ↑
            nudge(dx: 0, dy: -step, option: event.modifierFlags.contains(.option))

        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat, option: Bool) {
        guard phase == .selecting else { return }
        coordinator?.nudgeSelection(dx: dx, dy: dy, resize: !option)
    }

    // MARK: - 文字输入

    private func beginTextInput(at local: CGPoint, pixelPoint: CGPoint) {
        cancelTextInput()

        let fieldHeight: CGFloat = 26
        let field = NSTextField(frame: NSRect(
            x: local.x - 4,
            y: local.y - fieldHeight / 2,
            width: 240,
            height: fieldHeight
        ))
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        field.textColor = .systemRed
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字，回车确认"
        field.target = self
        field.action = #selector(textFieldDidSubmit)
        field.delegate = self

        addSubview(field)
        window?.makeFirstResponder(field)

        textField = field
        textPixelPoint = pixelPoint
    }

    @objc private func textFieldDidSubmit() {
        commitTextInput()
    }

    private func commitTextInput() {
        guard let field = textField, let pixel = textPixelPoint else { return }
        let text = field.stringValue
        textField = nil
        textPixelPoint = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)

        coordinator?.commitText(text, at: pixel)
        needsDisplay = true
    }

    private func cancelTextInput() {
        guard let field = textField else { return }
        textField = nil
        textPixelPoint = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        coordinator?.clearPendingText()
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard
            let ctx = NSGraphicsContext.current?.cgContext,
            let coordinator,
            let session = coordinator.session
        else { return }

        let selection = selectionInView()

        // 长截图模式：不压暗（要让用户看着内容真实滚动），遮罩只留边框和控制按钮。
        // 对应 iShot 的 `window.setBackgroundColor(clearColor)` + 按钮 addSubview。
        if session.isLongShot {
            if let selection {
                drawLongShotFrame(ctx, selection: selection)
                drawLongShotHint(ctx, selection: selection)
            }
            toolbar = nil
            return
        }

        let hoverRect = session.hoverWindow?.bounds
            .offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y)

        drawDimming(ctx, selection: selection, hover: session.isDragging ? nil : hoverRect)

        if let selection, selection.width >= 1, selection.height >= 1 {
            drawSelection(ctx, selection: selection, session: session)
            drawSizeLabel(ctx, selection: selection)
        }

        switch session.phase {
        case .selecting:
            if let cursor = session.cursorGlobal, let frame = coordinator.frame(for: displayID) {
                let local = CGPoint(x: cursor.x - displayOrigin.x, y: cursor.y - displayOrigin.y)
                drawMagnifier(ctx, at: local, frame: frame)
            }
            toolbar = nil

        case .annotating:
            if let selection {
                drawAnnotations(ctx, selection: selection, session: session)
                drawToolbar(ctx, selection: selection)
            }
        }
    }

    /// 半透明压暗；选区（或悬停窗口）用 even-odd 规则挖空，露出原图。
    private func drawDimming(_ ctx: CGContext, selection: CGRect?, hover: CGRect?) {
        ctx.setFillColor(CGColor(gray: 0, alpha: dimAlpha))

        let hole: CGRect? = {
            if let selection, selection.width >= 2, selection.height >= 2 { return selection }
            if let hover, hover.width >= 2, hover.height >= 2 { return hover }
            return nil
        }()

        guard let hole else {
            ctx.fill(bounds)
            return
        }

        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(hole)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
    }

    private func drawSelection(_ ctx: CGContext, selection: CGRect, session: CaptureSession) {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1)
        ctx.stroke(selection.insetBy(dx: 0.5, dy: 0.5))

        if let hover = session.hoverWindow?.bounds
            .offsetBy(dx: -displayOrigin.x, dy: -displayOrigin.y),
           hover.intersects(bounds),
           session.phase == .selecting,
           !session.isDragging {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(hover.insetBy(dx: 1, dy: 1))
        }
    }

    private func drawSizeLabel(_ ctx: CGContext, selection: CGRect) {
        let scale = coordinator?.frame(for: displayID)?.scale ?? 1
        let width = Int((selection.width * scale).rounded())
        let height = Int((selection.height * scale).rounded())
        let text = "\(width) × \(height) px"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 8

        var origin = CGPoint(x: selection.minX, y: selection.maxY + padding)
        if origin.y + textSize.height > bounds.maxY - 4 {
            origin.y = selection.maxY - textSize.height - padding
        }
        origin.x = min(origin.x, bounds.maxX - textSize.width - padding * 2)
        origin.x = max(origin.x, bounds.minX + padding)

        let background = CGRect(
            x: origin.x - padding,
            y: origin.y - 4,
            width: textSize.width + padding * 2,
            height: textSize.height + 8
        )

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: background, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()

        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: - 长截图 UI

    private func drawLongShotFrame(_ ctx: CGContext, selection: CGRect) {
        // 双线：深色打底 + 浅色内描，白底黑底都看得见
        // （单根白线在白网页上几乎隐形）
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
        ctx.setLineWidth(3)
        ctx.stroke(selection.insetBy(dx: 1.5, dy: 1.5))

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1.5)
        ctx.stroke(selection.insetBy(dx: 0.75, dy: 0.75))
    }

    /// 长截图模式的提示条。
    /// 遮罩是穿透的（用户要能滚到下面的内容），所以**不能用可点击按钮**，只做展示；
    /// 完成靠回车，取消靠 Esc。
    private func drawLongShotHint(_ ctx: CGContext, selection: CGRect) {
        guard let text = coordinator?.longShotController?.statusText else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 10
        let barWidth = textSize.width + padding * 2
        let barHeight: CGFloat = 24

        // 默认放在选区上方外侧；顶部放不下就挪到下方
        var rect = CGRect(
            x: selection.maxX - barWidth,
            y: selection.minY - barHeight - 8,
            width: barWidth,
            height: barHeight
        )
        if rect.minY < 2 {
            rect.origin.y = selection.maxY + 8
        }

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.82))
        ctx.fillPath()

        (text as NSString).draw(
            at: CGPoint(x: rect.minX + padding, y: rect.minY + (barHeight - textSize.height) / 2),
            withAttributes: attributes
        )
    }

    // MARK: - 标注

    private func drawAnnotations(_ ctx: CGContext, selection: CGRect, session: CaptureSession) {
        let scale = coordinator?.scale ?? 1

        ctx.saveGState()
        // 标注不允许画出选区
        ctx.clip(to: selection)
        AnnotationRenderer.draw(
            coordinator?.annotations.items ?? [],
            in: ctx,
            origin: selection.origin,
            scale: scale,
            selectedID: coordinator?.annotations.selectedID
        )
        // 正在画的跟手预览
        if let draft = session.draft, draft.kind != .text {
            AnnotationRenderer.draw(
                [draft],
                in: ctx,
                origin: selection.origin,
                scale: scale
            )
        }
        ctx.restoreGState()
    }

    private func drawToolbar(_ ctx: CGContext, selection: CGRect) {
        guard let coordinator else { return }
        let layout = ToolbarLayout.compute(
            selection: selection,
            bounds: bounds,
            activeTool: coordinator.session?.activeTool,
            canUndo: coordinator.annotations.canUndo,
            canRedo: coordinator.annotations.canRedo,
            hasAnnotations: !coordinator.annotations.isEmpty
        )
        toolbar = layout
        layout.draw(in: ctx, activeTool: coordinator.session?.activeTool)
    }

    /// 放大镜：直接从冻结帧里裁一小块，用最近邻放大，看到的是真像素而不是插值。
    private func drawMagnifier(_ ctx: CGContext, at point: CGPoint, frame: DisplayFrame) {
        let size: CGFloat = 128
        let zoom: CGFloat = 4
        let gap: CGFloat = 24

        var origin = CGPoint(x: point.x + gap, y: point.y + gap)
        if origin.x + size > bounds.maxX { origin.x = point.x - gap - size }
        if origin.y + size > bounds.maxY { origin.y = point.y - gap - size }
        origin.x = max(4, min(origin.x, bounds.maxX - size - 4))
        origin.y = max(4, min(origin.y, bounds.maxY - size - 4))

        let rect = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.92))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()

        let inner = rect.insetBy(dx: 4, dy: 4)
        let sourceSize = inner.width / zoom

        let sourceRect = CGRect(
            x: (point.x - sourceSize / 2) * frame.scale,
            y: (point.y - sourceSize / 2) * frame.scale,
            width: sourceSize * frame.scale,
            height: sourceSize * frame.scale
        )

        let imageBounds = CGRect(
            x: 0, y: 0,
            width: frame.image.width,
            height: frame.image.height
        )
        let clamped = sourceRect.intersection(imageBounds)

        if !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
           let patch = frame.image.cropping(to: clamped.integral) {

            let ratio = inner.width / sourceRect.width
            let destination = CGRect(
                x: inner.minX + (clamped.minX - sourceRect.minX) * ratio,
                y: inner.minY + (clamped.minY - sourceRect.minY) * ratio,
                width: clamped.width * ratio,
                height: clamped.height * ratio
            )

            ctx.saveGState()
            ctx.clip(to: inner)
            // isFlipped 视图的 CTM 是翻过的，直接 draw 会上下颠倒，这里再翻回来
            ctx.translateBy(x: destination.minX, y: destination.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(
                patch,
                in: CGRect(x: 0, y: 0, width: destination.width, height: destination.height)
            )
            ctx.restoreGState()
        }

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        ))
        ctx.strokePath()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.95))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: center.x - 7, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + 7, y: center.y))
        ctx.move(to: CGPoint(x: center.x, y: center.y - 7))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + 7))
        ctx.strokePath()

        let px = Int((point.x * frame.scale).rounded())
        let py = Int((point.y * frame.scale).rounded())
        let label = "\(px), \(py)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.9)
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)

        var labelOrigin = CGPoint(x: rect.minX + 6, y: rect.maxY + 4)
        if labelOrigin.y + textSize.height > bounds.maxY {
            labelOrigin.y = rect.minY - textSize.height - 4
        }

        let background = CGRect(
            x: labelOrigin.x - 4,
            y: labelOrigin.y - 2,
            width: textSize.width + 8,
            height: textSize.height + 4
        )
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: background, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        (label as NSString).draw(at: labelOrigin, withAttributes: attributes)
    }
}

extension SelectionCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextInput()
            return true
        }
        return false
    }
}
