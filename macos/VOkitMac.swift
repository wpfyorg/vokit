import AppKit
import Foundation
import SwiftUI

// First macOS desktop surface. The phone protocol stays in the existing Go binary.
@MainActor
final class PairSession: ObservableObject {
    static let shared = PairSession()

    @Published private(set) var status = "Disconnected"
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var connected = false
    @Published private(set) var running = false

    private var process: Process?
    private var pairingDirectory: URL?

    func connect() {
        guard !running else { return }

        let fileManager = FileManager.default
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("vivolinux"),
              fileManager.isExecutableFile(atPath: cli.path) else {
            status = "VOkit backend missing. Rebuild the app."
            return
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let stateDir = home.appendingPathComponent("Library/Application Support/VOkit/Pairing", isDirectory: true)
        let receiveDir = home.appendingPathComponent("Downloads/Vivo Office Kit", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stateDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            status = "Cannot prepare private pairing data."
            return
        }

        let task = Process()
        task.executableURL = cli
        // This button explicitly authorizes first-use trust of the scanned phone.
        task.arguments = ["pair", "--persistent", "--trust-scanned-phone",
                          "--state-dir", stateDir.path, "--receive-dir", receiveDir.path]
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        task.standardInput = FileHandle.nullDevice
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.running = false
                self.connected = false
                self.qrImage = nil
                self.status = finished.terminationStatus == 0 ? "Disconnected" :
                    "Pairing ended. Check Wi-Fi, phone approval and qrencode."
            }
        }

        do {
            try task.run()
        } catch {
            status = "Unable to start the VOkit backend."
            return
        }
        process = task
        pairingDirectory = stateDir
        running = true
        connected = false
        qrImage = nil
        status = "Preparing secure QR pairing…"
        consumeEvents(output)
        drain(errors) // Backend stderr may contain certificate details; never show it in the UI.
    }

    func disconnect() {
        guard let task = process else { return }
        task.terminate()
        status = "Disconnecting…"
    }

    func openDownloads() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Vivo Office Kit", isDirectory: true)
        NSWorkspace.shared.open(folder)
    }

    private func consumeEvents(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                // Protocol emits line-delimited, bounded JSON events. Stop on malformed output.
                if pending.count > 2 * 1024 * 1024 { break }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let stage = json["stage"] as? String else { continue }
                    let path = json["qr_path"] as? String
                    DispatchQueue.main.async { [weak self] in
                        self?.handle(stage: stage, qrPath: path)
                    }
                }
            }
        }
    }

    private func drain(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async {
            while !pipe.fileHandleForReading.availableData.isEmpty {}
        }
    }

    private func handle(stage: String, qrPath: String?) {
        guard running else { return }
        switch stage {
        case "qr_ready":
            guard let root = pairingDirectory, let qrPath else { return }
            let path = URL(fileURLWithPath: qrPath).standardizedFileURL
            guard path.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue < 1024 * 1024,
                  let image = NSImage(contentsOf: path) else { return }
            qrImage = image
            status = "Scan with Office Kit on your vivo phone"
        case "scan_received":
            qrImage = nil
            status = "Phone found. Establishing secure connection…"
        case "phone_negotiated":
            status = "Phone paired. Awaiting approval…"
        case "control_connected":
            connected = true
            qrImage = nil
            status = "Connected to phone"
        case "control_disconnected":
            connected = false
            status = "Phone disconnected"
        case "incoming_share_completed":
            status = "File received in Downloads/Vivo Office Kit"
        default:
            break
        }
    }
}

struct ContentView: View {
    @ObservedObject private var session = PairSession.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("VOkit for macOS")
                .font(.title.bold())
            Text("Connect a compatible vivo phone on the same Wi-Fi network.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let qr = session.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 256, height: 256)
                    .accessibilityLabel("Scan this QR code using vivo Office Kit")
            }
            Label(session.status, systemImage: session.connected ? "checkmark.circle.fill" : "circle.dotted")
                .multilineTextAlignment(.center)
            HStack {
                if session.running {
                    Button("Disconnect") { session.disconnect() }
                } else {
                    Button("Connect & Trust Scanned Phone") { session.connect() }
                        .buttonStyle(.borderedProminent)
                }
                Button("Received Files") { session.openDownloads() }
            }
            Text("Initial Mac preview: pairing, connection and incoming file sharing. Screen mirroring, virtual camera, clipboard and notifications are pending.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 450, minHeight: 430)
        .onDisappear { session.disconnect() }
    }
}

@main
struct VOkitMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
