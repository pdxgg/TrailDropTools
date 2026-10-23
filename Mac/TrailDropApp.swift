import SwiftUI
import AppKit
import AVKit
import AVFoundation
import QuickLookThumbnailing
import DiskArbitration

struct Media: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var date: String
    var dateSource: String
    var size: Int64
    var mtime: Int64
    var isVideo: Bool
    var companions: [String]
    var macPath: String?
    var day: String { String(date.prefix(10)) }
    var time: String { String(date.dropFirst(11).prefix(5)) }
    var bytes: String { size == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum Mode: String, CaseIterable, Identifiable {
    case batch = "批量转存", adaptive = "全量自适应", cleanup = "设备清理"
    var id: String { rawValue }
    var icon: String {
        switch self { case .batch: return "square.grid.2x2"; case .adaptive: return "calendar"; case .cleanup: return "trash" }
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case all = "全部素材", one = "最近 1 天", three = "最近 3 天", custom = "自定义时间"
    var id: String { rawValue }
}

@MainActor final class AppModel: ObservableObject {
    @Published var files: [Media] = []
    @Published var mode: Mode = .batch
    @Published var range: TimeRange = .all
    @Published var from = Calendar.current.startOfDay(for: Date())
    @Published var to = Date()
    @Published var selected: Set<String> = []
    @Published var cleanSelected: Set<String> = []
    @Published var inspectedMediaID: String?
    @Published var source: URL?
    @Published var destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/TrailDrop")
    @Published var status = "连接相机或读卡器，选择设备中的存储目录。"
    @Published var busy = false
    @Published var operation = ""
    @Published var progress = 0.0
    @Published var currentFile = ""
    @Published var preview: Media?
    @Published var showDelete = false
    @Published var confirmationStage = 1
    @Published var force = false
    @Published var forceText = ""
    @Published var volumes: [URL] = []
    @Published var deviceCandidates: [URL] = []
    @Published var showDevicePicker = false
    private var process: Process?
    private var sourceToken = ""
    private var mountedObserver: NSObjectProtocol?
    private var unmountedObserver: NSObjectProtocol?
    private let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TrailDrop")

    init() {
        refreshVolumes()
        mountedObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVolumes() }
        }
        unmountedObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                self.refreshVolumes()
                if let removed = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                   let source = self.source, source.path == removed.path || source.path.hasPrefix(removed.path + "/") {
                    self.status = "设备已断开；转存中断时会保留断点。重新接入后可继续。"
                }
            }
        }
    }

    var visible: [Media] {
        guard mode == .adaptive else { return files }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return files.filter { file in
            guard let date = Self.date(file.date) else { return range == .all }
            switch range {
            case .all: return true
            case .one: return date >= today && date < cal.date(byAdding: .day, value: 1, to: today)!
            case .three: return date >= cal.date(byAdding: .day, value: -2, to: today)! && date < cal.date(byAdding: .day, value: 1, to: today)!
            case .custom: return from <= to && date >= from && date < to.addingTimeInterval(60 - Double(cal.component(.second, from: to)))
            }
        }
    }
    var chosen: [Media] { mode == .adaptive ? visible : visible.filter { selected.contains($0.id) } }
    var inspectedMedia: Media? {
        if let inspectedMediaID, let file = visible.first(where: { $0.id == inspectedMediaID }) { return file }
        return chosen.first
    }
    func willSkipInDestination(_ file: Media) -> Bool {
        guard let macPath = file.macPath else { return false }
        let root = destination.standardizedFileURL.path
        let existing = URL(fileURLWithPath: macPath).standardizedFileURL.path
        return existing.hasPrefix(root + "/")
    }
    func archiveRelativePath(for file: Media) -> String {
        let rootName = source?.resolvingSymlinksInPath().lastPathComponent ?? "设备"
        return "\(file.day)/\(file.time.replacingOccurrences(of: ":", with: "-"))/\(rootName)/\(file.id)"
    }
    func plannedPCPath(for file: Media) -> String {
        "<PC 保存目录>\\<转存时间_短码>\\" + archiveRelativePath(for: file).replacingOccurrences(of: "/", with: "\\")
    }
    func proposedMacPath(for file: Media) -> String {
        if willSkipInDestination(file), let existing = file.macPath { return existing }
        return destination.appendingPathComponent("<转存时间_短码>").appendingPathComponent(archiveRelativePath(for: file)).path
    }
    var cleanupItems: [Media] { files.filter { cleanSelected.contains($0.id) } }
    var unsafeCount: Int { cleanupItems.filter { $0.macPath == nil }.count }
    var cleanBytes: String { cleanupItems.isEmpty ? "0 B" : ByteCountFormatter.string(fromByteCount: cleanupItems.reduce(0) { $0 + $1.size }, countStyle: .file) }
    var pendingCount: Int { chosen.filter { !willSkipInDestination($0) }.count }
    var skippedCount: Int { chosen.count - pendingCount }
    var pendingBytes: String { pendingCount == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: chosen.filter { !willSkipInDestination($0) }.reduce(0) { $0 + $1.size }, countStyle: .file) }
    var days: [String] { Array(Set(visible.map(\.day))).sorted(by: >) }
    var rangeDescription: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        switch range {
        case .all: return "全部素材，包含所有已识别的拍摄日期。"
        case .one: return "\(formatter.string(from: today)) 至 \(formatter.string(from: calendar.date(byAdding: .day, value: 1, to: today)!))（今天自然日，不含结束时刻）。"
        case .three: return "\(formatter.string(from: calendar.date(byAdding: .day, value: -2, to: today)!)) 至 \(formatter.string(from: calendar.date(byAdding: .day, value: 1, to: today)!))（共 3 个自然日，不含结束时刻）。"
        case .custom: return "\(formatter.string(from: from)) 至 \(formatter.string(from: to))（包含结束分钟）。"
        }
    }
    var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func date(_ value: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f.date(from: value)
    }
    func refreshVolumes() {
        let fm = FileManager.default
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []
        volumes = mounted.filter { volume in
            guard (try? volume.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) == false,
                  let session = DASessionCreate(kCFAllocatorDefault),
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
                  let details = DADiskCopyDescription(disk) as? [String: Any],
                  let transport = details[kDADiskDescriptionDeviceProtocolKey as String] as? String else { return false }
            return transport != "Virtual Interface" && transport != "Disk Image"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func scanConnectedDevices() {
        guard !busy else { return }
        refreshVolumes()
        deviceCandidates = volumes
        if deviceCandidates.isEmpty {
            status = "未发现已挂载的相机或读卡器。请在相机上选择“文件传输”，再重试；也可以手动选择设备目录。"
        } else if deviceCandidates.count == 1 {
            selectSource(deviceCandidates[0])
        } else {
            showDevicePicker = true
            status = "找到 \(deviceCandidates.count) 个外接存储，请选择要扫描的设备。"
        }
    }
    func selectSource(_ url: URL) {
        guard !busy else { return }
        source = url
        sourceToken = ""
        files = []
        selected = []
        cleanSelected = []
        inspectedMediaID = nil
        scan()
    }
    func chooseSource(_ initial: URL? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "扫描此目录"; panel.message = "选择相机、读卡器的存储根目录，或 DCIM 目录。"; panel.directoryURL = initial
        if panel.runModal() == .OK, let url = panel.url { selectSource(url) }
    }
    func chooseDestination() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存到此处"; panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
    func scan() {
        guard source != nil, !busy else { return }
        run("scan")
    }
    func transfer() {
        guard !chosen.isEmpty, !busy else { return }
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { status = "无法创建保存目录：\(error.localizedDescription)"; return }
        let expected = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, ["size": $0.size, "mtime": $0.mtime]) })
        run("transfer", extra: ["destination": destination.path, "selected": chosen.map(\.id), "expected": expected])
    }
    func pause() {
        process?.terminate()
        status = "正在保存断点；请等待当前操作停止。"
    }
    func toggle(_ file: Media) {
        if mode == .adaptive { return }
        if mode == .cleanup {
            if !cleanSelected.insert(file.id).inserted { cleanSelected.remove(file.id) }
        } else {
            if !selected.insert(file.id).inserted { selected.remove(file.id) }
            inspectedMediaID = file.id
        }
    }
    func isSelected(_ file: Media) -> Bool {
        mode == .adaptive || (mode == .cleanup ? cleanSelected.contains(file.id) : selected.contains(file.id))
    }
    func toggleDay(_ day: String) {
        let ids = Set(visible.filter { $0.day == day }.map(\.id))
        if mode == .cleanup { if ids.isSubset(of: cleanSelected) { cleanSelected.subtract(ids) } else { cleanSelected.formUnion(ids) } }
        else { if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) } }
    }
    func requestDelete(force: Bool) {
        guard !cleanupItems.isEmpty else { return }
        self.force = force; forceText = ""; confirmationStage = 1; showDelete = true
    }
    func deleteConfirmed() {
        guard force ? confirmationStage == 2 && forceText == "删除未备份素材" : unsafeCount == 0 else { return }
        showDelete = false
        let expected = Dictionary(uniqueKeysWithValues: cleanupItems.map { ($0.id, ["size": $0.size, "mtime": $0.mtime]) })
        run("delete", extra: ["selected": cleanupItems.map(\.id), "force": force, "confirmation": forceText, "expected": expected])
    }
    private func run(_ action: String, extra: [String: Any] = [:]) {
        guard !busy, let source else { return }
        let bundledEngine = Bundle.main.url(forResource: "traildrop-engine", withExtension: nil)
        let script = Bundle.main.url(forResource: "engine", withExtension: "py")
        guard bundledEngine != nil || (python != nil && script != nil) else {
            status = "应用内文件引擎缺失，请重新安装完整应用。"; return
        }
        var request: [String: Any] = ["action": action, "source": source.path, "stateDir": stateDir.path, "sourceToken": sourceToken]
        request.merge(extra) { _, new in new }
        guard let input = try? JSONSerialization.data(withJSONObject: request) else { return }
        let proc = Process(), output = Pipe(), stdin = Pipe()
        if let bundledEngine {
            proc.executableURL = bundledEngine
        } else if let python, let script {
            proc.executableURL = URL(fileURLWithPath: python); proc.arguments = ["-u", script.path]
        }
        proc.standardOutput = output; proc.standardInput = stdin; proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { status = "引擎启动失败：\(error.localizedDescription)"; return }
        process = proc; busy = true; operation = action; progress = 0
        status = action == "scan" ? "扫描全部媒体目录，并检查 Mac 副本……" : action == "delete" ? "重新校验副本和源文件，准备清理……" : "计算内容指纹，准备复制或恢复断点……"
        stdin.fileHandleForWriting.write(input + Data([10])); try? stdin.fileHandleForWriting.close()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<end)
                    buffer.removeSubrange(buffer.startIndex...end)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self?.handle(object, action: action) }
                    }
                }
            }
            proc.waitUntilExit()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.process = nil
                if proc.terminationStatus != 0 && !self.status.contains("失败") && !self.status.contains("暂停") {
                    self.status = "操作中断或引擎异常（\(proc.terminationStatus)）。保留源文件与断点，可重新扫描后重试。"
                }
            }
        }
    }
    private func handle(_ event: [String: Any], action: String) {
        switch event["event"] as? String {
        case "progress":
            let index = event["index"] as? Double ?? 0, total = max(1, event["total"] as? Double ?? 1)
            let bytes = event["bytes"] as? Double ?? 0, size = max(1, event["size"] as? Double ?? 1)
            progress = (index + bytes / size) / total; currentFile = event["name"] as? String ?? ""
        case "file": status = event["status"] as? String ?? ""; currentFile = event["name"] as? String ?? ""
        case "error": status = "操作失败：\(event["message"] as? String ?? "未知错误")"
        case "paused": status = event["message"] as? String ?? "已暂停"
        case "result":
            guard let result = event["result"] as? [String: Any] else { return }
            if action == "scan", let raw = result["files"], let data = try? JSONSerialization.data(withJSONObject: raw), let items = try? JSONDecoder().decode([Media].self, from: data) {
                sourceToken = result["sourceToken"] as? String ?? ""
                files = items; selected = Set(items.map(\.id)); cleanSelected = cleanSelected.intersection(Set(items.map(\.id)))
                let warnings = result["warnings"] as? [String] ?? []
                status = "扫描完成：\(items.count) 个素材，\(items.filter { $0.macPath != nil }.count) 个已有有效 Mac 副本。" + (warnings.isEmpty ? "" : " 跳过 \(warnings.count) 个不可读文件：\(warnings.prefix(3).joined(separator: "; "))")
            } else if action == "transfer" {
                progress = 1; status = "转存完成，校验通过。相机原文件保留；重新扫描后可到设备清理页面处理。"
                if let rows = result["files"] as? [[String: Any]] {
                    for row in rows { if let id = row["source"] as? String, let index = files.firstIndex(where: { $0.id == id }) { files[index].macPath = row["target"] as? String } }
                }
            } else if action == "delete" {
                let removed = Set(result["deleted"] as? [String] ?? [])
                files.removeAll { removed.contains($0.id) }; cleanSelected.subtract(removed)
                let failures = result["failed"] as? [[String: Any]] ?? []
                status = "清理完成：\(removed.count) 个素材已删除，\(failures.count) 个未删除。Mac 副本保留。" + failures.compactMap { $0["error"] as? String }.prefix(3).joined(separator: "; ")
            }
        default: break
        }
    }
}

