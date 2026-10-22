import AppKit
import CoreGraphics

/// 全项目唯一的坐标换算入口。
///
/// 两套坐标系必须分清（这是 V0.1 最容易返工的地方）：
/// - **NS 坐标系**（`NSScreen.frame`、`NSEvent.mouseLocation`）：原点在主屏**左下角**，y 轴向上。
/// - **CG 坐标系**（`CGWindowListCopyWindowInfo` 的 bounds、`CGDisplayBounds`、SCK 图像）：原点在主屏**左上角**，y 轴向下。
///
/// 本项目内部统一只用 **CG 全局坐标（pt，y 向下）**，只在需要交给 AppKit 时转换一次。
enum ScreenGeometry {

    /// 主屏：`frame.origin == .zero` 的那块屏。
    /// 不能假设 `NSScreen.screens[0]` 是主屏 —— 数组顺序不保证。
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero }
    }

    /// 坐标翻转基准：主屏高度。
    static var primaryHeight: CGFloat {
        primaryScreen?.frame.maxY ?? 0
    }

    // MARK: - 点

    static func cgPoint(fromNS point: NSPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func nsPoint(fromCG point: CGPoint, primaryHeight: CGFloat) -> NSPoint {
        NSPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: - 矩形

    static func cgRect(fromNS rect: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func nsRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 屏

    /// 某块屏在 CG 全局坐标下的矩形。
    static func cgRect(of screen: NSScreen) -> CGRect {
        cgRect(fromNS: screen.frame, primaryHeight: primaryHeight)
    }

    /// 某块屏在 CG 全局坐标下的原点（用于「屏内局部坐标 ↔ 全局坐标」）。
    static func cgOrigin(of screen: NSScreen) -> CGPoint {
        cgRect(of: screen).origin
    }

    /// 点落在哪块屏上。找不到时返回主屏。
    static func screen(containing cgPoint: CGPoint) -> NSScreen? {
        let p = nsPoint(fromCG: cgPoint, primaryHeight: primaryHeight)
        return NSScreen.screens.first { $0.frame.contains(p) } ?? primaryScreen
    }
}

extension NSScreen {
    /// 与 ScreenCaptureKit / CoreGraphics 对齐用的 displayID。
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// pt → px 的倍率（Retina 通常是 2）。
    var pixelScale: CGFloat {
        backingScaleFactor
    }
}

/// 一块屏的几何信息快照。
///
/// 单独抽出来是为了「先在主线程把 AppKit 状态读干净，再交给异步捕获」——
/// NSScreen 不是线程安全的，在 Task 里直接问它是隐患。
struct DisplayContext {
    let displayID: CGDirectDisplayID
    /// pt → px 倍率
    let scale: CGFloat
    /// 该屏在 CG 全局坐标下的矩形（pt，y 向下）
    let cgRect: CGRect
}

extension ScreenGeometry {
    static func displayContexts() -> [DisplayContext] {
        NSScreen.screens.map { screen in
            DisplayContext(
                displayID: screen.displayID,
                scale: screen.pixelScale,
                cgRect: cgRect(of: screen)
            )
        }
    }
}

extension CGRect {
    /// 两个角点构造矩形（拖拽框选用，允许反向拖）。
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
