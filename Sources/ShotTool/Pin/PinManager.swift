import AppKit

/// 管理所有贴图窗口。
@MainActor
final class PinManager {

    static let shared = PinManager()

    private var windows: [PinWindow] = []

    private init() {}

    var count: Int { windows.count }

    /// - Parameter globalOrigin: 图片左上角在 CG 全局坐标（pt，y 向下）中的位置
    func pin(_ image: CGImage, at globalOrigin: CGPoint, pixelScale: CGFloat) {
        let width = CGFloat(image.width) / pixelScale
        let height = CGFloat(image.height) / pixelScale

        // CG 全局（左上原点）→ NS 窗口坐标（左下原点）
        let origin = NSPoint(
            x: globalOrigin.x,
            y: ScreenGeometry.primaryHeight - globalOrigin.y - height
        )

        let window = PinWindow(image: image, at: origin, pixelScale: pixelScale)
        window.orderFrontRegardless()
        windows.append(window)

        NSLog("[ShotTool] 贴图 \(windows.count) 张，尺寸 \(Int(width))x\(Int(height))pt")
    }

    func close(_ window: PinWindow?) {
        guard let window, let index = windows.firstIndex(where: { $0 === window }) else { return }
        windows.remove(at: index)
        window.orderOut(nil)
    }

    func closeAll() {
        let count = windows.count
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        if count > 0 {
            NSLog("[ShotTool] 关闭全部贴图 \(count) 张")
        }
    }

    /// 关掉已经不可见或尺寸退化的窗口，防止列表越积越多
    func prune() {
        windows.removeAll { !$0.isVisible }
    }
}
