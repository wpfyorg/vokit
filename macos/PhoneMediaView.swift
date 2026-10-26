import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import VideoToolbox

enum PhoneMediaMode: Equatable {
    case screen
    case camera
}

/// A live preview backed by the connected Go media socket. Starts and stops with
/// `connected`; camera access is still approved on the phone by the Go service.
struct PhoneMediaView: View {
    let connected: Bool
    let mode: PhoneMediaMode
    @StateObject private var model = PhoneMediaModel()

    var body: some View {
        VStack(spacing: 10) {
            if mode == .camera {
                Picker("Camera", selection: $model.facing) {
                    Text("Rear camera").tag("rear")
                    Text("Front camera").tag("front")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
                .disabled(!connected)
            }
            H264Preview(layer: model.layer)
                .aspectRatio(mode == .screen ? 720.0 / 1560.0 : 16.0 / 9.0, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.configure(connected: connected, mode: mode) }
        .onChange(of: connected) { value in model.configure(connected: value, mode: mode) }
        .onChange(of: mode) { value in model.configure(connected: connected, mode: value) }
        .onChange(of: model.facing) { _ in model.configure(connected: connected, mode: mode) }
        .onDisappear { model.stop() }
    }
}

private struct H264Preview: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        layer.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.layer = layer
        layer.videoGravity = .resizeAspect
    }
}

@MainActor
private final class PhoneMediaModel: ObservableObject {
    @Published var status = "Connect the phone to start."
    @Published var facing = "rear"
    let layer = AVSampleBufferDisplayLayer()
    private var worker: DispatchWorkItem?
    private var socketFD: Int32 = -1
    private var generation = 0

    func configure(connected: Bool, mode: PhoneMediaMode) {
        stop()
        guard connected else { status = "Connect the phone to start."; return }
        generation += 1
        let run = generation
        status = mode == .screen ? "Requesting phone screen permission…" : "Requesting phone camera permission…"
        let item = DispatchWorkItem { [weak self] in self?.run(generation: run, mode: mode, facing: self?.facing ?? "rear") }
        worker = item
        DispatchQueue.global(qos: .userInitiated).async(execute: item)
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR); socketFD = -1 }
        layer.flushAndRemoveImage()
    }

    private func report(_ message: String, generation run: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == run else { return }
            self.status = message
        }
    }

    private func run(generation run: Int, mode: PhoneMediaMode, facing: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { report("Phone media service unavailable.", generation: run); return }
        defer {
            DispatchQueue.main.async { [weak self] in
                if self?.socketFD == fd { self?.socketFD = -1 }
                close(fd)
            }
        }
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        let runtimeSocket = runtime.map { "\($0)/vivolinux/media.sock" }
        let path = if let runtimeSocket, runtimeSocket.utf8.count < 100 {
            runtimeSocket
        } else {
            "/tmp/vivolinux-\(getuid())/media.sock"
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            report("Phone media socket path is invalid.", generation: run); return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { report("Phone media service unavailable. Reconnect and retry.", generation: run); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == run else { shutdown(fd, SHUT_RDWR); return }
            self.socketFD = fd
        }
        let request: [String: Any] = mode == .screen
            ? ["source": "screen"]
            : ["source": "camera", "facing": facing, "quality": "720p"]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              writeAll(fd, Data(requestData) + Data([10])) else {
            report("Could not start phone video.", generation: run); return
        }
        var decoder = AnnexBVideoDecoder(layer: layer)
        var buffer = Data()
        var videoStarted = false
        while true {
            if worker?.isCancelled == true { break }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(count))
            while buffer.count >= 5 {
                let kind = buffer[0]
                let size = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
                guard size <= 16 * 1024 * 1024 else { report("Invalid phone video packet.", generation: run); return }
                guard buffer.count >= size + 5 else { break }
                let payload = Data(buffer[5..<(size + 5)])
                buffer.removeSubrange(0..<(size + 5))
                if kind == 2 {
                    if decoder.append(payload) {
                        videoStarted = true
                        report("Live phone video", generation: run)
                    }
                } else if kind == 1 || kind == 3 {
                    if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        if let error = object["error"] as? String { report(error, generation: run) }
                        else if object["stage"] as? String == "permission_wait" { report("Approve access on the phone.", generation: run) }
                        else if object["stage"] as? String == "starting" { report("Starting phone video…", generation: run) }
                    }
                }
            }
        }
        if !videoStarted { report("Phone video stopped. Check permission and reconnect.", generation: run) }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return false }
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
}

/// Converts each Annex-B access unit into length-prefixed samples for VideoToolbox.
private struct AnnexBVideoDecoder {
    let layer: AVSampleBufferDisplayLayer
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var time = CMTime(value: 0, timescale: 30)

    mutating func append(_ bytes: Data) -> Bool {
        let units = nals(bytes)
        for unit in units {
            guard let first = unit.first else { continue }
            switch first & 0x1f {
            case 7: sps = unit
            case 8: pps = unit
            default: break
            }
        }
        if format == nil, let sps, let pps {
            var description: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    var pointers: [UnsafePointer<UInt8>] = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                    var sizes = [sps.count, pps.count]
                    return pointers.withUnsafeMutableBufferPointer { p in
                        sizes.withUnsafeMutableBufferPointer { s in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                        }
                    }
                }
            }
            if status == noErr { format = description }
        }
        guard let format else { return false }
        let pictures = units.filter { unit in guard let type = unit.first.map({ $0 & 0x1f }) else { return false }; return type == 1 || type == 5 }
        guard !pictures.isEmpty else { return false }
        var sample = Data()
        for unit in units where unit.first.map({ ($0 & 0x1f) != 7 && ($0 & 0x1f) != 8 }) == true {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { sample.append(contentsOf: $0) }
            sample.append(unit)
        }
        var block: CMBlockBuffer?
        let blockStatus = sample.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr && CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: sample.count) == kCMBlockBufferNoErr
        }
        guard blockStatus, let block else { return false }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = sample.count
        var buffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard result == noErr, let buffer else { return false }
        layer.enqueue(buffer)
        time = CMTimeAdd(time, timing.duration)
        return true
    }

    private func nals(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        func start(_ i: Int) -> Int {
            if i + 3 < bytes.count && bytes[i...i+3].elementsEqual([0, 0, 0, 1]) { return 4 }
            if i + 2 < bytes.count && bytes[i...i+2].elementsEqual([0, 0, 1]) { return 3 }
            return 0
        }
        var offsets: [(Int, Int)] = []
        var i = 0
        while i < bytes.count {
            let length = start(i)
            if length > 0 { offsets.append((i, length)); i += length } else { i += 1 }
        }
        guard !offsets.isEmpty else { return [] }
        return offsets.indices.compactMap { index in
            let begin = offsets[index].0 + offsets[index].1
            let end = index + 1 < offsets.count ? offsets[index + 1].0 : bytes.count
            return begin < end ? Data(bytes[begin..<end]) : nil
        }
    }
}
