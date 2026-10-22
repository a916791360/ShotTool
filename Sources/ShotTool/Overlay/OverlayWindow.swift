import AppKit

/// 全屏遮罩窗。
///
/// 三个必须重写/设置的属性，少一个就出问题：
/// 1. `canBecomeKey` 必须为 true —— borderless 窗口默认不接受键盘，Esc / 回车会全部失效；
/// 2. `level = .screenSaver` —— 否则盖不住菜单栏、Dock 和全屏 App；
/// 3. `collectionBehavior` 里带 `.fullScreenAuxiliary` —— 否则在别的 App 全屏时遮罩根本出不来。
final class OverlayWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        // 注意：带 screen: 的那个 init 是 convenience initializer，子类的 designated init 不能调它，
        // 所以这里只用 designated init，坐标靠 contentRect 自带定位（screen.frame 已是全局 NS 坐标）。
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }
}
