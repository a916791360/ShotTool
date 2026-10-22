import AppKit

/// 自检：不启动界面，只验证最容易出错的那部分 —— 坐标换算。
///
/// 为什么值得单独写：多屏坐标错误不会崩溃、不会报错，只会让截图整体偏移，
/// 而且**只在某些屏幕排列下出现**，靠肉眼试很难覆盖。这里把不变量写成断言。
@MainActor
enum SelfTest {

    private static var failures = 0
    private static var total = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        let suffix = detail.isEmpty ? "" : "  — \(detail)"
        if ok {
            print("  [通过] \(name)\(suffix)")
        } else {
            failures += 1
            print("  [失败] \(name)\(suffix)")
        }
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.001) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    static func run() -> Int32 {
        print("ShotTool 自检 · V0.1 骨架\n")

        let screens = NSScreen.screens
        let height = ScreenGeometry.primaryHeight

        print("1. 屏幕环境")
        check("至少有一块屏", !screens.isEmpty, "\(screens.count) 块")
        guard !screens.isEmpty else {
            print("\n没有可用屏幕，无法继续。")
            return 1
        }
        check(
            "主屏存在且原点为 (0,0)",
            ScreenGeometry.primaryScreen != nil,
            ScreenGeometry.primaryScreen.map { "\($0.frame)" } ?? "未找到"
        )
        check("翻转基准高度有效", height > 0, "\(height) pt")

        print("\n2. 每块屏")
        for (index, screen) in screens.enumerated() {
            let frame = screen.frame
            let cg = ScreenGeometry.cgRect(fromNS: frame, primaryHeight: height)
            let back = ScreenGeometry.nsRect(fromCG: cg, primaryHeight: height)

            check("屏 \(index) NS→CG→NS 往返一致", nearlyEqual(frame, back), "\(cg)")
            check("屏 \(index) displayID 有效", screen.displayID != 0, "\(screen.displayID)")
            check("屏 \(index) 倍率合理", screen.pixelScale >= 1, "\(screen.pixelScale)x")
            check(
                "屏 \(index) 在 CG 坐标系内尺寸不变",
                abs(cg.width - frame.width) < 0.001 && abs(cg.height - frame.height) < 0.001
            )

            let center = CGPoint(x: cg.midX, y: cg.midY)
            let origin = ScreenGeometry.cgOrigin(of: screen)
            let local = CGPoint(x: center.x - origin.x, y: center.y - origin.y)

            check(
                "屏 \(index) 中心点转局部坐标落在屏内",
                local.x >= 0 && local.y >= 0 && local.x <= cg.width && local.y <= cg.height,
                "局部 \(local)"
            )
            check(
                "屏 \(index) 中心点能反查回本屏",
                ScreenGeometry.screen(containing: center)?.displayID == screen.displayID
            )
        }

        print("\n3. 点与矩形换算")
        let probeCG = CGPoint(x: 123.5, y: 456.25)
        let asNS = ScreenGeometry.nsPoint(fromCG: probeCG, primaryHeight: height)
        let roundTrip = ScreenGeometry.cgPoint(fromNS: asNS, primaryHeight: height)
        check(
            "点 CG→NS→CG 往返一致",
            abs(roundTrip.x - probeCG.x) < 0.001 && abs(roundTrip.y - probeCG.y) < 0.001,
            "\(probeCG) → \(roundTrip)"
        )

        let reversed = CGRect(
            corner: CGPoint(x: 100, y: 100),
            corner: CGPoint(x: 50, y: 40)
        )
        check(
            "反向拖拽得到规范矩形",
            nearlyEqual(reversed, CGRect(x: 50, y: 40, width: 50, height: 60)),
            "\(reversed)"
        )

        print("\n4. 系统能力")
        let hasPermission = ScreenCaptureService.hasPermission()
        check(
            "屏幕录制权限",
            hasPermission,
            hasPermission ? "已授予" : "未授予 —— 此时截图会拿到空桌面图"
        )

        if hasPermission {
            let windows = WindowEnumerator.onScreenWindows(
                excludingPID: ProcessInfo.processInfo.processIdentifier
            )
            check("能枚举屏幕窗口", !windows.isEmpty, "\(windows.count) 个")
            check("枚举结果全部在普通窗口层", windows.allSatisfy { $0.layer == 0 })
            check("枚举结果全部有有效 bounds", windows.allSatisfy { $0.bounds.width > 0 })
        } else {
            print("  [跳过] 窗口枚举需要屏幕录制权限")
        }

        // 辅助功能只影响长截图，未授权不算失败
        let axTrusted = LongShotService.hasAccessibility()
        print("  [提示] 辅助功能权限（长截图用）：\(axTrusted ? "已授予" : "未授予")")

        print("\n合计 \(total) 项，失败 \(failures) 项。")
        return failures == 0 ? 0 : 1
    }
}
