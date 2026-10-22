import AppKit
import Carbon.HIToolbox

/// 全局热键。
///
/// 为什么不用 `CGEventTap`：那需要「辅助功能」权限，用户装完会被拦一道。
/// `RegisterEventHotKey` 是 Carbon 时代的老 API，**不需要任何权限**，
/// 这也是 iShot 的选择（REA 在符号表里同时看到 `_RegisterEventHotKey`
/// 与 `_InstallEventHandler`、`_GetApplicationEventTarget`）。
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID: EventHotKeyID

    var onFire: (() -> Void)?

    init(id: UInt32 = 1) {
        // 四字符签名，方便和其他 App 的热键区分
        self.hotKeyID = EventHotKeyID(signature: OSType(0x53484F54) /* 'SHOT' */, id: id)
    }

    deinit {
        unregister()
    }

    /// 注册。keyCode 用 `kVK_ANSI_*` 常量，modifiers 用 Carbon 的 `cmdKey` / `shiftKey` 等。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { instance.onFire?() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        guard status == noErr else { return false }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

/// 快捷键的可读描述（菜单里显示用）。
struct HotKeySpec {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    /// 默认 ⌘⇧2 —— 和系统截图 ⌘⇧4 区分开，又不至于太偏。
    static let `default` = HotKeySpec(
        keyCode: UInt32(kVK_ANSI_2),
        modifiers: UInt32(cmdKey | shiftKey),
        display: "⇧⌘2"
    )
}
