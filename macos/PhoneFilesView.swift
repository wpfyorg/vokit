import AppKit
import Foundation
import SwiftUI

private struct PhoneFile: Decodable, Identifiable {
    let fileName: String
    let savePath: String
    let fileSize: Int64
    let isDirectory: Bool
    let id: String
    let page: Int
    let category: String

    enum CodingKeys: String, CodingKey {
        case fileName, savePath, fileSize, isDirectory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try values.decode(String.self, forKey: .fileName)
        savePath = try values.decode(String.self, forKey: .savePath)
        fileSize = max(0, try values.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0)
        isDirectory = try values.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        id = savePath
        page = 0
        category = ""
    }

    init(fileName: String, savePath: String, fileSize: Int64, isDirectory: Bool, page: Int, category: String) {
        self.fileName = fileName
        self.savePath = savePath
        self.fileSize = max(0, fileSize)
        self.isDirectory = isDirectory
        self.id = savePath
        self.page = page
        self.category = category
    }
}

private struct PhoneFilePage: Decodable {
    let dataList: [PhoneFile]
    let totalCount: Int64
}

@MainActor
private final class PhoneFilesState: ObservableObject {
    static let shared = PhoneFilesState()
    @Published var category = "recent"
    @Published var directory = "/storage/emulated/0"
    @Published var files: [PhoneFile] = []
    @Published var page = 0
    @Published var hasMore = false
    @Published var busy = false
    @Published var status = ""
    @Published var selection: String?
    var pendingRefresh = false
}

/// Browse and transfer files through the active VOkit native phone session.
@MainActor
struct PhoneFilesView: View {
    let connected: Bool

    @ObservedObject private var state = PhoneFilesState.shared
    private var category: String { get { state.category } nonmutating set { state.category = newValue } }
    private var directory: String { get { state.directory } nonmutating set { state.directory = newValue } }
    private var files: [PhoneFile] { get { state.files } nonmutating set { state.files = newValue } }
    private var page: Int { get { state.page } nonmutating set { state.page = newValue } }
    private var hasMore: Bool { get { state.hasMore } nonmutating set { state.hasMore = newValue } }
    private var busy: Bool { get { state.busy } nonmutating set { state.busy = newValue } }
    private var status: String { get { state.status } nonmutating set { state.status = newValue } }
    private var selection: String? { get { state.selection } nonmutating set { state.selection = newValue } }

