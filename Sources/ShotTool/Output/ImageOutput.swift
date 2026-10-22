import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageOutput {

    /// 复制到剪贴板。同时写 PNG 和 TIFF —— 只写其中一种时，
    /// 粘进微信 / 企微 / 飞书 / Figma 会有一方拿不到图。
    @discardableResult
    static func copyToPasteboard(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = pasteboard.setData(png, forType: .png)

        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            ok = pasteboard.setData(tiff, forType: .tiff) || ok
        }
        return ok
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "Shot_\(formatter.string(from: Date())).png"
    }

    /// 弹保存面板让用户自己选位置。取消返回 nil。
    ///
    /// 和「复制」的区别就在这里：复制是隐式的、不需要决定去哪；
    /// 保存必须让人决定文件放哪，否则两个按钮的行为就撞了。
    static func saveWithPanel(_ image: CGImage) -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.title = "保存截图"
        panel.nameFieldStringValue = defaultFileName()
        panel.directoryURL = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return save(image, to: url) ? url : nil
    }

    /// 直接存桌面（菜单栏「保存最近一张」用，不打扰）
    @discardableResult
    static func saveToDesktop(_ image: CGImage) -> URL? {
        let directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let url = directory.appendingPathComponent(defaultFileName())
        return save(image, to: url) ? url : nil
    }

    @discardableResult
    static func save(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