struct Thumbnail: View {
    let file: Media
    @State private var image: NSImage?
    @State private var unavailable = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.10))
            if let image { Image(nsImage: image).resizable().scaledToFill().frame(height: 130).clipped() }
            else { VStack(spacing: 5) { Image(systemName: file.isVideo ? "video" : "photo"); Text(unavailable ? "预览不可用" : "加载缩略图…").font(.caption) }.foregroundStyle(.secondary) }
            if file.isVideo { VStack { Spacer(); HStack { Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 3); Spacer() }.padding(10) } }
        }
        .frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: file.path) {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: file.path), size: CGSize(width: 360, height: 240), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                DispatchQueue.main.async { image = representation?.nsImage; unavailable = representation == nil }
            }
        }
    }
}

struct RoutePathRow: View {
    let title: String
    let icon: String
    let path: String
    let note: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(path).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TransferRouteView: View {
    @ObservedObject var model: AppModel
    @State private var showPlannedPaths = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("转存路径预览", systemImage: "arrow.left.arrow.right").font(.headline)
                Spacer()
                if let file = model.inspectedMedia {
                    Text(model.chosen.contains(file) ? "已选素材示例" : "当前素材未选中")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let file = model.inspectedMedia {
                RoutePathRow(title: "设备原文件", icon: "externaldrive", path: file.path,
                             note: "相对于设备根目录：\(file.id)")
                Image(systemName: "arrow.down").foregroundStyle(Color.accentColor).padding(.leading, 4)
                RoutePathRow(title: model.willSkipInDestination(file) ? "这台 Mac · 已有有效副本" : "这台 Mac · 预计保存位置",
                             icon: "desktopcomputer", path: model.proposedMacPath(for: file),
                             note: model.willSkipInDestination(file) ? "位于当前目标目录，本次预计跳过重复写入。" : "转存开始时会生成实际批次文件夹；原文件名与设备内相对目录保留。")
                if let existing = file.macPath, !model.willSkipInDestination(file) {
                    Text("其他位置已有 Mac 副本：\(existing)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                DisclosureGroup("Windows PC 与手机路径规划 · 尚未实现转存", isExpanded: $showPlannedPaths) {
                    VStack(alignment: .leading, spacing: 12) {
                        RoutePathRow(title: "Windows PC · 规划位置", icon: "desktopcomputer", path: model.plannedPCPath(for: file),
                                     note: "未来在 PC 端选择保存目录后，沿用相同的归档结构。")
                        RoutePathRow(title: "手机 · 规划位置", icon: "iphone", path: "<手机文件目录>/<转存时间_短码>/\(model.archiveRelativePath(for: file))",
                                     note: "未来在手机端选择可访问的文件目录后，沿用相同的归档结构。")
                    }.padding(.top, 8)
                }.font(.subheadline.weight(.medium))
            } else {
                RoutePathRow(title: "设备来源", icon: "externaldrive", path: model.source?.path ?? "尚未选择设备目录", note: "选择一个素材后会显示完整原文件路径。")
                RoutePathRow(title: "这台 Mac · 保存根目录", icon: "desktopcomputer", path: model.destination.path, note: "选择素材后会显示预计归档路径。")
                Text("PC 与手机端尚未实现转存；对应路径会在选择素材后显示为规划示意。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.18)))
    }
}

struct MediaCard: View {
    @ObservedObject var model: AppModel
    let file: Media
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button { model.preview = file } label: { Thumbnail(file: file) }.buttonStyle(.plain).help("预览 \(file.name)")
                Button { model.toggle(file) } label: {
                    Image(systemName: model.isSelected(file) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(model.isSelected(file) ? Color.accentColor : Color.gray, Color.white)
                        .padding(8).background(.regularMaterial, in: Circle())
                }.buttonStyle(.plain).padding(5).disabled(model.mode == .adaptive || model.busy)
                    .accessibilityLabel(model.isSelected(file) ? "已选中 \(file.name)" : "选择 \(file.name)")
            }
            Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(2).textSelection(.enabled)
            Text(file.id).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(file.path)
            HStack { Text(file.time); Spacer(); Text(file.bytes) }.font(.caption).foregroundStyle(.secondary)
            Label(file.macPath == nil ? "未同步到 Mac / 副本不可用" : "已同步 · 相机仍保留", systemImage: file.macPath == nil ? "exclamationmark.circle" : "checkmark.shield")
                .font(.caption).foregroundStyle(file.macPath == nil ? Color.orange : Color.accentColor)
            if model.mode == .cleanup, let path = file.macPath {
                Button("查看 Mac 副本") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.font(.caption)
            }
            if model.mode != .cleanup {
                Button("查看路径") { model.inspectedMediaID = file.id }.font(.caption)
                    .accessibilityLabel("查看 \(file.name) 的转存路径")
            }
            Text("\(file.companions.count) 个关联文件 · 时间：\(file.dateSource)").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.isSelected(file) ? Color.accentColor.opacity(0.7) : Color.gray.opacity(0.12), lineWidth: model.isSelected(file) ? 2 : 1))
    }
}

struct PreviewSheet: View {
    let file: Media
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playable: Bool?
    var body: some View {
        VStack(spacing: 15) {
            HStack { Text(file.name).font(.headline); Spacer(); Button("关闭") { dismiss() } }
            if file.isVideo {
                if playable == true { VideoPlayer(player: player).frame(minHeight: 420) }
                else { Label(playable == nil ? "检查视频解码能力……" : "系统无法解码此视频，可在对应品牌的剪辑软件中打开。", systemImage: "video.slash").frame(minHeight: 260) }
            }
            else if let image = NSImage(contentsOfFile: file.path) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 500) }
            else { Label("系统无法解码此原始格式，可在外部应用中打开。", systemImage: "photo") }
            HStack { Text("\(file.date) · \(file.bytes)").foregroundStyle(.secondary); Spacer(); Button("在外部应用打开") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) } }
        }.padding(24).frame(minWidth: 640, minHeight: 360)
            .task {
                if file.isVideo {
                    let asset = AVURLAsset(url: URL(fileURLWithPath: file.path))
                    playable = (try? await asset.load(.isPlayable)) ?? false
                    if playable == true { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
                }
            }
            .onDisappear { player?.pause(); player = nil }
    }
}

