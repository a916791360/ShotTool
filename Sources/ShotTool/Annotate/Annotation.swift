import AppKit

/// 标注类型。V0.2 先落四个核心工具，其余按计划排在后面。
enum AnnotationKind: String, CaseIterable {
    case rectangle
    case ellipse
    case arrow
    case text
    // 后续：freehand(画笔)、mosaic(马赛克)、number(序号)、crop(裁剪)

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse:   return "椭圆"
        case .arrow:     return "箭头"
        case .text:      return "文字"
        }
    }

    /// 工具条上的占位字符（先用系统符号，后面换自绘图标）
    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .text:      return "textformat"
        }
    }
}

/// 标注的语义类型。
///
/// 第一阶段界面上**不显示**，只是把字段先埋进数据结构。
/// 第二阶段做「评审模式」时，同一个标注就能直接变成一条可导出的需求条目，
/// 那时候不用改模型、不用迁移数据。
enum AnnotationSemantic: String, CaseIterable {
    case changeText   // 改文案
    case bug          // 有问题
    case add          // 新增
    case question     // 疑问
    case remove       // 删除
}

struct AnnotationStyle {
    var color: NSColor
    /// 单位：图像像素（不是屏幕 pt），这样导出后线宽才不随缩放变化
    var lineWidth: CGFloat
    /// 单位：图像像素
    var fontSize: CGFloat

    static let `default` = AnnotationStyle(
        color: .systemRed,
        lineWidth: 4,
        fontSize: 28
    )
}

/// 一条标注。
///
/// 坐标系约定：`start` / `end` / `points` 都是**选区内像素坐标**（原点在选区左上角，y 向下）。
/// 用像素而不是 pt 的原因：导出时直接对应图像像素，换屏幕、换倍率都不用重算。
struct Annotation: Identifiable {
    let id: UUID
    var kind: AnnotationKind
    var start: CGPoint
    var end: CGPoint
    var text: String?
    var style: AnnotationStyle
    /// ★ 预留：语义标签，第一阶段不显示
    var semantic: AnnotationSemantic?
    /// ★ 预留：一句话说明
    var note: String?

    init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        start: CGPoint,
        end: CGPoint,
        text: String? = nil,
        style: AnnotationStyle = .default,
        semantic: AnnotationSemantic? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.text = text
        self.style = style
        self.semantic = semantic
        self.note = note
    }

    /// 规范化的包围盒（像素坐标）
    var boundingBox: CGRect {
        switch kind {
        case .arrow:
            return CGRect(corner: start, corner: end)
        case .text:
            let size = AnnotationRenderer.measureText(text ?? "", style: style)
            return CGRect(origin: start, size: size)
        default:
            return CGRect(corner: start, corner: end)
        }
    }

    /// 拖动整体移动
    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx
        start.y += dy
        end.x += dx
        end.y += dy
    }

    /// 拖右下角缩放
    mutating func resize(to point: CGPoint) {
        end = point
    }
}

/// 标注集合 + 撤销栈。
///
/// 撤销用「整个数组快照」而不是命令差分：一条标注就是个几十字节的 struct，
/// 几十条标注的快照也就几 KB，比维护命令栈可靠得多，也不会出现撤销后状态不一致。
/// 注意：快照的是**标注数据**，不是图片，和计划里「不存整图快照」并不冲突。
final class AnnotationStore {

    private(set) var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    private(set) var selectedID: UUID?

    var isEmpty: Bool { items.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private let maxHistory = 60

    private func snapshot() {
        undoStack.append(items)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func add(_ annotation: Annotation) {
        snapshot()
        items.append(annotation)
        selectedID = annotation.id
    }

    func replace(_ annotation: Annotation) {
        guard let index = items.firstIndex(where: { $0.id == annotation.id }) else { return }
        items[index] = annotation
    }

    /// 连续拖拽时只记录一次快照
    func beginInteraction() {
        snapshot()
    }

    func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        snapshot()
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        remove(id: id)
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        selectedID = nil
    }

    /// 命中检测：从最后画的往前找，先找到的就是最上层。
    /// tolerance 单位是像素，热区比图形本身大一圈，小箭头也好点。
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> UUID? {
        for annotation in items.reversed() {
            if hit(annotation, point: point, tolerance: tolerance) {
                return annotation.id
            }
        }
        return nil
    }

    private func hit(_ annotation: Annotation, point: CGPoint, tolerance: CGFloat) -> Bool {
        switch annotation.kind {
        case .rectangle, .ellipse:
            let box = annotation.boundingBox.insetBy(dx: -tolerance, dy: -tolerance)
            return box.contains(point)

        case .arrow:
            // 点到线段距离
            return distanceToSegment(point, annotation.start, annotation.end) <= tolerance + annotation.style.lineWidth

        case .text:
            return annotation.boundingBox.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }

        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - projection.x, p.y - projection.y)
    }
}
