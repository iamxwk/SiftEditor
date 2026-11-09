import AppKit

/// 并排显示两个源文件之间差异的窗格。
///
/// 遵循大文件的惯例：**仅组装可见行**。
/// 差异工具 (`DiffModel`) 不会将线条实体化，而是将屏幕上并排显示的数十条线条组合在一起。
/// 即使  / diff 有 8600 万行，渲染端也只有一个屏幕只有 `NSAttributedString`。
///
/// 只读。不提供编辑、搜索和跟踪功能（这些功能由 `DocumentPane` 的默认实现）。
final class DiffViewer: NSView, DocumentPane {

    // MARK: - DocumentPane

    /// diff 不属于任何特定文件（有两个文件，一个在左侧，一个在右侧）。请使用 `displayTitle` 作为侧边栏名称。
    var fileURL: URL? { nil }
    var onStateChange: ((ViewerState) -> Void)?
    var onSearchState: ((Int, Int, Bool, Int, Bool, Bool) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onDirtyChange: ((Bool) -> Void)?

    var supportsSearch: Bool { false }
    var supportsFollow: Bool { false }
    var supportsStructured: Bool { false }
    var canPrint: Bool { false }
    func printDocument() {}

    /// 要在侧边栏和标题中显示的名称。
    private(set) var displayTitle: String = "Diff"

    // MARK: - 中身

    private let leftView = DocumentView()
    private let rightView = DocumentView()
    private let scroller = DiffScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
    private let header = NSView()
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let gutter = MergeGutter()

    private var left: DiffSource?
    private var right: DiffSource?
    private var model: DiffModel?

    /// 如何禁用“比较格式”。**空 = 普通比较，也会查看值。**
    private var formatMask: FormatMask = []
    /// 您是否按形状进行比较？（用于菜单检查和摘要标题）
    var isFormatCompare: Bool { !formatMask.isEmpty }
    /// 它们可以合并吗？**按形状比较时无法合并**——形状相同，但内容不同。
    /// 取下其中一侧会擦除内容。保持此开口打开会造成数据悄然损坏。
    var canMerge: Bool { !isFormatCompare }

    private var topRow = 0
    private var scrollAccumulator: CGFloat = 0
    private let scrollerWidth: CGFloat = 16
    private let headerHeight: CGFloat = 28

    /// 行内差异缓存（仅限可见行；滚动时丢弃）。
    private var charDiffCache: [Int: (left: [Range<Int>], right: [Range<Int>])] = [:]

    // MARK: - 选择（仅限单列选择。跨越左右两列的选择无效。）

    private enum Side { case left, right }
    /// 选择的起始点和结束点。使用显示行（绝对值）和行内偏移量 UTF-16。
    private var selSide: Side?
    private var selAnchor: (row: Int, idx: Int)?
    private var selFocus: (row: Int, idx: Int)?

    // MARK: - 合并（左侧为基地。只有被选中的汉克才能占据右侧。）

    /// 应用代码块（`DiffModel.ops` 上方的下标）。箭头 (→) = 将左侧内容向右移动。
    /// 如果为空，“请将其放在右侧”。
    private var adopted: Set<Int> = []
    /// 您当前选择的 Hank（您可以使用 ⌥→ 接受/取消的 Hank）。
    private var currentHunkOp: Int?

    /// 使用的线条带（左：“消失/替换”，右：“输入”）。
    private var adoptedBG: NSColor { NSColor.systemBlue.withAlphaComponent(0.35) }
    /// 在尚未被录用的汉克斯家族成员中，这是我目前正在挑选的一位。
    private var currentHunkBG: NSColor { NSColor.systemTeal.withAlphaComponent(0.10) }

    private func view(_ side: Side) -> DocumentView { side == .left ? leftView : rightView }
    private func source(_ side: Side) -> DiffSource? { side == .left ? left : right }

    /// 该行和该列中出现的字符串（如果该行仅存在于另一侧，则为空）。
    private func text(_ side: Side, row: Int) -> String {
        guard let model, let r = model.row(at: row), let src = source(side) else { return "" }
        let line = side == .left ? r.left : r.right
        return line.map { src.line(at: $0) } ?? ""
    }

    // MARK: - 颜色（与主题背景相匹配。调整密度，使其在浅色和深色环境下均清晰可读。）

    private var addBG: NSColor { NSColor.systemGreen.withAlphaComponent(0.16) }
    private var delBG: NSColor { NSColor.systemRed.withAlphaComponent(0.16) }
    private var modBG: NSColor { NSColor.systemYellow.withAlphaComponent(0.14) }
    /// 无行侧（待填充空白侧）。浅灰色表示没有内容。
    private var fillerBG: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.07) }
    /// 行内实际发生变化的字符。颜色比色带更深。
    private var addInline: NSColor { NSColor.systemGreen.withAlphaComponent(0.38) }
    private var delInline: NSColor { NSColor.systemRed.withAlphaComponent(0.38) }

    // MARK: - 组件

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let theme = EditorTheme.current()

        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chromeBackground.cgColor
        addSubview(header)
        for (label, align) in [(leftLabel, NSTextAlignment.left), (rightLabel, .left)] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = theme.chromeText
            label.alignment = align
            header.addSubview(label)
        }
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = theme.chromeSecondaryText
        summary.alignment = .right
        header.addSubview(summary)

        gutter.onToggle = { [weak self] op in self?.toggleHunk(op) }
        addSubview(gutter)

        for (v, side) in [(leftView, Side.left), (rightView, Side.right)] {
            // 防止文本溢出到相邻列（包括不换行的长行和背景填充）。
            v.clipsToBounds = true
            v.onScrollWheel = { [weak self] in self?.handleScrollWheel($0) }
            v.onKeyDown = { [weak self] in self?.handleKeyDown($0) }
            v.onMouseDown = { [weak self] in self?.beginSelection(side, $0) }
            v.onMouseDragged = { [weak self] in self?.extendSelection(side, $0) }
            v.onCopy = { [weak self] in self?.copySelection() }
            v.onSelectAll = { [weak self] in self?.selectAll(side) }
            addSubview(v)
        }

        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrollerAction(_:))
        addSubview(scroller)

        applyCurrentFontSize()
        applyDisplaySettings()
    }

    // MARK: - 入口

    /// 开始比较（**从主线程调用**）。准备源数据并在后台运行 diff 的计算。
    /// 完成后，在主屏幕上绘制。由于索引然后使用 diff 处理两个 10GB 元素需要几十秒时间，
    /// 当我在这里启用同步时，窗口冻结了（实际上我的窗口就冻结了）。
    ///
    /// `makeSources` 在后台线程中被调用。此处，为 mmap 创建了一个索引。
    /// `notReadableMessage` 是 `makeSources` 返回 nil 时显示的消息（默认情况下用于文件）。
    /// 当您想要显示与每个入口点相符的原因时，例如检索  / URL 失败，请替换此内容。
    func beginCompare(title: String,
                      makeSources: @escaping () -> (DiffSource, DiffSource)?,
                      notReadableMessage: String? = nil,
                      onFailure: @escaping (String) -> Void) {
        displayTitle = title
        summary.stringValue = L("diff.comparing")
        let mask = formatMask
        leftLabel.stringValue = ""
        rightLabel.stringValue = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let sources = makeSources() else {
                DispatchQueue.main.async { onFailure(notReadableMessage ?? L("diff.cannotRead")) }
                return
            }
            let (l, r) = sources

            // 索引每行16字节。与浏览不同，它实际占用内存，因此请先检查机器是否能够容纳它。
            guard DiffBudget.fits(leftLines: l.lineCount, rightLines: r.lineCount) else {
                let msg = DiffBudget.describe(leftLines: l.lineCount, rightLines: r.lineCount)
                DispatchQueue.main.async { onFailure(msg) }
                return
            }

            let ops = LineDiff.compute(l.lineHashes(mask: mask), r.lineHashes(mask: mask))
            let m = DiffModel(ops: ops)

            DispatchQueue.main.async {
                guard let self else { return }
                self.left = l
                self.right = r
                self.displayTitle = "\(l.displayName) ↔ \(r.displayName)"
                self.leftLabel.stringValue = l.displayName
                self.rightLabel.stringValue = r.displayName
                self.install(m)
                self.onCompared?()
            }
        }
    }

    /// 在屏幕上显示计算出的 diff 值。**初始比较和模式切换后的重新计算步骤相同。**
    /// （丢弃你选择的汉克——你比较它们的方式会改变，所以是哪个汉克就行了）。
    private func install(_ m: DiffModel) {
        model = m
        charDiffCache.removeAll()
        adopted.removeAll()
        currentHunkOp = m.hunkOpIndices.first
        // 跳转到第一个差异（日志的前几万行相同是正常的）。
        topRow = m.hunkStarts.first.map { max(0, $0 - 3) } ?? 0
        scroller.markers = m.markers().map {
            DiffScroller.Marker(position: $0.position, kind: {
                switch $0.kind {
                case .delete:  return .delete
                case .insert:  return .insert
                default:       return .replace
                }
            }($0))
        }
        refresh()
    }

    // MARK: - 比较格式（按形状比较，而不是按值比较）

    /// 开启或关闭“比较格式”。
    ///
    /// **使用相同的数据源重新计算，仅更改哈希方法** — mmap 和索引不会被重新创建。
    /// 因此，即使使用 10GB，也只需要重新计算哈希值和 diff。这需要几秒钟时间，所以让它在后台运行即可。
    ///
    /// 这与入口点（文件/打开文档/剪贴板/URL）不同，
    /// 即使在菜单中，它也没有被设置为第 5 个入口点，而是被设置为**打开后切换的模式**。
    /// 打开后才发现它无法读取，因为值不同。
    func toggleFormatCompare() {
        setFormatMask(isFormatCompare ? [] : .standard)
    }

    private func setFormatMask(_ mask: FormatMask) {
        guard let l = left, let r = right else { NSSound.beep(); return }
        formatMask = mask
        summary.stringValue = L("diff.comparing")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ops = LineDiff.compute(l.lineHashes(mask: mask), r.lineHashes(mask: mask))
            let m = DiffModel(ops: ops)
            DispatchQueue.main.async {
                guard let self, self.formatMask == mask else { return }   // 舍弃因被快速攻击超越而损失的任何分数。
                self.install(m)
            }
        }
    }

    /// 比较完成后的通知（用于更新侧边栏名称）。
    var onCompared: (() -> Void)?

    @discardableResult func open(url: URL) -> Bool { false }   // diff 窗格由 compare (_:_:) 创建。

    // MARK: - 绘图（仅绘制可见行）

    private var visibleRowCount: Int {
        max(1, Int((bounds.height - headerHeight) / max(1, leftView.lineHeight)))
    }
    private var maxTopRow: Int { max(0, (model?.rowCount ?? 0) - visibleRowCount) }

    private func refresh() {
        guard let model, let left, let right else { return }
        topRow = min(max(0, topRow), maxTopRow)

        let count = min(visibleRowCount, max(0, model.rowCount - topRow))
        var lTexts: [NSAttributedString] = [], rTexts: [NSAttributedString] = []
        var lNums: [Int] = [], rNums: [Int] = []
        var lBGs: [NSColor?] = [], rBGs: [NSColor?] = []
        lTexts.reserveCapacity(count); rTexts.reserveCapacity(count)

        for k in 0..<count {
            let rowIdx = topRow + k
            guard let row = model.row(at: rowIdx) else { break }

            let op = model.opIndex(at: rowIdx)
            let isAdopted = op.map { adopted.contains($0) } ?? false

            // **结果在右侧。** 按下箭头（→）将交换右侧和左侧的内容。
            // 仅记住  标记并在保存时应用的方法不会改变屏幕，并导致“未合并”。
            // 我被告知（实际上是被告知），你看不见的东西就好像不存在一样。
            let lStr = row.left.map { left.line(at: $0) } ?? ""
            var rStr = row.right.map { right.line(at: $0) } ?? ""
            var rStruck = false          // 应用 insert = 从右侧落下的线条（以删除线显示）
            switch row.kind {
            case .replace where isAdopted:
                rStr = lStr                                  // 已替换为左侧内容。
            case .delete where isAdopted:
                rStr = lStr                                  // 原本只在左侧的行已移至右侧。
            case .insert where isAdopted:
                rStruck = true                               // 与左侧对齐并下拉
            default:
                break
            }

            // 行内差异仅包含“已更改的行”。仅计算可见行。
            var lRanges: [Range<Int>] = [], rRanges: [Range<Int>] = []
            if row.kind == .replace, !isAdopted, row.left != nil, row.right != nil {
                if let cached = charDiffCache[rowIdx] {
                    lRanges = cached.left; rRanges = cached.right
                } else {
                    let d = CharDiff.ranges(left: lStr, right: rStr)
                    charDiffCache[rowIdx] = d
                    lRanges = d.left; rRanges = d.right
                }
            }

            lTexts.append(attributed(lStr, inline: lRanges, color: delInline))
            rTexts.append(attributed(rStr, inline: rRanges, color: addInline, struck: rStruck))
            lNums.append(row.left ?? DocumentView.noLineNumber)
            rNums.append(row.right ?? DocumentView.noLineNumber)

            let isCurrent = op != nil && op == currentHunkOp

            switch row.kind {
            case .equal:
                lBGs.append(nil); rBGs.append(nil)
            case .delete:
                // 应用 = 将仅位于左侧的行移动到右侧（填充右侧的空白）。
                lBGs.append(delBG)
                rBGs.append(isAdopted ? adoptedBG : fillerBG)
            case .insert:
                // 应用 = 删除仅存在于右侧的行（与左侧对齐）。
                lBGs.append(fillerBG)
                rBGs.append(isAdopted ? adoptedBG : addBG)
            case .replace:
                lBGs.append(row.left == nil ? fillerBG : (isAdopted ? adoptedBG : modBG))
                rBGs.append(row.right == nil ? fillerBG : (isAdopted ? adoptedBG : modBG))
            }
            // 被选中的汉克被巧妙地分层处理，即使他没有被使用，也能看到他。
            if isCurrent, !isAdopted, row.kind != .equal {
                if lBGs[k] == nil { lBGs[k] = currentHunkBG }
                if rBGs[k] == nil { rBGs[k] = currentHunkBG }
            }
        }

        leftView.lines = lTexts;   rightView.lines = rTexts
        leftView.lineNumbers = lNums; rightView.lineNumbers = rNums
        leftView.rowBackgrounds = lBGs; rightView.rowBackgrounds = rBGs
        let visible = topRow..<(topRow + count)
        leftView.selectionByRow = selectionRows(.left, visible: visible)
        rightView.selectionByRow = selectionRows(.right, visible: visible)

        // 合并区域：仅在 Hank 的文本的**第一行**显示箭头。
        var gutterRows: [MergeGutter.Row] = []
        gutterRows.reserveCapacity(count)
        var lastOp: Int? = topRow > 0 ? model.opIndex(at: topRow - 1) : nil
        for k in 0..<count {
            let rowIdx = topRow + k
            let op = model.opIndex(at: rowIdx)
            let isDiff = op.map { if case .equal = model.ops[$0] { return false } else { return true } } ?? false
            let isHead = isDiff && op != lastOp
            gutterRows.append(MergeGutter.Row(
                // 按形状比较时无法合并，因此不会显示可点击区域或箭头。
                hunkOp: (canMerge && isDiff) ? op : nil,   // 可以按在 Hank 代码的每一行上（如果只按在第一行上则不会起作用）。
                isHead: canMerge && isHead,                // 箭头只能画在第一行。
                adopted: op.map { adopted.contains($0) } ?? false,
                current: op != nil && op == currentHunkOp))
            lastOp = op
        }
        gutter.rows = gutterRows
        gutter.lineHeight = leftView.lineHeight
        gutter.window?.invalidateCursorRects(for: gutter)
        updateSummary()
        leftView.needsDisplay = true; rightView.needsDisplay = true

        // 缓存只保留可见内容（因此即使无限滚动也不会变得臃肿）。
        if charDiffCache.count > 2_000 {
            let keep = topRow..<(topRow + count)
            charDiffCache = charDiffCache.filter { keep.contains($0.key) }
        }

        updateScroller()
        emitState()
    }

    /// 仅以深色高亮显示特殊字符的行。`struck` 是已从结果中删除的行（已删除线）。
    private func attributed(_ s: String, inline: [Range<Int>], color: NSColor,
                            struck: Bool = false) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: s, attributes: leftView.textAttributes)
        if struck {
            attr.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .strikethroughColor: NSColor.systemRed],
                               range: NSRange(location: 0, length: attr.length))
        }
        guard !inline.isEmpty else { return attr }
        let chars = Array(s)
        for r in inline {
            guard r.lowerBound >= 0, r.upperBound <= chars.count, r.lowerBound < r.upperBound else { continue }
            // Character 单位范围 → UTF-16 范围（不要拆分表情符号）。
            let pre = String(chars[0..<r.lowerBound]).utf16.count
            let len = String(chars[r.lowerBound..<r.upperBound]).utf16.count
            let ns = NSRange(location: pre, length: len)
            if ns.location + ns.length <= attr.length {
                attr.addAttribute(.backgroundColor, value: color, range: ns)
            }
        }
        return attr
    }

    /// 标题摘要。**显示申请数量** -- 根据颜色主题，如果仅使用行颜色，则可能不易察觉。
    private func updateSummary() {
        guard let model else { return }
        let base = statusLabel(for: model)
        summary.stringValue = adopted.isEmpty ? base : base + " ／ " + L("diff.adopted", adopted.count)
    }

    /// 摘要文本。**按表单比较时，将调用该函数** -- 如果仅显示“无差异”，
    /// 如果值匹配，可能会被误解。
    private func statusLabel(for model: DiffModel) -> String {
        let base = model.isIdentical
            ? (isFormatCompare ? L("diff.formatIdentical") : L("diff.identical"))
            : L("diff.summary", model.hunkStarts.count, model.changedRowCount)
        return isFormatCompare ? L("diff.formatMode") + "：" + base : base
    }

    private func emitState() {
        guard let model else { return }
        // 文件大小字段在 diff 中没有意义（有两个字段，一个在左侧，一个在右侧）。显示差异摘要。
        let label = statusLabel(for: model)
        onStateChange?(ViewerState(encodingName: label,
                                   lineCount: model.rowCount,
                                   lineCountIsExact: true,
                                   fileSize: 0,
                                   indexProgress: 1.0))
    }

    // MARK: - 选择并复制

    /// 从单击的列开始选择。放弃另一列中的选择。
    ///（在“并排比较”屏幕中，跨越左右两侧的选择没有意义）。
    private func beginSelection(_ side: Side, _ event: NSEvent) {
        let v = view(side)
        let p = v.convert(event.locationInWindow, from: nil)
        guard let hit = v.index(at: p) else { return }
        let row = topRow + hit.row
        if event.modifierFlags.contains(.shift), selSide == side, selAnchor != nil {
            selFocus = (row, hit.utf16Index)          // Shift + 点击扩展范围
        } else {
            selSide = side
            selAnchor = (row, hit.utf16Index)
            selFocus = (row, hit.utf16Index)
            selectHunk(at: row)                       // 选择点击的差异进行采用。
        }
        window?.makeFirstResponder(v)
        refresh()
    }

    private func extendSelection(_ side: Side, _ event: NSEvent) {
        guard selSide == side else { return }
        let v = view(side)
        let p = v.convert(event.locationInWindow, from: nil)
        guard let hit = v.index(at: p) else { return }
        selFocus = (topRow + hit.row, hit.utf16Index)
        refresh()
    }

    /// 选择该列中的所有行。即使是大型文件，选择本身也只定义了一个范围，因此开销很小。
    /// （复制时首次读取该行）。
    private func selectAll(_ side: Side) {
        guard let model, model.rowCount > 0 else { return }
        selSide = side
        selAnchor = (0, 0)
        let last = model.rowCount - 1
        selFocus = (last, text(side, row: last).utf16.count)
        refresh()
    }

    /// 选择归一化（起点≤终点）。
    private func normalizedSelection() -> (start: (row: Int, idx: Int), end: (row: Int, idx: Int))? {
        guard let a = selAnchor, let f = selFocus else { return nil }
        if a.row < f.row || (a.row == f.row && a.idx <= f.idx) { return (a, f) }
        return (f, a)
    }

    /// 将选定的文本复制到剪贴板。跳过仅存在于另一侧的行（空白行）。
    /// -- 如果您复制不存在的行并混入空白行，则粘贴位置的值将变为 false。
    private func copySelection() {
        guard let side = selSide, let model, let sel = normalizedSelection() else { NSSound.beep(); return }
        let text = model.selectedText(from: sel.start, to: sel.end) { [weak self] row in
            guard let self, let r = model.row(at: row) else { return nil }
            let exists = (side == .left) ? r.left != nil : r.right != nil
            return exists ? self.text(side, row: row) : nil    // 填充行是 nil = 跳过
        }
        guard !text.isEmpty else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 创建可见行的选择高亮显示（传递给 DocumentView）。
    private func selectionRows(_ side: Side, visible: Range<Int>) -> [Int: DocumentView.RowSelection] {
        guard selSide == side, let sel = normalizedSelection() else { return [:] }
        var out: [Int: DocumentView.RowSelection] = [:]
        for row in visible where row >= sel.start.row && row <= sel.end.row {
            let u = text(side, row: row).utf16.count
            let from = (row == sel.start.row) ? min(sel.start.idx, u) : 0
            let to   = (row == sel.end.row)   ? min(sel.end.idx, u)   : u
            guard from <= to else { continue }
            out[row - visible.lowerBound] = DocumentView.RowSelection(
                range: NSRange(location: from, length: to - from),
                extendsToLineEnd: row < sel.end.row)     // 跨越多行的选择将带区延伸至行尾。
        }
        return out
    }

    // MARK: - 差异之间的移动

    /// 下一个差异。将目标设置为“选定的 Hank”（成为 ⌥→ 的目标）。
    func nextHunk() { goToHunk(model?.hunk(after: currentHunkOp)) }
    /// 上一个差异。
    func previousHunk() { goToHunk(model?.hunk(before: currentHunkOp)) }

    private func goToHunk(_ op: Int?) {
        guard let model, let op else { NSSound.beep(); return }
        currentHunkOp = op
        let row = model.startRow(ofOp: op)
        // 如果图片不在屏幕上，请将其移近。如果图片在屏幕上，请不要滚动（以免视线跳动）。
        if row < topRow || row >= topRow + visibleRowCount - 1 {
            topRow = max(0, row - 3)
        }
        refresh()
    }

    // MARK: - 合并

    /// 是否已选择 Hunk（菜单激活）？
    var hasCurrentHunk: Bool { currentHunkOp != nil }
    /// 是否有已被采纳（已启用“合并并保存”）的代码块？
    var hasAdoptedHunks: Bool { !adopted.isEmpty }

    /// 选择 Hank 并采用右侧的内容（左侧是基础内容）。
    func adoptCurrentHunk() {
        guard canMerge, let op = currentHunkOp else { NSSound.beep(); return }
        adopted.insert(op)
        refresh()
    }

    /// 取消招聘（返回左侧位置）。
    func revertCurrentHunk() {
        guard canMerge, let op = currentHunkOp else { NSSound.beep(); return }
        adopted.remove(op)
        refresh()
    }

    /// 按下箭头时：如果尚未采用，则采用；如果已采用，则取消。
    private func toggleHunk(_ op: Int) {
        guard canMerge else { NSSound.beep(); return }
        currentHunkOp = op
        if adopted.contains(op) { adopted.remove(op) } else { adopted.insert(op) }
        refresh()
    }

    /// 将单击的 Hank 设置为“选定的 Hank”。
    private func selectHunk(at row: Int) {
        guard let model, let op = model.opIndex(at: row) else { return }
        if case .equal = model.ops[op] { return }     // 请勿选择非差异行。
        currentHunkOp = op
    }

    /// 将合并结果另存为其他名称。**请勿修改原始的两个文件。**
    ///
    /// 主文本未加载到内存中，字节流从左右源按 ops（10GB 也有效）流式传输。
    func saveMerged() {
        guard canMerge, let model, let left, let right else { NSSound.beep(); return }

        let panel = NSSavePanel()
        panel.message = L("diff.saveMergedMessage")
        panel.prompt = L("diff.saveMerged")
        panel.nameFieldStringValue = mergedFileName()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let adoptedNow = adopted
        let eol: [UInt8] = [0x0A]        // 输出为 LF。请勿混淆。

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            try model.writeMerged(left: left, right: right, applied: adoptedNow, eol: eol, to: out)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("diff.saveFailed")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        onMergedSaved?(url)
    }

    /// 合并结果保存时发出通知（打开并查看）。
    var onMergedSaved: ((URL) -> Void)?

    /// 创建一个名为“原始文件名-merged.扩展名”的文件。
    private func mergedFileName() -> String {
        let base = right?.displayName ?? "merged.txt"
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-merged" : "\(stem)-merged.\(ext)"
    }

    /// 保持左右列水平位置相同。
    private func setHorizontalOffset(_ x: CGFloat) {
        leftView.setHorizontalOffset(x)
        rightView.setHorizontalOffset(leftView.horizontalOffset)   // 钳位后对齐值。
    }

    private func handleKeyDown(_ event: NSEvent) {
        let step = leftView.lineHeight * 4
        // ⌥→ 选择正确选项，⌥← 撤销（合并）。不按 ⌥ 表示水平滚动。
        if event.modifierFlags.contains(.option) {
            switch event.keyCode {
            case 124: adoptCurrentHunk(); return      // ⌥→
            case 123: revertCurrentHunk(); return     // ⌥←
            default: break
            }
        }
        switch event.keyCode {
        case 123: setHorizontalOffset(leftView.horizontalOffset - step); return   // ←
        case 124: setHorizontalOffset(leftView.horizontalOffset + step); return   // →
        default: break
        }
        switch event.keyCode {
        case 125: topRow += 1; refresh()                       // ↓
        case 126: topRow -= 1; refresh()                       // ↑
        case 121: topRow += visibleRowCount - 1; refresh()     // PageDown
        case 116: topRow -= visibleRowCount - 1; refresh()     // PageUp
        case 115: topRow = 0; refresh()                        // Home
        case 119: topRow = maxTopRow; refresh()                // End
        default: break
        }
    }

    private func handleScrollWheel(_ event: NSEvent) {
        // 将水平部件并排移动，保持两侧对齐。如果只有一侧未对齐，“并排比较”功能将无法正常工作。
        if event.scrollingDeltaX != 0 {
            setHorizontalOffset(leftView.horizontalOffset - event.scrollingDeltaX)
        }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= leftView.lineHeight }
        scrollAccumulator += delta
        let lines = Int(scrollAccumulator / leftView.lineHeight)
        if lines != 0 {
            scrollAccumulator -= CGFloat(lines) * leftView.lineHeight
            topRow -= lines
            refresh()
        }
    }

    @objc private func scrollerAction(_ sender: NSScroller) {
        let page = max(1, visibleRowCount - 1)
        switch sender.hitPart {
        case .knob, .knobSlot: topRow = Int(Double(maxTopRow) * sender.doubleValue)
        case .decrementPage: topRow -= page
        case .incrementPage: topRow += page
        case .decrementLine: topRow -= 1
        case .incrementLine: topRow += 1
        default: break
        }
        refresh()
    }

    private func updateScroller() {
        let total = model?.rowCount ?? 0
        scroller.isEnabled = total > visibleRowCount
        scroller.knobProportion = total > 0 ? CGFloat(visibleRowCount) / CGFloat(total) : 1
        scroller.doubleValue = maxTopRow > 0 ? Double(topRow) / Double(maxTopRow) : 0
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: h - headerHeight, width: w, height: headerHeight)
        let gutterW: CGFloat = 30
        let colW = max(0, (w - scrollerWidth - gutterW) / 2)
        leftLabel.frame = NSRect(x: 10, y: 5, width: colW - 20, height: 18)
        rightLabel.frame = NSRect(x: colW + 40, y: 5, width: max(0, colW - 160), height: 18)
        summary.frame = NSRect(x: w - scrollerWidth - 240, y: 5, width: 230, height: 18)

        let bodyH = max(0, h - headerHeight)
        leftView.frame = NSRect(x: 0, y: 0, width: colW, height: bodyH)
        gutter.frame = NSRect(x: colW, y: 0, width: gutterW, height: bodyH)
        rightView.frame = NSRect(x: colW + gutterW, y: 0, width: colW, height: bodyH)
        scroller.frame = NSRect(x: w - scrollerWidth, y: 0, width: scrollerWidth, height: bodyH)
        refresh()
    }

    // MARK: - 剩余 DocumentPane

    func reEmitState() { emitState() }
    func focusContent() { window?.makeFirstResponder(leftView) }
    func ensureVisibleLayout() { refresh() }

    func applyCurrentFontSize() {
        for v in [leftView, rightView] { v.configure(font: EditorFont.current()) }
        needsLayout = true
        refresh()
    }
    func applyLineWrap() {
        // diff 的设计初衷是左右行对齐查看。文本换行会导致行垂直偏移，破坏原有的对应关系。
        // 自动换行始终禁用（通过水平滚动查看）。
        for v in [leftView, rightView] { v.wrapEnabled = false }
        refresh()
    }
    func applyDisplaySettings() {
        for v in [leftView, rightView] {
            v.highlightCurrentLine = false      // diff 和乐队正在打架。
            v.cursorShape = AppSettings.cursorShape
            v.showLineNumbers = AppSettings.showLineNumbers
            v.showInvisibles = AppSettings.showInvisibles
            v.configure(font: EditorFont.current())   // 整合制表符宽度、行间距和配色方案。
        }
        refresh()
    }
}