struct DeleteSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.force ? "强制清理：含未备份素材" : "确认清理相机素材", systemImage: model.force ? "exclamationmark.triangle.fill" : "trash").font(.title2)
            Text("所选 \(model.cleanupItems.count) 个素材，约 \(model.cleanBytes)（不含关联文件）。")
            Text("其中 \(model.unsafeCount) 个未同步至 Mac 或当前副本不可用。删除作用于相机原文件及同名关联文件，无法通过本应用撤销。")
                .foregroundStyle(model.force ? Color.orange : Color.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 7) { ForEach(model.cleanupItems) { f in Label(f.name, systemImage: f.macPath == nil ? "exclamationmark.circle" : "checkmark.shield").font(.caption) } } }.frame(maxHeight: 150)
            if model.force && model.confirmationStage == 2 {
                Text("再次提醒：未备份素材可能永久丢失。输入“删除未备份素材”继续。").font(.headline)
                TextField("删除未备份素材", text: $model.forceText).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("取消") { model.showDelete = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.force && model.confirmationStage == 1 {
                    Button("我了解风险，继续二次确认", role: .destructive) { model.confirmationStage = 2 }
                } else {
                    Button("确认删除相机原文件", role: .destructive) { model.deleteConfirmed() }
                        .disabled(model.force && model.forceText != "删除未备份素材")
                }
            }
        }.padding(28).frame(width: 570)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 16)]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("轻舟").font(.largeTitle.weight(.semibold)); Text("TRAILDROP").font(.caption).tracking(3).foregroundStyle(.secondary)
                ForEach(Mode.allCases) { mode in
                    Button { model.mode = mode } label: { Label(mode.rawValue, systemImage: mode.icon).frame(maxWidth: .infinity, alignment: .leading).padding(9).background(model.mode == mode ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).disabled(model.busy)
                }
                Divider().padding(.vertical, 8)
                Text("外接存储").font(.caption).foregroundStyle(.secondary)
                ForEach(model.volumes, id: \.path) { volume in Button { model.selectSource(volume) } label: { Label(volume.lastPathComponent, systemImage: "externaldrive") }.buttonStyle(.plain).disabled(model.busy) }
                Spacer()
                Text("本地处理 · 原始画质\n首版支持 USB 磁盘 / 读卡器").font(.caption).foregroundStyle(.secondary)
            }.padding(20).navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(model.mode.rawValue).font(.largeTitle.weight(.semibold)); Text(model.source?.path ?? "尚未选择相机存储目录").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Spacer()
                    Button { model.scanConnectedDevices() } label: { Label("扫描已连接设备", systemImage: "externaldrive.badge.magnifyingglass") }.buttonStyle(.borderedProminent).disabled(model.busy)
                    Button("选择设备目录") { model.chooseSource() }.disabled(model.busy)
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }.help("重新扫描全部媒体目录").disabled(model.source == nil || model.busy)
                }
                if model.mode == .adaptive {
                    Picker("时间范围", selection: $model.range) { ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(model.busy)
                    if model.range == .custom { HStack { DatePicker("开始", selection: $model.from); DatePicker("结束", selection: $model.to) }.disabled(model.busy) }
                    Text(model.rangeDescription + " 按本机时区筛选；下方打勾素材均在本次同步范围内。").font(.caption).foregroundStyle(.secondary)
                    if model.range == .custom && model.from > model.to { Text("开始时间不能晚于结束时间").foregroundStyle(.red) }
                }
                if model.mode == .cleanup {
                    Text("已同步素材可直接勾选清理；未同步素材仍可勾选，须通过“强制清理”与二次提醒。每次删除前重新校验副本。").font(.callout).foregroundStyle(.secondary)
                }
                if model.mode != .cleanup && model.source != nil {
                    TransferRouteView(model: model)
                }
                HStack {
                    Text("\(model.visible.count) 个素材 · 按日期倒序").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.mode != .adaptive {
                        Button(model.mode == .cleanup ? "全选已同步" : "全选") {
                            if model.mode == .cleanup { model.cleanSelected = Set(model.files.filter { $0.macPath != nil }.map(\.id)) }
                            else { model.selected = Set(model.visible.map(\.id)) }
                        }.disabled(model.busy)
                        Button("取消全选") { if model.mode == .cleanup { model.cleanSelected = [] } else { model.selected = [] } }.disabled(model.busy)
                    }
                }
                ScrollView {
                    if model.files.isEmpty { VStack(spacing: 16) { Image(systemName: "camera.on.rectangle").font(.system(size: 48)).foregroundStyle(.secondary); Text(model.busy ? "正在扫描与检查副本……" : "接上相机，带走回忆。").font(.title2); Text("点击“扫描已连接设备”查找照片和视频；扫描不会转存或清理文件。").foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 90) }
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.days, id: \.self) { day in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(day).font(.headline)
                                    Text("\(model.visible.filter { $0.day == day }.count) 个素材").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if model.mode != .adaptive {
                                        let dayFiles = model.visible.filter { $0.day == day }
                                        let count = dayFiles.filter { model.isSelected($0) }.count
                                        Text(count == 0 ? "未选" : count == dayFiles.count ? "全选" : "部分已选 \(count)/\(dayFiles.count)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Button(count == dayFiles.count ? "取消当天" : "选择当天") { model.toggleDay(day) }.disabled(model.busy)
                                    }
                                }
                                LazyVGrid(columns: columns, spacing: 16) { ForEach(model.visible.filter { $0.day == day }.sorted { $0.date < $1.date }) { file in MediaCard(model: model, file: file) } }
                            }
                        }
                    }.padding(3)
                }
                Divider()
                if model.busy { ProgressView(value: model.progress); HStack { Text(model.currentFile).font(.caption).lineLimit(1); Spacer(); Button("暂停 / 停止") { model.pause() } } }
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if model.mode == .cleanup {
                    HStack { Text("已选 \(model.cleanupItems.count) 个 · 约 \(model.cleanBytes)").font(.callout); Spacer();
                        if model.unsafeCount > 0 { Button("强制清理（\(model.unsafeCount) 个未备份）", role: .destructive) { model.requestDelete(force: true) }.disabled(model.busy) }
                        else { Button("清理所选", role: .destructive) { model.requestDelete(force: false) }.disabled(model.cleanupItems.isEmpty || model.busy) }
                    }
                } else {
                    HStack { VStack(alignment: .leading) { Text("已选 \(model.chosen.count) 个 · 预计待复制 \(model.pendingCount) 个 / \(model.pendingBytes) · 已有副本 \(model.skippedCount) 个").font(.callout); Text(model.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Button("更改保存位置") { model.chooseDestination() }.disabled(model.busy); Button("开始 / 继续转存") { model.transfer() }.buttonStyle(.borderedProminent).disabled(model.chosen.isEmpty || model.busy || (model.mode == .adaptive && model.range == .custom && model.from > model.to)) }
                }
            }.padding(26).frame(minWidth: 720, minHeight: 640)
        }
        .tint(Color(red: 0.04, green: 0.48, blue: 0.44))
        .sheet(item: $model.preview) { PreviewSheet(file: $0) }
        .sheet(isPresented: $model.showDelete) { DeleteSheet(model: model) }
        .confirmationDialog("选择要扫描的设备", isPresented: $model.showDevicePicker, titleVisibility: .visible) {
            ForEach(model.deviceCandidates, id: \.path) { volume in
                Button(volume.lastPathComponent) { model.selectSource(volume) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只读取并展示所选设备上的照片和视频，不会自动转存或清理。")
        }
    }
}

@main struct TrailDropApp: App {
    var body: some Scene {
        WindowGroup("轻舟 TrailDrop") { ContentView() }.defaultSize(width: 1160, height: 800)
    }
}
