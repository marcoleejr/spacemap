import AppKit
import SpaceMapCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = SpaceMapViewModel()
    @State private var showHelp = false
    @State private var showReview = false
    @State private var showTrashConfirm = false
    @State private var showFilter = false
    @State private var trashTarget: DiskNode?
    @FocusState private var filterFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            summaryStrip
            if model.fullDiskAccessRestricted || model.fullDiskAccessNewlyGranted {
                fullDiskAccessBanner
            }
            HStack(spacing: 0) {
                rail.frame(width: 208)
                Divider().overlay(Theme.line)
                TreemapCanvas(model: model)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                Divider().overlay(Theme.line)
                inspector.frame(width: 322)
            }
            Divider().overlay(Theme.line)
            commandStrip
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .frame(minWidth: 1120, minHeight: 700)
        .focusable()
        .onKeyPress { keyPress in handle(keyPress) }
        .onAppear { model.startScan() }
        .onChange(of: showFilter) { _, active in
            if active { filterFocused = true }
            else { model.filterText = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceMapRequestTrash)) { _ in requestTrash(model.selectedNode) }
        .sheet(isPresented: $showReview) { reviewSheet }
        .overlay { if showHelp { helpOverlay } }
        .alert(L10n.string("trash.title"), isPresented: $showTrashConfirm, presenting: trashTarget) { node in
            Button(L10n.string("trash.cancel"), role: .cancel) { trashTarget = nil }
            Button(L10n.string("action.trash"), role: .destructive) {
                do {
                    try model.moveToTrash(node)
                    trashTarget = nil
                } catch {
                    model.statusMessage = L10n.format("error.trash_failed", error.localizedDescription)
                    trashTarget = nil
                }
            }
        } message: { node in
            Text("\(node.path)\n\(L10n.format("trash.note", ByteFormatter.string(node.bytes(apparent: model.useApparentSize))))")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                SpaceMark(size: 22)
                Text("SpaceMap")
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.2)
            }
            pathControl
            Spacer(minLength: 8)
            if showFilter { filterField }
            else {
                Button { showFilter = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(ToolbarButtonStyle()).help(L10n.string("filter.placeholder"))
            }
            modeSegment
            Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ToolbarButtonStyle()).help(L10n.string("key.rescan"))
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(Theme.background)
    }

    private var pathControl: some View {
        HStack(spacing: 6) {
            Text("/").foregroundStyle(Theme.secondary.opacity(0.7))
            Button(L10n.string("nav.home")) { model.resetToRoot() }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
            Text("/").foregroundStyle(Theme.secondary.opacity(0.7))
            Menu {
                Button(L10n.string("nav.scan_home")) { model.scanHome() }
                Button(L10n.string("nav.choose_folder")) { chooseFolder() }
            } label: {
                HStack(spacing: 5) {
                    Text(model.rootName).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            ForEach(Array(model.breadcrumbs.dropFirst()), id: \.path) { crumb in
                Text("/").foregroundStyle(Theme.secondary.opacity(0.7))
                Button(crumb.name) { model.focus(at: crumb.path) }
                    .buttonStyle(.plain).foregroundStyle(Theme.text)
                    .lineLimit(1).help(crumb.path)
            }
        }
        .font(.system(size: 13))
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField(L10n.string("filter.placeholder"), text: $model.filterText)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
                .focused($filterFocused)
            Button { showFilter = false; filterFocused = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var modeSegment: some View {
        HStack(spacing: 2) {
            modeButton(.size, icon: "chart.bar")
            modeButton(.files, icon: "doc.stack")
            modeButton(.age, icon: "clock")
        }
        .padding(3)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }

    private func modeButton(_ mode: TreemapMode, icon: String) -> some View {
        Button { model.mode = mode } label: {
            Label(mode.localizedTitle, systemImage: icon)
                .font(.system(size: 12, weight: model.mode == mode ? .semibold : .regular))
                .foregroundStyle(model.mode == mode ? Theme.text : Theme.secondary)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(model.mode == mode ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: model.mode == mode ? .black.opacity(scheme == .dark ? 0.35 : 0.12) : .clear, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
    }

    // MARK: - Summary strip

    private var summaryStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.isScanning ? Theme.accent : Theme.category(.toolchains))
                    .frame(width: 8, height: 8)
                Text(summary)
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.isScanning, let current = model.metrics.currentPath {
                    Text(abbreviatedPath(current))
                        .font(.system(size: 11.5).monospaced()).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 360, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
        .background(Theme.background)
    }

    private var summary: String {
        guard let root = model.scanRoot else {
            return model.isScanning ? "\(L10n.string("summary.scanning"))…" : L10n.string("summary.empty")
        }
        let size = ByteFormatter.string(root.bytes(apparent: model.useApparentSize), precision: 0)
        let base = "\(size) · \(L10n.filesCompact(compact(root.fileCount), count: root.fileCount)) · \(L10n.dirsCompact(compact(root.directoryCount), count: root.directoryCount))"
        return model.isScanning ? "\(L10n.string("summary.scanning")) · \(base)" : base
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                railGroup(L10n.string("rail.display")) {
                    Toggle(L10n.string("toggle.hidden"), isOn: $model.includeHiddenFiles)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                        .onChange(of: model.includeHiddenFiles) { _, _ in model.startScan() }
                    Toggle(L10n.string("toggle.apparent"), isOn: $model.useApparentSize)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    HStack {
                        Text(L10n.format("depth.label", model.depth)).font(.system(size: 12)).monospacedDigit()
                        Spacer()
                        Stepper("", value: $model.depth, in: 1...8).labelsHidden()
                    }
                }
                railGroup(L10n.string("rail.legend")) {
                    legendRow(.reclaimable, hatched: true)
                    ForEach([DiskCategory.code, .agentScratch, .toolchains, .synced, .git, .media, .documents, .cache], id: \.self) { category in
                        legendRow(category)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
    }

    private func railGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func railRow(icon: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 18)
                    .foregroundStyle(active ? Theme.accent : Theme.secondary)
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(active ? Theme.text : Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(active ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func modeIcon(_ mode: TreemapMode) -> String {
        switch mode {
        case .size: "chart.bar"
        case .files: "doc.stack"
        case .age: "clock"
        }
    }

    private func legendRow(_ category: DiskCategory, hatched: Bool = false) -> some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Theme.category(category).opacity(0.9))
                if hatched {
                    Canvas { context, size in
                        var path = Path()
                        for start in stride(from: -size.height, through: size.width, by: 4) {
                            path.move(to: CGPoint(x: start, y: size.height))
                            path.addLine(to: CGPoint(x: start + size.height, y: 0))
                        }
                        context.stroke(path, with: .color(.white.opacity(0.65)), lineWidth: 0.8)
                    }
                }
            }
            .frame(width: 13, height: 13)
            Text(category.localizedTitle).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 2)
            if let bytes = model.categoryFootprint[category], bytes > 0 {
                Text(ByteFormatter.string(bytes, precision: 0))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: - FDA banner

    private var fullDiskAccessBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
            Text(L10n.string(model.fullDiskAccessRestricted ? "fda.message" : "fda.granted")).font(.system(size: 11.5)).foregroundStyle(Theme.text)
            Spacer()
            if model.fullDiskAccessRestricted {
                Button(L10n.string("fda.action")) { openFullDiskAccessSettings() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            } else {
                Button(L10n.string("fda.rescan")) { model.startScan() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.accent.opacity(scheme == .dark ? 0.12 : 0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1) }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                inspectorCard(L10n.string("section.selection")) { selectionBody }
                inspectorCard(L10n.string("section.worth"), trailing: worthTotal) { worthBody }
                inspectorCard(L10n.string("section.disk"), trailing: Text(model.volumeDetails().name).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).frame(maxWidth: 120, alignment: .trailing)) { diskBody }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .background(Theme.surface)
    }

    private func inspectorCard<Content: View, Trailing: View>(_ title: String, trailing: Trailing, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Spacer()
                trailing
            }
            content()
        }
        .padding(14)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.line, lineWidth: 1))
    }

    private func inspectorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        inspectorCard(title, trailing: EmptyView(), content: content)
    }

    @ViewBuilder
    private var selectionBody: some View {
        if let node = model.selectedNode {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.category(node.colorCategory)).frame(width: 5, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(node.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if model.isMarked(node) { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent) }
                    }
                    Text(pathForDisplay(node.path))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            let parts = ByteFormatter.valueAndUnit(node.bytes(apparent: model.useApparentSize), precision: 1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parts.value).font(.system(size: 40, weight: .semibold).monospacedDigit()).tracking(-0.8)
                Text(parts.unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 2)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised)
                    Capsule().fill(Theme.accent).frame(width: geometry.size.width * selectedShare(node))
                }
            }
            .frame(height: 6)
            statGrid(node: node)
            HStack(spacing: 8) {
                Button { model.revealInFinder(node) } label: {
                    Label(L10n.string("action.reveal"), systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle())
                Button(role: .destructive) { requestTrash(node) } label: {
                    Label(L10n.string("action.trash"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CardButtonStyle(destructive: true))
            }
            .padding(.top, 2)
        } else {
            Text(L10n.string("sel.empty")).font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.vertical, 8)
        }
        if let error = model.statusMessage {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger).padding(.top, 4)
        }
    }

    private func statGrid(node: DiskNode) -> some View {
        VStack(spacing: 7) {
            statRow(L10n.string("sel.of_scan"), percent(node))
            statRow(L10n.string("sel.files"), compact(node.fileCount))
            statRow(L10n.string("sel.last_write"), L10n.age(from: node.modifiedAt))
            statRow(L10n.string("sel.kind"), node.category.localizedTitle)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.85).multilineTextAlignment(.trailing)
        }
    }

    private var worthTotal: some View {
        Text(model.isScanning && model.cleanupCandidates.isEmpty ? "…" : ByteFormatter.string(model.cleanupTotalBytes, precision: 0))
            .font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.accent)
    }

    @ViewBuilder
    private var worthBody: some View {
        if model.cleanupCandidates.isEmpty {
            Text(model.isScanning ? L10n.string("worth.finding") : L10n.string("worth.empty"))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.vertical, 4)
        } else {
            VStack(spacing: 8) {
                ForEach(model.cleanupCandidates) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        Button {
            model.select(candidate.node)
            if candidate.node.isDirectory { model.zoomTo(candidate.node) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.category(candidate.node.colorCategory)).frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.node.path == model.rootURL.path ? candidate.node.name : relativePath(candidate.node.path))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(L10n.candidateSubtitle(candidate)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(ByteFormatter.string(candidate.bytes, precision: 0))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.raised)
                        Capsule().fill(Theme.category(candidate.node.colorCategory).opacity(0.85))
                            .frame(width: geometry.size.width * min(1, CGFloat(candidate.bytes) / CGFloat(max(1, model.cleanupCandidates.first?.bytes ?? 1))))
                    }
                }
                .frame(height: 4)
            }
            .padding(9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var diskBody: some View {
        let volume = model.volumeDetails()
        let free = volume.free ?? 0
        let total = volume.total ?? 0
        let used = total > free ? total - free : 0
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(ByteFormatter.valueAndUnit(free).value)
                .font(.system(size: 32, weight: .semibold).monospacedDigit()).tracking(-0.5)
            Text(L10n.format("disk.free", ByteFormatter.valueAndUnit(free).unit))
                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(Theme.secondary)
                    .frame(width: total > 0 ? geometry.size.width * min(1, CGFloat(used) / CGFloat(total)) : 0)
            }
        }
        .frame(height: 7)
        HStack {
            Text(L10n.format("disk.used", ByteFormatter.string(used, precision: 0)))
            Spacer()
            Text(L10n.format("disk.total", ByteFormatter.string(total, precision: 0)))
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
    }

    // MARK: - Command strip

    private var commandStrip: some View {
        HStack(spacing: 13) {
            keyHint("space", "key.mark")
            keyHint("enter", "key.open")
            keyHint("⌫", "key.up")
            keyHint("c", "key.review")
            keyHint("hjkl", "key.move")
            keyHint("/", "key.filter")
            keyHint("[ ]", "key.depth")
            keyHint("t", "key.mode")
            keyHint("0", "key.reset")
            keyHint("r", "key.rescan")
            Spacer(minLength: 4)
            Button { showHelp = true } label: { keycap("?") }
                .buttonStyle(.plain).help(L10n.string("keys.help_tip"))
            Text(L10n.string("keys.all")).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
            Text(statusSummary).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.secondary)
                .lineLimit(1).frame(maxWidth: 280, alignment: .trailing)
            if model.isScanning {
                Button { model.cancelScan() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.danger).help(L10n.string("keys.cancel_scan"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Theme.surface)
    }

    // MARK: - Review sheet

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("review.title")).font(.system(size: 19, weight: .semibold))
                    Text(L10n.string("review.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(L10n.string("review.done")) { showReview = false }.keyboardShortcut(.defaultAction)
            }
            if model.markedNodes.isEmpty {
                ContentUnavailableView(L10n.string("review.empty_title"), systemImage: "bookmark", description: Text(L10n.string("review.empty_hint")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.markedNodes) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.name).font(.system(size: 13, weight: .medium))
                            Text(node.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(ByteFormatter.string(node.bytes(apparent: model.useApparentSize)))
                            .font(.system(size: 12).monospacedDigit())
                        Button { requestTrash(node) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(Theme.danger).help(L10n.string("review.trash_tip"))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(node); showReview = false }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
        .background(Theme.surface)
    }

    // MARK: - Help overlay

    private var helpOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { showHelp = false }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L10n.string("help.title")).font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button { showHelp = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    helpRow("Space", L10n.string("help.mark"))
                    helpRow("Return", L10n.string("help.open"))
                    helpRow("Delete", L10n.string("help.up"))
                    helpRow("C", L10n.string("help.review"))
                    helpRow("H J K L · arrows", L10n.string("help.move"))
                    helpRow("/", L10n.string("help.filter"))
                    helpRow("[  ]", L10n.string("help.depth"))
                    helpRow("T", L10n.format("help.mode", TreemapMode.size.localizedTitle, TreemapMode.files.localizedTitle, TreemapMode.age.localizedTitle))
                    helpRow("0", L10n.string("help.reset"))
                    helpRow("R", L10n.string("help.rescan"))
                    helpRow("? · Escape", L10n.string("help.dismiss"))
                }
                Text(L10n.string("help.footnote"))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, 3)
            }
            .padding(24)
            .frame(width: 640)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
        }
    }

    private var statusSummary: String {
        let count = compact(model.metrics.entriesScanned)
        let elapsed = String(format: "%.1f", model.metrics.duration)
        if model.isScanning {
            let current = model.metrics.currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.string("status.starting")
            return L10n.format("status.scanning", count as CVarArg, elapsed as CVarArg, current as CVarArg)
        }
        return L10n.format("status.done", count as CVarArg, elapsed as CVarArg)
    }

    private func handle(_ key: KeyPress) -> KeyPress.Result {
        if key.key == .escape {
            showHelp = false
            showReview = false
            if showFilter { showFilter = false; filterFocused = false }
            return .handled
        }
        if filterFocused { return .ignored }
        if key.key == .space { model.toggleMarked(); return .handled }
        if key.key == .return { model.openSelected(); return .handled }
        if key.key == .delete || key.key == .deleteForward { model.goUp(); return .handled }
        if key.key == .leftArrow || key.characters.lowercased() == "h" || key.key == .upArrow || key.characters.lowercased() == "k" {
            model.moveSelection(-1); return .handled
        }
        if key.key == .rightArrow || key.characters.lowercased() == "l" || key.key == .downArrow || key.characters.lowercased() == "j" {
            model.moveSelection(1); return .handled
        }
        switch key.characters.lowercased() {
        case "c": showReview = true
        case "/": showFilter = true
        case "t":
            let modes = TreemapMode.allCases
            let index = modes.firstIndex(of: model.mode) ?? 0
            model.mode = modes[(index + 1) % modes.count]
        case "0": model.resetToRoot()
        case "r": model.startScan()
        case "?": showHelp = true
        case "[": model.depth = max(1, model.depth - 1)
        case "]": model.depth = min(8, model.depth + 1)
        default: return .ignored
        }
        return .handled
    }

    private func requestTrash(_ node: DiskNode?) {
        guard let node else { return }
        trashTarget = node
        showTrashConfirm = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("panel.choose_title")
        panel.message = L10n.string("panel.choose_message")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in model.scan(at: url) }
        }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func selectedShare(_ node: DiskNode) -> CGFloat {
        guard let root = model.rootNode else { return 0 }
        let whole = Double(max(1, root.bytes(apparent: model.useApparentSize)))
        return min(1, max(0, CGFloat(Double(node.bytes(apparent: model.useApparentSize)) / whole)))
    }

    private func percent(_ node: DiskNode) -> String {
        guard let root = model.rootNode else { return "0%" }
        let whole = Double(max(1, root.bytes(apparent: model.useApparentSize)))
        let value = Double(node.bytes(apparent: model.useApparentSize)) / whole * 100
        return value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    private func keyHint(_ key: String, _ actionKey: StaticString) -> some View {
        HStack(spacing: 5) {
            keycap(key)
            Text(L10n.string(actionKey)).font(.system(size: 10.5)).foregroundStyle(Theme.secondary)
        }
        .fixedSize()
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, key.count > 2 ? 5 : 6).padding(.vertical, 3)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, lineWidth: 1))
    }

    private func helpRow(_ key: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 105, alignment: .leading)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text)
        }
    }

    private func pathForDisplay(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == model.rootURL.path { return path == home ? "~" : path }
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func relativePath(_ path: String) -> String {
        let base = model.rootURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : URL(fileURLWithPath: path).lastPathComponent
    }

    private func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}

private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(8)
            .background(configuration.isPressed ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct CardButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(destructive ? Theme.danger : Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(configuration.isPressed ? Theme.raised : Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(destructive ? Theme.danger.opacity(0.5) : Theme.accent.opacity(0.5), lineWidth: 1))
    }
}

// Color.init(hex:) and Color.init(light:dark:) live in Theme.swift

private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
