import AppKit

enum ToolbarID: Hashable {
    case tool(AnnotationKind)
    case undo
    case redo
    case pin
    case longShot
    case copy
    case save
    case close
}

/// 标注工具条。
///
/// 用自绘 + 手写命中检测，而不是加 NSButton 子视图：
/// 覆盖窗里已经是一整块自绘画布，塞子视图会导致重绘时序和坐标系统两套逻辑。
struct ToolbarLayout {

    struct Button {
        let id: ToolbarID
        let rect: CGRect
        let label: String
        let enabled: Bool
    }

    let buttons: [Button]
    let background: CGRect

    private static let buttonSize: CGFloat = 30
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 2
    private static let groupGap: CGFloat = 10

    private struct Spec {
        let id: ToolbarID
        let label: String
        let enabled: Bool
        let startsGroup: Bool
    }

    static func compute(
        selection: CGRect,
        bounds: CGRect,
        activeTool: AnnotationKind?,
        canUndo: Bool,
        canRedo: Bool,
        hasAnnotations: Bool
    ) -> ToolbarLayout {
        let specs: [Spec] = [
            Spec(id: .tool(.rectangle), label: "▭", enabled: true, startsGroup: true),
            Spec(id: .tool(.ellipse),   label: "◯", enabled: true, startsGroup: false),
            Spec(id: .tool(.arrow),     label: "↗", enabled: true, startsGroup: false),
            Spec(id: .tool(.text),      label: "T", enabled: true, startsGroup: false),
            Spec(id: .undo,             label: "↶", enabled: canUndo, startsGroup: true),
            Spec(id: .redo,             label: "↷", enabled: canRedo, startsGroup: false),
            Spec(id: .pin,              label: "钉", enabled: true, startsGroup: true),
            Spec(id: .longShot,         label: "⇕", enabled: true, startsGroup: false),
            Spec(id: .copy,             label: "⧉", enabled: hasAnnotations, startsGroup: true),
            Spec(id: .save,             label: "⤓", enabled: hasAnnotations, startsGroup: false),
            Spec(id: .close,            label: "✕", enabled: true, startsGroup: true)
        ]

        var width = padding * 2
        for (index, spec) in specs.enumerated() {
            width += buttonSize
            if index > 0 && !spec.startsGroup { width += gap }
            if spec.startsGroup && index > 0 { width += groupGap }
        }
        let height = buttonSize + padding * 2

        // 默认放选区下方；贴底就翻到上方
        var originY = selection.maxY + 10
        if originY + height > bounds.maxY - 4 {
            originY = selection.minY - 10 - height
        }
        originY = max(4, min(originY, bounds.maxY - height - 4))

        var originX = selection.minX
        originX = max(4, min(originX, bounds.maxX - width - 4))

        var buttons: [Button] = []
        var cursorX = originX + padding
        for (index, spec) in specs.enumerated() {
            if spec.startsGroup && index > 0 { cursorX += groupGap }
            else if index > 0 { cursorX += gap }

            let rect = CGRect(
                x: cursorX,
                y: originY + padding,
                width: buttonSize,
                height: buttonSize
            )
            buttons.append(Button(id: spec.id, rect: rect, label: spec.label, enabled: spec.enabled))
            cursorX += buttonSize
        }

        let background = CGRect(x: originX, y: originY, width: width, height: height)
        return ToolbarLayout(buttons: buttons, background: background)
    }

    func hitTest(_ point: CGPoint) -> ToolbarID? {
        for button in buttons where button.rect.insetBy(dx: -2, dy: -2).contains(point) {
            return button.id
        }
        return nil
    }

    func draw(in ctx: CGContext, activeTool: AnnotationKind?) {
        // 底板
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.92))
        ctx.addPath(CGPath(
            roundedRect: background,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        ))
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
        ctx.setLineWidth(0.5)
        ctx.addPath(CGPath(
            roundedRect: background.insetBy(dx: 0.25, dy: 0.25),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        ))
        ctx.strokePath()

        for button in buttons {
            let isActive: Bool = {
                if case .tool(let kind) = button.id { return kind == activeTool }
                return false
            }()

            if isActive {
                ctx.setFillColor((NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue).cgColor)
                ctx.addPath(CGPath(
                    roundedRect: button.rect,
                    cornerWidth: 6,
                    cornerHeight: 6,
                    transform: nil
                ))
                ctx.fillPath()
            }

            if let img = ToolbarIcon.image(for: button.id) {
                let iconSize: CGFloat = 16
                let iconRect = CGRect(
                    x: button.rect.midX - iconSize / 2,
                    y: button.rect.midY - iconSize / 2,
                    width: iconSize,
                    height: iconSize
                )
                let alpha: CGFloat = button.enabled ? (isActive ? 1.0 : 0.92) : 0.28
                img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha)
            } else {
                let color: NSColor = button.enabled
                    ? (isActive ? .white : NSColor(white: 1, alpha: 0.90))
                    : NSColor(white: 1, alpha: 0.28)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: color
                ]
                let size = (button.label as NSString).size(withAttributes: attributes)
                let point = CGPoint(
                    x: button.rect.midX - size.width / 2,
                    y: button.rect.midY - size.height / 2
                )
                (button.label as NSString).draw(at: point, withAttributes: attributes)
            }
        }
    }
}
