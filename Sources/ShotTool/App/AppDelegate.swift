import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem?
    private var isCapturing = false
    private var lastImage: CGImage?

    /// 自测/演示模式：跳过单实例检查，这样已安装版本在后台跑时也能启动诊断
    private var isDiagnosticRun: Bool {
        CommandLine.arguments.contains { argument in
            argument.hasPrefix("--demo") || argument == "--selftest" || argument.hasSuffix("-test")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护。
        // 多开时全局热键只有第一个注册得上，第二个会静默失败——用户看到的是「按了没反应」。
        // 只让「比我先启动」的实例获胜，避免两个同时启动时互相认为对方存在、双双退出。
        //
        // 但自测/演示模式要放行：否则已经装好的版本在后台跑着，`--demo-xxx` 一启动就被踢掉，
        // 日志里只剩一句「已有更早的实例」，什么问题都查不了。
        if let bundleID = Bundle.main.bundleIdentifier, !isDiagnosticRun {
            let myPID = ProcessInfo.processInfo.processIdentifier
            let myLaunch = NSRunningApplication.current.launchDate ?? Date()

            let earlier = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != myPID }
                .filter { other in
                    let otherLaunch = other.launchDate ?? Date()
                    if otherLaunch < myLaunch { return true }
                    if otherLaunch == myLaunch { return other.processIdentifier < myPID }
                    return false
                }

            if let first = earlier.first {
                NSLog("[ShotTool] 已有更早的实例在运行（pid \(first.processIdentifier)），本实例退出")
                NSApp.terminate(nil)
                return
            }
        }

        setupStatusItem()
        setupCoordinator()
        setupHotKey()

        if !ScreenCaptureService.hasPermission() {
            // 首次启动先别急着弹窗，等用户真的按热键时再引导（避免装完就被打扰）
            NSLog("[ShotTool] 尚无屏幕录制权限，首次截图时会引导授权")
        }

        // 自测入口：`--auto-capture` 启动后自动唤一次遮罩，并在 5 秒后自动收场。
        // 用来在没有人手动按热键的情况下验证遮罩层是否真的能盖住全屏。
        if CommandLine.arguments.contains("--auto-capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                OverlayCoordinator.shared.cancel()
            }
        }

        // 自测入口：遮罩出现后自动摆一个选区，验证挖空 / 描边 / 尺寸标签。
        if CommandLine.arguments.contains("--demo-selection") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                OverlayCoordinator.shared.demoSelection(
                    CGRect(x: 335, y: 228, width: 800, height: 500)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                OverlayCoordinator.shared.cancel()
            }
        }

        // 自测入口：进标注态并摆几条示例标注，验证工具条与标注渲染。
        if CommandLine.arguments.contains("--demo-annotations") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                OverlayCoordinator.shared.demoSelection(
                    CGRect(x: 335, y: 200, width: 800, height: 500)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                OverlayCoordinator.shared.demoAnnotations()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) {
                OverlayCoordinator.shared.cancel()
            }
        }

        // 自测入口：进入长截图态，验证控制条是否出现在选区中心
        if CommandLine.arguments.contains("--demo-longshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                OverlayCoordinator.shared.demoSelection(
                    CGRect(x: 400, y: 180, width: 700, height: 560)
                )
            }
            // 先把光标挪到选区中心（CGWarp 是真实移动光标，mouseLocation 会变）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                CGWarpMouseCursorPosition(CGPoint(x: 750, y: 460))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                OverlayCoordinator.shared.handleToolbar(.longShot)
            }
            // 自测只验证「进入长截图模式 + 提示条是否显示」。
            // 方案 B 的滚动由用户真实滚动驱动，脚本没法模拟（注入的滚动不是真实事件，
            // 也正好是我们放弃的那条路），所以这里不做滚动模拟。
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                OverlayCoordinator.shared.longShotController?.cancel()
            }
        }

        // 自测入口：选区后直接出图，验证剪贴板链路
        if CommandLine.arguments.contains("--demo-copy") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                OverlayCoordinator.shared.demoSelection(
                    CGRect(x: 400, y: 200, width: 600, height: 400)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                OverlayCoordinator.shared.handleToolbar(.copy)
            }
        }

        // 自测入口：走完整流程贴一张图到屏幕上
        if CommandLine.arguments.contains("--demo-pin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startCapture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                OverlayCoordinator.shared.demoSelection(
                    CGRect(x: 420, y: 240, width: 620, height: 400)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                OverlayCoordinator.shared.handleToolbar(.pin)
            }
        }

        // 自测入口：验证保存面板能否在菜单栏常驻（无 Dock 图标）的应用里正常弹出。
        // 这个很容易坏——panel 需要一个能激活的应用，否则点了按钮像没反应。
        if CommandLine.arguments.contains("--savepanel-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let ctx = CGContext(
                    data: nil, width: 400, height: 300,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ), let image = ctx.makeImage() else { return }
                let url = ImageOutput.saveWithPanel(image)
                NSLog("[ShotTool] 保存面板返回：\(url?.path ?? "已取消")")
            }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "viewfinder",
                accessibilityDescription: "截图"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "截图 · \(HotKeySpec.default.display)"
        }

        let menu = NSMenu()
        let capture = NSMenuItem(
            title: "截图",
            action: #selector(startCapture),
            keyEquivalent: "2"
        )
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())

        let save = NSMenuItem(
            title: "保存最近一张到桌面",
            action: #selector(saveLastCapture),
            keyEquivalent: "s"
        )
        save.keyEquivalentModifierMask = [.command, .shift]
        save.target = self
        menu.addItem(save)

        let closeAllPins = NSMenuItem(
            title: "关闭全部贴图",
            action: #selector(closeAllPinsAction),
            keyEquivalent: "w"
        )
        closeAllPins.keyEquivalentModifierMask = [.command, .option]
        closeAllPins.target = self
        menu.addItem(closeAllPins)

        let permission = NSMenuItem(
            title: "检查屏幕录制权限",
            action: #selector(checkPermission),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func setupHotKey() {
        hotKey.onFire = { [weak self] in
            self?.startCapture()
        }
        let spec = HotKeySpec.default
        if hotKey.register(keyCode: spec.keyCode, modifiers: spec.modifiers) {
            NSLog("[ShotTool] 全局热键已就绪：\(spec.display)")
        } else {
            NSLog("[ShotTool] 热键注册失败，可能被其他 App 占用")
        }
    }

    private func setupCoordinator() {
        let coordinator = OverlayCoordinator.shared

        coordinator.onFinish = { [weak self] image in
            guard let self else { return }
            self.isCapturing = false

            guard let image else { return }   // 取消，不要多余反馈

            self.lastImage = image
            ImageOutput.copyToPasteboard(image)
            NSSound(named: "Glass")?.play()
            self.flashStatusItem()
        }

        coordinator.onPermissionRequired = { [weak self] in
            self?.isCapturing = false
            self?.promptForPermission()
        }
    }

    // MARK: - 动作

    @objc private func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        OverlayCoordinator.shared.begin()
    }

    @objc private func closeAllPinsAction() {
        PinManager.shared.closeAll()
    }

    @objc private func saveLastCapture() {
        guard let lastImage else {
            NSSound.beep()
            return
        }
        if let url = ImageOutput.saveToDesktop(lastImage) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func checkPermission() {
        if ScreenCaptureService.hasPermission() {
            let alert = NSAlert()
            alert.messageText = "屏幕录制权限已授予"
            alert.informativeText = "现在可以直接用 \(HotKeySpec.default.display) 截图。"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else {
            promptForPermission()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func promptForPermission() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        没有这个权限时，系统不会报错，但截出来会是一张空的桌面壁纸 —— 这是 macOS 最容易误判的地方。

        请点「打开系统设置」，在「隐私与安全性 → 屏幕录制」里勾选 ShotTool，然后退出并重新打开本 App。

        如果开关已经是打开状态却仍然提示没权限：请用列表下方的减号（−）把它移除，再按一次热键重新授权。
        App 更新后系统会沿用旧的授权记录，而那份记录已经跟新版本对不上了。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCaptureService.requestPermission()
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            if let url {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func flashStatusItem() {
        guard let button = statusItem?.button else { return }
        let original = button.image
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            button.image = original
        }
    }
}
