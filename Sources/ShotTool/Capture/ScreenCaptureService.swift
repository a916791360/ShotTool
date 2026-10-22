import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "没有屏幕录制权限"
        case .noDisplay:
            return "找不到可截取的显示器"
        case .underlying(let message):
            return message
        }
    }
}

/// 一块屏的冻结帧。
///
/// 关键设计：**先抓图，再显示遮罩**。
/// 好处有三个：① 遮罩本身不会出现在截图里；② 放大镜直接从这张图里裁，不用反复调系统 API；
/// ③ 截出来的内容是「按下热键那一刻」的画面，符合预期。
struct DisplayFrame {
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// pt → px 倍率
    let scale: CGFloat
    /// 该屏在 CG 全局坐标下的矩形（pt，y 向下）
    let cgRect: CGRect
}

enum ScreenCaptureService {

    // MARK: - 权限

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 请求权限。返回时通常还是 false —— 系统要求用户去设置里手动勾选并重启 App。
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - 截取

    /// 抓取所有显示器（带超时兜底）。
    ///
    /// 超时是刚需，不是保险丝：ScreenCaptureKit 在没有授权时会**挂起等待系统授权框**，
    /// 不抛错也不返回。用户看到的现象是「按了热键毫无反应」，比报错难查得多。
    static func captureAllDisplays(
        contexts: [DisplayContext],
        timeout: TimeInterval = 5
    ) async throws -> [CGDirectDisplayID: DisplayFrame] {
        try await withThrowingTaskGroup(of: [CGDirectDisplayID: DisplayFrame].self) { group in
            group.addTask {
                try await captureDisplays(contexts: contexts)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CaptureError.underlying(
                    "抓屏超过 \(Int(timeout)) 秒没有返回，通常是「屏幕录制」权限还没授予。"
                        + "请到系统设置 → 隐私与安全性 → 屏幕录制里勾选 ShotTool，然后重新打开本 App。"
                )
            }

            do {
                guard let frames = try await group.next() else { throw CaptureError.noDisplay }
                group.cancelAll()
                return frames
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// 只走 ScreenCaptureKit（macOS 14+）。iShot 那套 `CGWindowListCreateImage` 双轨制是为了兼容
    /// 10.13 才付出的维护成本 —— REA 的符号表里 `SCScreenshotManager` 是 **weak import**，
    /// 说明它确实是运行时探测；我们不需要这层复杂度。
    ///
    /// - Parameter contexts: 主线程预先读好的屏幕几何信息，避免在异步上下文里访问 NSScreen。
    private static func captureDisplays(
        contexts: [DisplayContext]
    ) async throws -> [CGDirectDisplayID: DisplayFrame] {
        guard hasPermission() else { throw CaptureError.noPermission }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureError.underlying("枚举可共享内容失败：\(error.localizedDescription)")
        }

        guard !content.displays.isEmpty else { throw CaptureError.noDisplay }

        // 不把本 App 自己的窗口截进去（重复唤起时可能还有残留遮罩）
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        var result: [CGDirectDisplayID: DisplayFrame] = [:]

        for display in content.displays {
            guard let context = contexts.first(where: { $0.displayID == display.displayID }) else {
                continue
            }

            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()

            // 不要用 display.width / display.height —— 实测它给的是逻辑点（这台机器上返回 1470），
            // 直接拿来当像素尺寸会截出半分辨率图，文字发虚但不报警。
            // 物理像素必须自己从「逻辑尺寸 × 倍率」算。
            let pixelWidth = Int((context.cgRect.width * context.scale).rounded())
            let pixelHeight = Int((context.cgRect.height * context.scale).rounded())
            config.width = pixelWidth
            config.height = pixelHeight
            config.showsCursor = false
            config.captureResolution = .best
            config.scalesToFit = false

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                result[display.displayID] = DisplayFrame(
                    displayID: display.displayID,
                    image: image,
                    scale: context.scale,
                    cgRect: context.cgRect
                )
            } catch {
                throw CaptureError.underlying(
                    "截取显示器 \(display.displayID) 失败：\(error.localizedDescription)"
                )
            }
        }

        guard !result.isEmpty else { throw CaptureError.noDisplay }
        return result
    }
}
