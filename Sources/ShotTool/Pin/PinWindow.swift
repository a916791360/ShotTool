import AppKit

/// 贴图窗口（钉在屏幕上的图）。
///
/// 关键在 `.nonactivatingPanel` + `canBecomeKey = false`：
/// 贴图必须**不抢焦点**，否则贴出图的瞬间原来的输入框就失焦、下拉菜单会收起。
/// 这是贴图工具最容易忽略、也最影响手感的一点。
@MainActor
final class PinWindow: NSPanel {

    private(set) var pinnedImage: CGImage
    private let pinView: PinContentView
    /// 图片像素 → 屏幕 pt 的换算倍率
    let pixelScale: CGFloat

    init(image: CGImage, at origin: CGPoint, pixelScale: CGFloat) {
        self.pinnedImage = image
        self.pixelScale = pixelScale

        let size = CGSize(
            width: CGFloat(image.width) / pixelScale,
            height: CGFloat(image.height) / pixelScale
        )

        let view = PinContentView(frame: CGRect(origin: .zero, size: size))
        self.pinView = view

        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // 需要 mouseMoved 才能做顶栏的按钮悬停反馈
        acceptsMouseMovedEvents = true
        // 不能出现在截图里，否则会「自己截自己」
        sharingType = .none

        view.image = image
        view.host = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 贴图窗口的内容视图：画图 + 拖动 + 缩放 + 右键菜单。
@MainActor
final class PinContentView: NSView {

    var image: CGImage?
    weak var host: PinWindow?

    private var dragMouseOrigin: NSPoint = .zero
    private var dragWindowOrigin: NSPoint = .zero
    private var isDragging = false

    // 顶部操作栏：鼠标移进来才出现，移开淡出——不占位置，也不挡图
    private let barHeight: CGFloat = 26
    private var isHovering = false
    private var hoveredButton: Int?
    private enum BarButton: Int, CaseIterable {
        case copy, save, opacity, close
    }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredButton = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = isHovering ? button(at: point)?.rawValue : nil
        if newHover != hoveredButton {
            hoveredButton = newHover
            needsDisplay = true
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.001))
        ctx.fill(bounds)

        ctx.saveGState()
        // flipped 视图里画 CGImage 会上下颠倒，先翻回来
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        // 细边框，压在白底截图上也能看出边界
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))

        drawBar(ctx)
    }

    // MARK: - 顶部操作栏

    private func barButtons() -> [(BarButton, CGRect)] {
        let size: CGFloat = 22
        let gap: CGFloat = 2
        let rightPadding: CGFloat = 6

        var result: [(BarButton, CGRect)] = []
        for (index, button) in BarButton.allCases.reversed().enumerated() {
            let x = bounds.maxX - rightPadding - CGFloat(index + 1) * size - CGFloat(index) * gap
            result.append((button, CGRect(x: x, y: 2, width: size, height: size)))
        }
        return result
    }

    private func barLabel(_ button: BarButton) -> (text: String, size: CGFloat) {
        switch button {
        case .copy:    return ("⧉", 13)
        case .save:    return ("⤓", 13)
        case .close:   return ("✕", 13)
        case .opacity: return ("\(Int(((host?.alphaValue ?? 1) * 100).rounded()))", 9)
        }
    }

    private func drawBar(_ ctx: CGContext) {
        guard isHovering else { return }

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.62))
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: barHeight))

        for (button, rect) in barButtons() {
            if hoveredButton == button.rawValue {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.24))
                ctx.addPath(CGPath(
                    roundedRect: rect.insetBy(dx: 1, dy: 1),
                    cornerWidth: 4,
                    cornerHeight: 4,
                    transform: nil
                ))
                ctx.fillPath()
            }

            let (text, size) = barLabel(button)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.92)
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func button(at point: CGPoint) -> BarButton? {
        guard isHovering, point.y <= barHeight else { return nil }
        for (button, rect) in barButtons() where rect.contains(point) {
            return button
        }
        return nil
    }

    private func perform(_ button: BarButton) {
        switch button {
        case .copy:
            copyImage()
        case .save:
            saveImage()
        case .opacity:
            cycleOpacity()
        case .close:
            PinManager.shared.close(host)
        }
    }

    private func cycleOpacity() {
        guard let host else { return }
        let steps: [CGFloat] = [1.0, 0.75, 0.5, 0.25]
        let current = host.alphaValue
        host.alphaValue = steps.first { $0 < current - 0.01 } ?? 1.0
        needsDisplay = true
    }

    // MARK: - 拖动

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = button(at: point) {
            perform(button)
            return
        }

        isDragging = true
        dragMouseOrigin = NSEvent.mouseLocation
        dragWindowOrigin = host?.frame.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let host else { return }
        let current = NSEvent.mouseLocation
        host.setFrameOrigin(NSPoint(
            x: dragWindowOrigin.x + (current.x - dragMouseOrigin.x),
            y: dragWindowOrigin.y + (current.y - dragMouseOrigin.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            NSCursor.pop()
        }
        isDragging = false
    }

    // MARK: - 缩放

    override func scrollWheel(with event: NSEvent) {
        guard let host else { return }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        let factor = 1 + delta * 0.012
        var frame = host.frame
        var newSize = CGSize(width: frame.width * factor, height: frame.height * factor)

        // 限制范围：太小看不清，太大铺满屏
        let minWidth: CGFloat = 80
        let maxWidth = (host.screen?.visibleFrame.width ?? 1400) * 0.95
        newSize.width = min(max(newSize.width, minWidth), maxWidth)
        newSize.height = newSize.width * (frame.height / frame.width)

        // 以窗口中心为锚点缩放
        frame.origin.x -= (newSize.width - frame.width) / 2
        frame.origin.y -= (newSize.height - frame.height) / 2
        frame.size = newSize
        host.setFrame(frame, display: true)
    }

    // MARK: - 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let copy = NSMenuItem(title: "复制", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)

        let save = NSMenuItem(title: "另存为…", action: #selector(saveImage), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        menu.addItem(.separator())

        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [100, 75, 50, 25] {
            let item = NSMenuItem(
                title: "\(value)%",
                action: #selector(setOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = value
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())

        let close = NSMenuItem(title: "关闭这张", action: #selector(closeSelf), keyEquivalent: "")
        close.target = self
        menu.addItem(close)

        let closeAll = NSMenuItem(title: "关闭全部贴图", action: #selector(closeAll), keyEquivalent: "")
        closeAll.target = self
        menu.addItem(closeAll)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImage() {
        guard let image else { return }
        ImageOutput.copyToPasteboard(image)
    }

    @objc private func saveImage() {
        guard let image else { return }
        _ = ImageOutput.saveWithPanel(image)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        host?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func closeSelf() {
        PinManager.shared.close(host)
    }

    @objc private func closeAll() {
        PinManager.shared.closeAll()
    }
}
