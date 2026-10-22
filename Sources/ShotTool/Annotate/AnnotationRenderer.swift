import AppKit

/// 标注渲染。
///
/// 所有几何量都存**图像像素**，渲染时统一除以 scale 换成 pt。
/// 这样同一个标注在 1x / 2x 屏上视觉大小一致，导出到原图也自动对齐。
enum AnnotationRenderer {

    /// - Parameters:
    ///   - origin: 选区左上角在目标坐标系中的位置（pt）
    ///   - scale: 每个 pt 对应多少图像像素（Retina 是 2）
    static func draw(
        _ items: [Annotation],
        in ctx: CGContext,
        origin: CGPoint,
        scale: CGFloat,
        selectedID: UUID? = nil
    ) {
        for item in items {
            draw(item, in: ctx, origin: origin, scale: scale)
        }
        if let selectedID, let selected = items.first(where: { $0.id == selectedID }) {
            drawSelection(selected, in: ctx, origin: origin, scale: scale)
        }
    }

    private static func point(_ p: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + p.x / scale, y: origin.y + p.y / scale)
    }

    private static func rect(_ r: CGRect, origin: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + r.minX / scale,
            y: origin.y + r.minY / scale,
            width: r.width / scale,
            height: r.height / scale
        )
    }

    private static func draw(
        _ item: Annotation,
        in ctx: CGContext,
        origin: CGPoint,
        scale: CGFloat
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setStrokeColor(item.style.color.cgColor)
        ctx.setFillColor(item.style.color.cgColor)
        ctx.setLineWidth(max(0.5, item.style.lineWidth / scale))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.kind {
        case .rectangle:
            ctx.stroke(rect(CGRect(corner: item.start, corner: item.end), origin: origin, scale: scale))

        case .ellipse:
            let box = rect(CGRect(corner: item.start, corner: item.end), origin: origin, scale: scale)
            ctx.strokeEllipse(in: box)

        case .arrow:
            drawArrow(
                from: point(item.start, origin: origin, scale: scale),
                to: point(item.end, origin: origin, scale: scale),
                lineWidth: max(0.5, item.style.lineWidth / scale),
                in: ctx
            )

        case .text:
            drawText(item, origin: origin, scale: scale)
        }
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat,
        in ctx: CGContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)

        // 头部随线段长度增长，但要收敛：
        // 线性涨到 72px 封顶，否则长箭头的三角会大到吃掉半张图
        //（先用 0.30 系数试过，1000px 的箭头长了 300px 的三角，过火）。
        let headLength = max(lineWidth * 2.5, min(length * 0.16, 72))
        // 张角从 π/7 放宽到 π/6，头部更饱满一些
        let headAngle = CGFloat.pi / 6

        // 线收到头部底端，避免线尖穿透三角
        let shaftEnd = CGPoint(
            x: end.x - headLength * 0.88 * cos(angle),
            y: end.y - headLength * 0.88 * sin(angle)
        )

        ctx.beginPath()
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let left = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        ctx.beginPath()
        ctx.move(to: end)
        ctx.addLine(to: left)
        ctx.addLine(to: right)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ item: Annotation, origin: CGPoint, scale: CGFloat) {
        guard let text = item.text, !text.isEmpty else { return }

        let fontSize = max(6, item.style.fontSize / scale)
        let position = point(item.start, origin: origin, scale: scale)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: item.style.color
        ]

        // 文字带一点同色描边，压在深色截图上也能看清
        let outline: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.55)
        ]
        (text as NSString).draw(at: CGPoint(x: position.x + 1, y: position.y + 1), withAttributes: outline)
        (text as NSString).draw(at: position, withAttributes: attributes)
    }

    private static func drawSelection(
        _ item: Annotation,
        in ctx: CGContext,
        origin: CGPoint,
        scale: CGFloat
    ) {
        let box = rect(item.boundingBox, origin: origin, scale: scale).insetBy(dx: -4, dy: -4)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box)

        // 四个角把手
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(NSColor.white.cgColor)
        let handle: CGFloat = 6
        for corner in [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY),
            CGPoint(x: box.maxX, y: box.maxY)
        ] {
            let r = CGRect(
                x: corner.x - handle / 2,
                y: corner.y - handle / 2,
                width: handle,
                height: handle
            )
            ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
            ctx.setFillColor(NSColor.white.cgColor)
        }
    }

    /// 文字尺寸按像素测量（把 px 数值当 pt 来量，比例一致）。
    /// 第一版只支持单行。
    static func measureText(_ text: String, style: AnnotationStyle) -> CGSize {
        guard !text.isEmpty else { return CGSize(width: 40, height: style.fontSize) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // 至少给一个可点的热区
        return CGSize(width: max(size.width, 30), height: max(size.height, style.fontSize))
    }

    /// 把标注合成到原图上，返回新图。
    ///
    /// 导出走独立路径而不是「截屏带标注」：截屏会连遮罩和工具条一起拍进去。
    static func composite(base: CGImage, annotations: [Annotation], scale: CGFloat) -> CGImage {
        guard !annotations.isEmpty else { return base }

        let width = base.width
        let height = base.height
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return base }

        // 顺序很关键，写反了整张图会上下颠倒：
        // 1) 先在默认坐标系（原点左下）把底图铺满 —— 这样底图是正立的
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 2) 再翻转坐标系画标注（标注坐标约定是左上原点、y 向下）
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(annotations, in: ctx, origin: .zero, scale: scale)
        NSGraphicsContext.current = previous

        ctx.restoreGState()

        return ctx.makeImage() ?? base
    }
}
