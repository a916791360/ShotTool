import AppKit
import CoreGraphics

/// 一个屏幕上的窗口（用于「鼠标悬停高亮整窗、单击直接截该窗」）。
struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    /// CG 全局坐标（pt，y 向下）
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
}

/// 依据 REA 取证的实现路径：iShot 导入 `CGWindowListCopyWindowInfo` +
/// `kCGWindowBounds` / `kCGWindowLayer` / `kCGWindowOwnerPID` / `kCGWindowAlpha`，
/// 即「按层过滤 + 按 z 序遍历」的常规做法，本项目同路径自主实现。
enum WindowEnumerator {

    /// 屏幕上的普通窗口，按 z 序（最上层在前）。
    static func onScreenWindows(excludingPID: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WindowInfo] = []
        result.reserveCapacity(raw.count)

        for dict in raw {
            guard
                let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t,
                let layer = dict[kCGWindowLayer as String] as? Int,
                let rawBounds = dict[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
            else { continue }

            // 只看普通应用窗口层。菜单栏、Dock、输入法候选框都在其他层。
            guard layer == 0 else { continue }
            guard ownerPID != excludingPID else { continue }

            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }

            // 太小的多是无边框浮层、tooltip，不适合作为截图目标
            guard bounds.width >= 40, bounds.height >= 40 else { continue }

            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? ""

            result.append(
                WindowInfo(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    ownerName: ownerName,
                    bounds: bounds,
                    layer: layer,
                    alpha: CGFloat(alpha)
                )
            )
        }
        return result
    }

    /// 点下面最上层的那个窗口。
    static func topmostWindow(at point: CGPoint, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.bounds.contains(point) }
    }
}
