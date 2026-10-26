import AppKit
import Foundation
import SwiftUI

enum PairPhase {
    case idle, preparing, scanning, connecting, approval, connected, stopping, failed
}

@MainActor
final class PairSession: ObservableObject {
    static let shared = PairSession()

    @Published private(set) var status = "Disconnected"
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var connected = false
    @Published private(set) var running = false
    @Published private(set) var phase: PairPhase = .idle
    @Published private(set) var failureHint: String?
    @Published private(set) var recentTransfer = false

    private var process: Process?
    private var pairingDirectory: URL?
    private var disconnectRequested = false

    func connect() {
        guard !running else { return }
        failureHint = nil
        recentTransfer = false
        disconnectRequested = false
        phase = .preparing

        let fileManager = FileManager.default
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("vivolinux"),
              fileManager.isExecutableFile(atPath: cli.path) else {
            status = "VOkit backend missing. Rebuild the app."
            phase = .failed
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
            phase = .failed
            return
        }

        let task = Process()
        task.executableURL = cli
        // This button explicitly authorizes first-use trust of the scanned phone.
        task.arguments = ["pair", "--persistent", "--trust-scanned-phone",
                          "--state-dir", stateDir.path, "--receive-dir", receiveDir.path]
        // Finder-launched GUI apps normally do not inherit Homebrew's PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? ""].joined(separator: ":")
        task.environment = environment
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
                if self.disconnectRequested || finished.terminationStatus == 0 {
                    self.phase = .idle
                    self.status = "Disconnected"
                    self.failureHint = nil
                } else {
                    self.phase = .failed
                    self.status = "Pairing interrupted"
                    if self.failureHint == nil {
                        self.failureHint = "The phone could not complete pairing. Check Local Network access and try a fresh QR code."
                    }
                }
            }
        }

        do {
            try task.run()
        } catch {
            status = "Unable to start the VOkit backend."
            phase = .failed
            return
        }
        process = task
        pairingDirectory = stateDir
        running = true
        connected = false
        qrImage = nil
        status = "Preparing secure QR pairing…"
        phase = .preparing
        consumeEvents(output)
        drain(errors) // Only map known errors to safe descriptions.
    }

    func disconnect() {
        guard let task = process else { return }
        disconnectRequested = true
        task.terminate()
        phase = .stopping
        status = "Disconnecting…"
    }

    func openDownloads() {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Vivo Office Kit", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
                    let code = json["code"] as? String
                    DispatchQueue.main.async { [weak self] in
                        self?.handle(stage: stage, qrPath: path, code: code)
                    }
                }
            }
        }
    }

    private func drain(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var recent = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                recent.append(chunk)
                if recent.count > 64 * 1024 { recent.removeFirst(recent.count - 32 * 1024) }
            }
            // stderr may contain certificates and protocol identifiers. Never display raw text.
            let log = String(data: recent, encoding: .utf8) ?? ""
            let hint: String?
            if log.contains("install qrencode") {
                hint = "Install qrencode with Homebrew, then try again."
            } else if log.contains("no private IPv4 LAN address") {
                hint = "Connect your Mac to Wi-Fi before pairing."
            } else if log.contains("no reachable phone") {
                hint = "The phone was not reachable over the local network."
            } else if log.contains("context deadline exceeded") {
                hint = "Connection timed out. Approve the phone prompt and retry."
            } else if log.contains("connection refused") {
                hint = "The phone refused the connection. Check phone approval."
            } else {
                hint = nil
            }
            guard let hint else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.disconnectRequested else { return }
                self.failureHint = hint
            }
        }
    }

    private func handle(stage: String, qrPath: String?, code: String?) {
        guard running, !disconnectRequested else { return }
        switch stage {
        case "qr_ready":
            guard let root = pairingDirectory, let qrPath else { return }
            let path = URL(fileURLWithPath: qrPath).standardizedFileURL
            guard path.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue < 1024 * 1024,
                  let image = NSImage(contentsOf: path) else { return }
            qrImage = image
            phase = .scanning
            status = "Scan with Office Kit on your vivo phone"
        case "scan_received":
            qrImage = nil
            phase = .connecting
            status = "Phone found. Establishing secure connection…"
        case "phone_negotiated":
            phase = .approval
            status = "Phone paired. Awaiting approval…"
        case "control_connected":
            connected = true
            phase = .connected
            qrImage = nil
            status = "Connected to phone"
        case "control_disconnected":
            connected = false
            phase = .failed
            failureHint = "Phone disconnected. Check both devices are on the same Wi-Fi."
            status = "Phone disconnected"
        case "incoming_share_completed":
            recentTransfer = true
            status = "File received in Downloads/Vivo Office Kit"
        case "scan_bootstrap_failed", "scan_result_failed", "phone_negotiation_failed", "phone_candidates_unavailable":
            switch code {
            case "timeout", "expired":
                failureHint = "Pairing timed out. Approve access on the phone and scan a new code."
            case "no_usable_lan_endpoint":
                failureHint = "The scanned phone did not provide a reachable Wi-Fi address."
            case "network_or_tls":
                failureHint = "The secure connection could not reach the phone. Check Wi-Fi and Local Network access."
            case "certificate_trust":
                failureHint = "Phone identity verification failed. Start a fresh pairing attempt."
            case "phone_rejected_or_incompatible":
                failureHint = "The phone rejected this connection. Check Office Kit on the phone."
            default:
                failureHint = "Pairing could not finish. Check Wi-Fi, phone approval and try again."
            }
        default:
            break
        }
    }
}

