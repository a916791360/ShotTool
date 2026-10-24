import AppKit
import Carbon.HIToolbox

@MainActor
final class LongShotHUDController {

    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var finishButton: NSButton?
    private var cancelButton: NSButton?

    private var finishHotKey: GlobalHotKey?
    private var keypadEnterHotKey: GlobalHotKey?
    private var cancelHotKey: GlobalHotKey?

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {}

    func show(near globalRect: CGRect, on screen: NSScreen) {
        close()

        let hudWidth: CGFloat = 320
        let hudHeight: CGFloat = 48

        // 默认放置在选区底边下方 12pt；如果太贴近屏幕底部，则放到选区顶边上方 12pt
        let screenRect = ScreenGeometry.cgRect(of: screen)
        var hudOriginY = globalRect.maxY + 12
        if hudOriginY + hudHeight > screenRect.maxY - 10 {
            hudOriginY = globalRect.minY - hudHeight - 12
        }
        hudOriginY = max(screenRect.minY + 10, min(hudOriginY, screenRect.maxY - hudHeight - 10))

        var hudOriginX = globalRect.midX - hudWidth / 2
        hudOriginX = max(screenRect.minX + 10, min(hudOriginX, screenRect.maxX - hudWidth - 10))

        let globalCG = CGRect(x: hudOriginX, y: hudOriginY, width: hudWidth, height: hudHeight)
        let nsRect = ScreenGeometry.nsRect(fromCG: globalCG, primaryHeight: ScreenGeometry.primaryHeight)

        let window = NSPanel(
            contentRect: nsRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: nsRect.size))
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // 状态文字
        let label = NSTextField(labelWithString: "已截 1 屏 · 请自然向下滚动")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = label

        // 取消按钮
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(handleCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.font = NSFont.systemFont(ofSize: 12)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        self.cancelButton = cancelBtn

        // 完成按钮
        let finishBtn = NSButton(title: "完成 ↵", target: self, action: #selector(handleFinish))
        finishBtn.bezelStyle = .rounded
        finishBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        finishBtn.contentTintColor = .controlAccentColor
        finishBtn.keyEquivalent = "\r"
        finishBtn.translatesAutoresizingMaskIntoConstraints = false
        self.finishButton = finishBtn

        effectView.addSubview(label)
        effectView.addSubview(cancelBtn)
        effectView.addSubview(finishBtn)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -8),

            cancelBtn.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            cancelBtn.trailingAnchor.constraint(equalTo: finishBtn.leadingAnchor, constant: -6),

            finishBtn.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            finishBtn.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
        ])

        window.contentView = effectView
        window.orderFrontRegardless()
        self.panel = window

        installHotKeys()
    }

    func updateStatus(screenCount: Int, heightPx: Int) {
        if heightPx > 0 {
            statusLabel?.stringValue = "已截 \(screenCount) 屏 (\(heightPx)px) · 继续滚动"
        } else {
            statusLabel?.stringValue = "已录 \(screenCount) 帧 · 请自然滚动"
        }
    }

    func showFinishing() {
        statusLabel?.stringValue = "正在生成高清长图..."
        finishButton?.isEnabled = false
        cancelButton?.isEnabled = false
    }

    func close() {
        removeHotKeys()
        panel?.orderOut(nil)
        panel = nil
        statusLabel = nil
        finishButton = nil
        cancelButton = nil
    }

    // MARK: - 全局快捷键（拦截下层 App 的键盘焦点）

    private func installHotKeys() {
        removeHotKeys()

        // Return / Enter 完成
        let enterKey = GlobalHotKey(id: 101)
        enterKey.onFire = { [weak self] in
            self?.handleFinish()
        }
        enterKey.register(keyCode: UInt32(kVK_Return), modifiers: 0)
        self.finishHotKey = enterKey

        let keypadEnterKey = GlobalHotKey(id: 102)
        keypadEnterKey.onFire = { [weak self] in
            self?.handleFinish()
        }
        keypadEnterKey.register(keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0)
        self.keypadEnterHotKey = keypadEnterKey

        // Esc 取消
        let escKey = GlobalHotKey(id: 103)
        escKey.onFire = { [weak self] in
            self?.handleCancel()
        }
        escKey.register(keyCode: UInt32(kVK_Escape), modifiers: 0)
        self.cancelHotKey = escKey
    }

    private func removeHotKeys() {
        finishHotKey?.unregister()
        finishHotKey = nil
        keypadEnterHotKey?.unregister()
        keypadEnterHotKey = nil
        cancelHotKey?.unregister()
        cancelHotKey = nil
    }

    @objc private func handleFinish() {
        onFinish?()
    }

    @objc private func handleCancel() {
        onCancel?()
    }
}
