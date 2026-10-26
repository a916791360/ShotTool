import AppKit

/// IconPark 官方矢量图标提供类（ByteDance IconPark）
/// 所有图标遵循 48x48 矢量网格，并自动作为 Template 图像按当前工具条颜色（选中高亮/普通白/不可用暗态）精准渲染
final class ToolbarIcon {

    private static let svgMap: [ToolbarID: String] = [
        // 1:1 正方形矩形（用户明确要求 1:1 正方形）
        .tool(.rectangle): """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M39 6H9C7.34315 6 6 7.34315 6 9V39C6 40.6569 7.34315 42 9 42H39C40.6569 42 42 40.6569 42 39V9C42 7.34315 40.6569 6 39 6Z" fill="none" stroke="black" stroke-width="3.6" stroke-linejoin="round"/>
        </svg>
        """,

        // 圆形/椭圆
        .tool(.ellipse): """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <circle cx="24" cy="24" r="18" fill="none" stroke="black" stroke-width="3.6"/>
        </svg>
        """,

        // 箭头 (ArrowRightUp)
        .tool(.arrow): """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M19 11H37V29" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M11.5439 36.4559L36.9997 11" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 文字 (FontSize)
        .tool(.text): """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M8 11L8 6H40V11" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M24 6V42" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M16 42H32" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 撤销 (Undo)
        .undo: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M11.2721 36.7279C14.5294 39.9853 19.0294 42 24 42C33.9411 42 42 33.9411 42 24C42 14.0589 33.9411 6 24 6C19.0294 6 14.5294 8.01472 11.2721 11.2721C9.61407 12.9301 6 17 6 17" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M6 9V17H14" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 重做 (Redo)
        .redo: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M36.7279 36.7279C33.4706 39.9853 28.9706 42 24 42C14.0589 42 6 33.9411 6 24C6 14.0589 14.0589 6 24 6C28.9706 6 33.4706 8.01472 36.7279 11.2721C38.3859 12.9301 42 17 42 17" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M42 8V17H33" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 图钉 (Pushpin - IconPark 官方标准图钉造型，平顶、细颈、阔腰、下尖针)
        .pin: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M32 4H16L20 7L16 20C16 20 10 24 10 28H20L24 44L28 28H38C38 24 34 21.1667 32 20L28 7L32 4Z" fill="none" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 长截图 (SortFour / UpDown 双向滚动长截图标)
        .longShot: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M16 12L24 4L32 12" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M32 36L24 44L16 36" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M24 4V44" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 复制 (Copy)
        .copy: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M13 12.4316V7.8125C13 6.2592 14.2592 5 15.8125 5H40.1875C41.7408 5 43 6.2592 43 7.8125V32.1875C43 33.7408 41.7408 35 40.1875 35H35.5163" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M32.1875 13H7.8125C6.2592 13 5 14.2592 5 15.8125V40.1875C5 41.7408 6.2592 43 7.8125 43H32.1875C33.7408 43 35 41.7408 35 40.1875V15.8125C35 14.2592 33.7408 13 32.1875 13Z" fill="none" stroke="black" stroke-width="3.6" stroke-linejoin="round"/>
        </svg>
        """,

        // 保存 (Download)
        .save: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M6 24V42H42V24" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M33 23L24 32L15 23" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M24 6V32" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """,

        // 关闭 (Close)
        .close: """
        <svg width="48" height="48" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M10 10L38 38" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        <path d="M10 38L38 10" stroke="black" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """
    ]

    private static let cachedImages: [ToolbarID: NSImage] = {
        var map: [ToolbarID: NSImage] = [:]
        for (id, svg) in svgMap {
            if let data = svg.data(using: .utf8), let img = NSImage(data: data) {
                img.isTemplate = true
                map[id] = img
            }
        }
        return map
    }()

    static func image(for id: ToolbarID) -> NSImage? {
        cachedImages[id]
    }
}
