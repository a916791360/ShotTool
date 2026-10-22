import AppKit
import Darwin

/// 启动引导。
/// 单独抽出来是因为 main.swift 的顶层代码在 Swift 5 语言模式下不属于 MainActor，
/// 而 NSApplication / NSWindow 全是主线程限定，直接写会报隔离错误。
@MainActor
enum Bootstrap {

    /// 必须强引用：NSApplication.delegate 不持有 delegate，存成局部变量会被立刻释放。
    private static var delegate: AppDelegate?

    static var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/ShotTool.log"
    }

    /// 从 Finder 启动时没有终端，NSLog 只会进 unified log，用户拿不到。
    /// 这里在没有 TTY 时把 stderr 重定向到固定文件，方便出问题时直接发文件给我。
    /// 从终端启动（有 TTY）保持原样，日志照旧打在终端。
    static func setupFileLogging() {
        // isatty 返回 0 表示不是终端（从 Finder 启动），这时才需要重定向
        guard isatty(STDERR_FILENO) == 0 else { return }

        let dir = (logFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // 超过 2MB 就清空，避免无限增长
        if let size = (try? FileManager.default.attributesOfItem(atPath: logFilePath))?[.size] as? Int,
           size > 2_000_000 {
            try? FileManager.default.removeItem(atPath: logFilePath)
        }

        freopen(logFilePath, "a", stderr)
    }

    static func run() {
        setupFileLogging()

        let application = NSApplication.shared
        let instance = AppDelegate()
        delegate = instance
        application.delegate = instance
        application.setActivationPolicy(.accessory)
        application.run()
    }

    static func runSelfTest() -> Int32 {
        _ = NSApplication.shared
        return SelfTest.run()
    }

    static func runCaptureTest() -> Int32 {
        _ = NSApplication.shared
        return CaptureTest.run()
    }

    static func runAnnotateTest() -> Int32 {
        _ = NSApplication.shared
        return AnnotateTest.run()
    }

    static func runLongShotTest() -> Int32 {
        _ = NSApplication.shared
        return LongShotTest.run()
    }
}

if CommandLine.arguments.contains("--selftest") {
    let code = MainActor.assumeIsolated { Bootstrap.runSelfTest() }
    exit(code)
}

if CommandLine.arguments.contains("--capture-test") {
    let code = MainActor.assumeIsolated { Bootstrap.runCaptureTest() }
    exit(code)
}

if CommandLine.arguments.contains("--annotate-test") {
    let code = MainActor.assumeIsolated { Bootstrap.runAnnotateTest() }
    exit(code)
}

if CommandLine.arguments.contains("--longshot-test") {
    let code = MainActor.assumeIsolated { Bootstrap.runLongShotTest() }
    exit(code)
}

MainActor.assumeIsolated { Bootstrap.run() }