private struct PairStep: View {
    let index: Int
    let title: String
    let description: String
    let progress: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(progress > index ? Color.green.opacity(0.12) :
                          progress == index ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.10))
                    .frame(width: 30, height: 30)
                if progress > index {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text("\(index)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(progress == index ? .accentColor : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: progress == index ? .semibold : .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var session = PairSession.shared

    private var progress: Int {
        switch session.phase {
        case .idle, .preparing, .failed: return 1
        case .scanning: return 1
        case .connecting: return 2
        case .approval: return 3
        case .connected, .stopping: return 4
        }
    }

    private var heading: String {
        switch session.phase {
        case .idle: return "Connect your phone"
        case .preparing: return "Preparing pairing"
        case .scanning: return "Scan this QR code"
        case .connecting: return "Connecting to phone"
        case .approval: return "Approve on your phone"
        case .connected: return "Phone connected"
        case .stopping: return "Disconnecting"
        case .failed: return "Pairing interrupted"
        }
    }

    private var description: String {
        switch session.phase {
        case .idle: return "Pair a compatible vivo phone securely over Wi-Fi."
        case .preparing: return "Creating a fresh secure pairing code…"
        case .scanning: return "Open Office Kit on your phone and scan the code below."
        case .connecting: return "Code scanned. Locating your phone on the local network…"
        case .approval: return "Accept the connection request in Office Kit to continue."
        case .connected: return "Ready for files shared from your phone."
        case .stopping: return "Ending the active connection…"
        case .failed: return "The last attempt ended before a connection was established."
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("PHONE CONNECTION")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(session.connected ? Color.green : session.running ? Color.orange : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(session.connected ? "Connected" : session.running ? "Pairing" : "Offline")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .padding(.bottom, 24)
                Text(heading)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .padding(.bottom, 8)
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                connectionCard
                    .padding(.top, 22)
                    .frame(maxHeight: .infinity, alignment: .top)

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Local Wi-Fi pairing · macOS 13+")
                    Spacer()
                    Text("PREVIEW")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 815, height: 565)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { session.disconnect() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("VOkit")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("for macOS")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 34)

            Text("GET CONNECTED")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
            PairStep(index: 1, title: "Open Office Kit", description: "Use your phone's Office Kit scanner.", progress: progress)
                .padding(.bottom, 22)
            PairStep(index: 2, title: "Scan and connect", description: "Keep both devices on the same Wi-Fi.", progress: progress)
                .padding(.bottom, 22)
            PairStep(index: 3, title: "Approve access", description: "Accept the prompt on your phone.", progress: progress)

            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("Incoming files", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                Text("Shared files arrive in Downloads / Vivo Office Kit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { session.openDownloads() } label: {
                    Label("Open received files", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(22)
        .frame(width: 252)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var connectionCard: some View {
        VStack(spacing: 17) {
            if let qr = session.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 212, height: 212)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 15))
                    .accessibilityLabel("Scan this QR code using vivo Office Kit")
                Label("Waiting for your phone to scan", systemImage: "qrcode.viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 21)
                        .fill(session.connected ? Color.green.opacity(0.10) : Color.accentColor.opacity(0.07))
                        .frame(width: 90, height: 90)
                    if session.connected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 41))
                    } else if session.running && session.phase != .stopping {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: session.phase == .failed ? "wifi.exclamationmark" : "iphone.and.arrow.forward")
                            .font(.system(size: 37))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.top, 20)

                if session.connected {
                    Text(session.recentTransfer ? "File received successfully" : "Connected and ready")
                        .font(.system(size: 15, weight: .semibold))
                } else if session.phase == .failed {
                    Text(session.failureHint ?? "Check Local Network access, Wi-Fi and phone approval.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                    Text("If macOS just asked for Local Network access, allow it and scan a fresh code.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 26)
                } else if !session.running {
                    Text("Your phone is one scan away")
                        .font(.system(size: 15, weight: .semibold))
                    Text("No cable or account sign-in required")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Keep VOkit open while your phone connects")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if session.running {
                    Button(session.phase == .stopping ? "Disconnecting…" : session.connected ? "Disconnect" : "Cancel connection") {
                        session.disconnect()
                    }
                    .disabled(session.phase == .stopping)
                } else {
                    Button {
                        session.connect()
                    } label: {
                        Label(session.phase == .failed ? "Try pairing again" : "Start pairing",
                              systemImage: session.phase == .failed ? "arrow.clockwise" : "qrcode")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if session.connected {
                    Button("Received files") { session.openDownloads() }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 326)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.075)))
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