    private let categories: [(String, String)] = [
        ("", "Folders"), ("recent", "Recent"), ("images", "Images"), ("videos", "Videos"),
        ("audio", "Audio"), ("documents", "Documents")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Collection", selection: Binding(get: { category }, set: { category = $0 })) {
                    ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                .frame(width: 150)
                if category.isEmpty {
                    Button("Up") { openFolder(URL(fileURLWithPath: directory).deletingLastPathComponent().path) }
                    Text(directory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Upload") { chooseUpload() }.disabled(!connected || busy)
                Button("Download") { downloadSelected() }.disabled(!connected || busy || selectedFile == nil || selectedFile?.isDirectory == true)
                Button("Preview") { previewSelected() }.disabled(!connected || busy || selectedFile == nil || selectedFile?.isDirectory == true)
            }
            .padding()

            List(selection: Binding(get: { selection }, set: { selection = $0 })) {
                ForEach(files) { file in
                    HStack {
                        Image(systemName: file.isDirectory ? "folder" : icon(for: file.fileName))
                            .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                        Text(file.fileName).lineLimit(1)
                        Spacer()
                        if !file.isDirectory { Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file)).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                    .tag(file.savePath)
                    .onTapGesture(count: 2) {
                        if file.isDirectory { openFolder(file.savePath) }
                        else { selection = file.savePath; previewSelected() }
                    }
                    .contextMenu {
                        if file.isDirectory {
                            Button("Open Folder") { openFolder(file.savePath) }
                        } else {
                            Button("Download…") { selection = file.savePath; downloadSelected() }
                            Button("Preview") { selection = file.savePath; previewSelected() }
                        }
                    }
                }
                if hasMore {
                    Button(busy ? "Loading…" : "Load More") { loadFiles(reset: false) }
                        .disabled(busy || !connected)
                        .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: category) { _ in
                loadFiles(reset: true)
            }

            HStack {
                Text(status.isEmpty ? (connected ? " " : "Connect your phone to browse files") : status)
                    .foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh") { loadFiles(reset: true) }.disabled(!connected || busy)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onChange(of: connected) { value in
            if value { loadFiles(reset: true) }
            else { files = []; hasMore = false; state.pendingRefresh = false; status = "Phone disconnected" }
        }
        .onAppear { if connected { loadFiles(reset: true) } }
    }

    private var selectedFile: PhoneFile? { files.first { $0.savePath == selection } }

    private func loadFiles(reset: Bool) {
        guard connected else { return }
        if busy {
            if reset { state.pendingRefresh = true }
            return
        }
        if reset { files = []; page = 0; hasMore = false; selection = nil }
        let requestedPage = page
        busy = true
        status = requestedPage == 0 ? "Reading phone files…" : "Loading more files…"
        var args = ["files", "--page", String(requestedPage)]
        args += category.isEmpty ? ["--path", directory] : ["--category", category]
        run(args, as: PhoneFilePage.self) { result in
            busy = false
            if state.pendingRefresh {
                state.pendingRefresh = false
                if PairSession.shared.connected { loadFiles(reset: true) }
                return
            }
            guard PairSession.shared.connected else {
                files = []; hasMore = false; status = "Phone disconnected"
                return
            }
            switch result {
            case .success(let listing):
                guard listing.dataList.count <= 2000 else { status = "Phone returned too many files."; return }
                let valid = listing.dataList.filter(validPhoneFile)
                let existing = Set(files.map(\.savePath))
                let added = valid.filter { !existing.contains($0.savePath) }.map {
                    PhoneFile(fileName: $0.fileName, savePath: $0.savePath, fileSize: $0.fileSize,
                              isDirectory: $0.isDirectory, page: requestedPage, category: category)
                }
                files.append(contentsOf: added)
                page += 1
                hasMore = !added.isEmpty && (listing.dataList.count >= 200 || Int64(files.count) < listing.totalCount)
                status = "\(files.count) files and folders" + (hasMore ? " · More available" : "")
            case .failure(let error):
                status = error.localizedDescription
                hasMore = false
            }
        }
    }

    private func validPhoneFile(_ file: PhoneFile) -> Bool {
        let path = NSString(string: file.savePath).standardizingPath
        return file.fileName != "." && file.fileName != ".." && !file.fileName.contains("/") &&
            !file.fileName.contains("\\") && !file.fileName.contains("\0") && file.savePath.hasPrefix("/") &&
            path == file.savePath && !file.savePath.contains("\\") &&
            (file.isDirectory || URL(fileURLWithPath: file.savePath).lastPathComponent == file.fileName)
    }

    private func openFolder(_ path: String) {
        guard path.hasPrefix("/"), NSString(string: path).standardizingPath == path,
              !path.contains("\\"), !path.contains("\0") else { status = "Invalid phone folder."; return }
        directory = path
        category = ""
        files = []; page = 0; hasMore = false
        loadFiles(reset: true)
    }

    private func downloadSelected() {
        guard let file = selectedFile, !file.isDirectory, connected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { status = "Choose a new name. Existing files are never replaced."; return }
        busy = true; status = "Saving phone file…"
        run(["download", "--remote", file.savePath, "--output", url.path, "--page", String(file.page)] + categoryArg(file), as: TransferReceipt.self) { result in
            busy = false
            switch result {
            case .success(let receipt): status = "Saved \(ByteCountFormatter.string(fromByteCount: receipt.bytes, countStyle: .file)) · SHA-256 \(receipt.sha256)"
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func chooseUpload() {
        guard connected else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_073_741_824 else {
                status = "Choose a regular file up to 1 GiB."; return
            }
        } catch { status = "Cannot read selected file."; return }
        let destination = category.isEmpty ? directory : "/storage/emulated/0/Download"
        busy = true; status = "Uploading to \(destination)…"
        run(["upload", "--local", url.path, "--to", destination], as: UploadReceipt.self) { result in
            busy = false
            switch result {
            case .success: status = "Upload complete"; loadFiles(reset: true)
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func previewSelected() {
        guard let file = selectedFile, !file.isDirectory, connected else { return }
        let ext = URL(fileURLWithPath: file.fileName).pathExtension.lowercased()
        guard ["jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "mp4", "mov", "m4v", "3gp", "webm"].contains(ext) else {
            status = "Preview supports image and video files. Download other files to open them."; return
        }
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("VOkitPreview-\(UUID().uuidString).\(ext)")
        busy = true; status = "Preparing preview…"
        run(["preview", "--remote", file.savePath, "--output", cache.path, "--page", String(file.page)] + categoryArg(file), as: PreviewReceipt.self) { result in
            busy = false
            switch result {
            case .success:
                NSWorkspace.shared.open(cache)
                status = "Opened \(file.fileName)"
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func categoryArg(_ file: PhoneFile) -> [String] { file.category.isEmpty ? [] : ["--category", file.category] }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp": return "photo"
        case "mp4", "mov", "m4v", "3gp", "webm": return "film"
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus": return "music.note"
        default: return "doc"
        }
    }

    private func run<T: Decodable>(_ arguments: [String], as type: T.Type, completion: @escaping (Result<T, Error>) -> Void) {
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("vivolinux"),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            completion(.failure(PhoneFilesError.backendMissing)); return
        }
        let process = Process()
        process.executableURL = cli
        let environment = ProcessInfo.processInfo.environment
        let runtimeSocket = environment["XDG_RUNTIME_DIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("vivolinux/native.sock").path
        }
        let socket = runtimeSocket.flatMap { $0.utf8.count < 100 ? $0 : nil }
            ?? "/tmp/vivolinux-\(getuid())/native.sock"
        process.arguments = arguments + ["--socket", socket]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(); process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            do { try process.run() }
            catch {
                DispatchQueue.main.async { completion(.failure(PhoneFilesError.operationFailed)) }
                return
            }
            // Read while the subprocess runs: a large folder response can fill
            // a pipe and prevent the process from ever exiting otherwise.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result: Result<T, Error>
            if process.terminationStatus != 0 {
                result = .failure(PhoneFilesError.operationFailed)
            } else {
                do {
                    // The Go native CLI emits the result itself, not a
                    // { result: ... } envelope.
                    result = .success(try JSONDecoder().decode(T.self, from: data))
                } catch { result = .failure(PhoneFilesError.invalidResponse) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

private struct TransferReceipt: Decodable { let bytes: Int64; let sha256: String }
private struct UploadReceipt: Decodable {
    let bytes: Int64
    let localSHA256: String?
    enum CodingKeys: String, CodingKey { case bytes; case localSHA256 = "local_sha256" }
}
private struct PreviewReceipt: Decodable { let path: String }

private enum PhoneFilesError: LocalizedError {
    case backendMissing, operationFailed, invalidResponse, remote(String)
    var errorDescription: String? {
        switch self {
        case .backendMissing: return "VOkit backend is missing. Rebuild the app."
        case .operationFailed: return "Phone operation failed. Check the connection and file permission."
        case .invalidResponse: return "Phone returned an invalid response."
        case .remote(let message): return message == "file_permission_required" ? "Approve file access on the phone and retry." : "Phone file operation failed."
        }
    }
}
