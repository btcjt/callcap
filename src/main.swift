// callcap — dual-channel call capture for macOS 13+.
//
// Captures a target app's audio (ScreenCaptureKit) and the microphone
// (AVAudioEngine) into two separate WAV files, plus a JSON sidecar carrying
// the start-time offset between them so they can be aligned downstream.
//
// Deliberately does NOT use a virtual audio driver (BlackHole) or a
// multi-output device: those break volume control, survive as clutter in
// Audio MIDI Setup, and capture every app rather than the one on the call.

import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Utilities

let stderrHandle = FileHandle.standardError

func log(_ message: String) {
    stderrHandle.write("\(message)\n".data(using: .utf8)!)
}

func die(_ message: String, code: Int32 = 1) -> Never {
    log("error: \(message)")
    exit(code)
}

/// mach_absolute_time ticks -> seconds
let machToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000_000.0
}()

// MARK: - TCC responsibility

/// Re-exec self as its own "responsible process".
///
/// macOS attributes a TCC grant to whichever process is deemed responsible for
/// the request. A binary spawned from a shell inherits the terminal as its
/// responsible process, so Screen Recording is checked against Terminal /
/// VS Code / iTerm rather than against this app bundle — the grant on
/// "Call Capture" is then ignored and capture is denied even with the
/// toggle on. Launching via `open` avoids it (launchd becomes the parent), but
/// that costs live stderr and Ctrl-C handling.
///
/// posix_spawn with the private `responsibility_spawnattrs_setdisclaim`
/// attribute plus POSIX_SPAWN_SETEXEC replaces this process with an identical
/// one that owns its own TCC identity. An env marker stops it recursing.
func reexecAsResponsibleProcess() {
    let marker = "CALLCAP_DISCLAIMED"
    guard ProcessInfo.processInfo.environment[marker] == nil else { return }

    typealias SetDisclaim = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_spawnattrs_setdisclaim") else { return }
    let setDisclaim = unsafeBitCast(symbol, to: SetDisclaim.self)

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return }
    defer { posix_spawnattr_destroy(&attributes) }

    let disclaimed = withUnsafeMutablePointer(to: &attributes) {
        setDisclaim(UnsafeMutableRawPointer($0), 1)
    }
    guard disclaimed == 0 else { return }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC))

    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)

    var environment = ProcessInfo.processInfo.environment
    environment[marker] = "1"
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)

    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var pid: pid_t = 0
    _ = posix_spawn(&pid, executable, nil, &attributes, &argv, &envp)
    // SETEXEC replaces the process on success, so reaching here means it
    // failed. Carry on undisclaimed rather than refusing to run.
}

// MARK: - CLI

struct Options {
    var bundleID = ""
    var captureSystemAudio = true
    var outputDir = URL(fileURLWithPath:
        ((ProcessInfo.processInfo.environment["CALLCAP_DIR"]
            ?? "~/Documents/call-recordings") as NSString).expandingTildeInPath)
    var label: String?
    var duration: Double?
    var maxDuration: Double = 3 * 60 * 60
    var silenceTimeout: Double = 5 * 60
    var listApps = false
    var listAudioDevices = false
    var showPermissions = false
    var removeAggregate: String?
    var micDeviceName: String?
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--app", "-a":
            guard let v = it.next() else { die("--app needs a bundle id or app name") }
            o.bundleID = v
            o.captureSystemAudio = false
        case "--system", "-s":
            o.captureSystemAudio = true
        case "--out", "-o":
            guard let v = it.next() else { die("--out needs a directory") }
            o.outputDir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        case "--label", "-l":
            guard let v = it.next() else { die("--label needs a value") }
            o.label = v
        case "--duration", "-d":
            guard let v = it.next(), let d = Double(v) else { die("--duration needs seconds") }
            o.duration = d
        case "--max-duration":
            guard let v = it.next(), let d = Double(v) else { die("--max-duration needs minutes") }
            o.maxDuration = d * 60
        case "--silence-timeout":
            guard let v = it.next(), let d = Double(v) else { die("--silence-timeout needs minutes") }
            o.silenceTimeout = d * 60
        case "--no-auto-stop":
            o.maxDuration = 0
            o.silenceTimeout = 0
        case "--mic":
            guard let v = it.next() else { die("--mic needs a device name") }
            o.micDeviceName = v
        case "--list-apps":
            o.listApps = true
        case "--list-audio-devices":
            o.listAudioDevices = true
        case "--permissions":
            o.showPermissions = true
        case "--remove-aggregate":
            guard let v = it.next() else { die("--remove-aggregate needs a device name") }
            o.removeAggregate = v
        case "--help", "-h":
            print("""
            callcap-rec — record a call as two channels (far end + your mic)

              --app, -a <app>         capture only this app's audio, by bundle id
                                      or name. More precise than the default
                                      when you know which app owns the call.
              --system, -s            capture all system audio (the default)
              --out, -o <dir>         output directory
                                      (default: $CALLCAP_DIR, else
                                      ~/Documents/call-recordings)
              --label, -l <text>      slug appended to the recording name
              --duration, -d <secs>   record exactly N seconds, then stop
              --silence-timeout <min> stop after N minutes with no audio on either
                                      channel (default 5; 0 disables)
              --max-duration <min>    hard cap on a recording (default 180; 0 disables)
              --no-auto-stop          record until Ctrl-C, no matter how long or quiet
              --mic <name>            input device name (default: system default)
              --list-apps             list running apps with audio-capturable bundle ids
              --permissions           report this app's Screen Recording + Microphone
                                      state and request anything missing

            Audio device housekeeping:
              --list-audio-devices    show every CoreAudio device, flagging aggregate
                                      and multi-output devices as removable
              --remove-aggregate <n>  delete an aggregate / multi-output device by name

              --help, -h              this text

            Stop a recording with Ctrl-C. Two WAVs and a .json sidecar are written.
            """)
            exit(0)
        default:
            die("unknown argument: \(arg)")
        }
    }
    return o
}

/// Screen Recording permission is what gates app-audio capture. Without it
/// ScreenCaptureKit throws SCStreamErrorDomain -3801, which is opaque enough
/// to be worth translating.
@available(macOS 13.0, *)
func shareableContent() async -> SCShareableContent {
    do {
        return try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
    } catch {
        let code = (error as NSError).code
        if code == -3801 || code == -3802 {
            log("""
                error: Screen Recording permission is not granted.

                  System Settings > Privacy & Security > Screen & System Audio Recording
                  enable "Call Capture"

                macOS only offers the toggle after the app has asked once, which just
                happened. Opening that pane now — flip the switch, then re-run.
                """)
            _ = try? await NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
                configuration: NSWorkspace.OpenConfiguration())
            exit(2)
        }
        die("could not query shareable content: \(error.localizedDescription)")
    }
}

// MARK: - Recorder

@available(macOS 13.0, *)
final class CallRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    private let options: Options
    private let sessionName: String
    private let farURL: URL
    private let nearURL: URL
    private let metaURL: URL

    private var stream: SCStream?
    private let captureSession = AVCaptureSession()
    private let micOutput = AVCaptureAudioDataOutput()

    private var farFile: AVAudioFile?
    private var nearFile: AVAudioFile?

    /// Host-clock seconds at which each stream produced its first sample.
    private var farStartHost: Double?
    private var nearStartHost: Double?

    private var farFrames: Int64 = 0
    private var farCallbacks: Int = 0

    /// Host-clock seconds when either channel last carried something louder
    /// than room tone. Drives the silence timeout.
    private var lastSoundHost: Double = Double(mach_absolute_time()) * machToSeconds
    private let soundThresholdDB: Float = -45
    private var nearFrames: Int64 = 0

    private let writeQueue = DispatchQueue(label: "com.callcap.write")
    private var finished = false

    init(options: Options) {
        self.options = options
        let stamp = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            return f.string(from: Date())
        }()
        let slug = options.label.map { "_" + $0.replacingOccurrences(of: " ", with: "-") } ?? ""
        self.sessionName = "call_\(stamp)\(slug)"
        let dir = options.outputDir.appendingPathComponent(sessionName)
        self.farURL = dir.appendingPathComponent("far.wav")
        self.nearURL = dir.appendingPathComponent("near.wav")
        self.metaURL = dir.appendingPathComponent("recording.json")
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var sessionDirectory: URL { farURL.deletingLastPathComponent() }

    // MARK: Far end (app audio via ScreenCaptureKit)

    func startAppCapture() async throws {
        let content = await shareableContent()
        guard let display = content.displays.first else {
            die("no display available for capture")
        }

        let filter: SCContentFilter
        let sourceLabel: String

        if options.captureSystemAudio {
            // Everything audible, whatever produces it — the catch-all for web
            // calls, or anything ScreenCaptureKit cannot be pointed at directly.
            filter = SCContentFilter(display: display, excludingApplications: [],
                                     exceptingWindows: [])
            sourceLabel = "all system audio"
        } else {
            // Bundle id first, then app name, so "--app Chrome" works as well as
            // "--app com.google.Chrome".
            let wanted = options.bundleID
            let app = content.applications.first { $0.bundleIdentifier == wanted }
                ?? content.applications.first {
                    $0.applicationName.localizedCaseInsensitiveCompare(wanted) == .orderedSame
                }
                ?? content.applications.first {
                    $0.applicationName.localizedCaseInsensitiveContains(wanted)
                        || $0.bundleIdentifier.localizedCaseInsensitiveContains(wanted)
                }
            guard let app else {
                die("""
                    no running app matches '\(wanted)'.
                    Start it (and join the call) first, --list-apps to see what is running,
                    or --system to capture everything audible.
                    """)
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            sourceLabel = "\(app.applicationName) (\(app.bundleIdentifier))"
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Video is mandatory on the stream config, but we never add a video
        // output, so keep it as close to free as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        try await stream.startCapture()
        self.stream = stream
        log("• capturing audio: \(sourceLabel)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        if ProcessInfo.processInfo.environment["CALLCAP_DEBUG"] != nil, farCallbacks < 8 {
            let f = pcm.format
            log("  [far #\(farCallbacks)] samples=\(CMSampleBufferGetNumSamples(sampleBuffer)) "
                + "frameLength=\(pcm.frameLength) sr=\(f.sampleRate) ch=\(f.channelCount) "
                + "interleaved=\(f.isInterleaved) buffers=\(UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList).count)")
        }
        farCallbacks += 1
        noteAudio(pcm)

        if farFile == nil {
            do {
                farFile = try AVAudioFile(
                    forWriting: farURL,
                    settings: Self.wavSettings(from: pcm.format),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false)
            } catch {
                log("error: cannot open far.wav: \(error)")
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            farStartHost = CMTimeGetSeconds(pts)
        }
        do {
            try farFile?.write(from: pcm)
            farFrames += Int64(pcm.frameLength)
        } catch {
            log("error: far.wav write failed: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("error: app capture stopped: \(error.localizedDescription)")
    }

    // MARK: Near end (microphone via AVAudioEngine)

    /// AVAudioEngine does not fail when Microphone permission is missing — it
    /// starts happily and simply never delivers a buffer, producing a silent
    /// recording with no error anywhere. So ask explicitly first.
    static func ensureMicrophoneAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            die("Microphone permission was declined — your side cannot be recorded.")
        case .denied, .restricted:
            log("""
                error: Microphone permission is denied, so your own voice would not
                be recorded.

                  System Settings > Privacy & Security > Microphone
                  enable "Call Capture"

                Opening that pane now — flip the switch, then re-run.
                """)
            _ = try? await NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!,
                configuration: NSWorkspace.OpenConfiguration())
            exit(2)
        @unknown default:
            return
        }
    }

    /// Captures the microphone with AVCaptureSession rather than AVAudioEngine.
    ///
    /// AVAudioEngine's input tap silently delivered zero buffers here — it
    /// starts without error and simply never fires, which is indistinguishable
    /// from a muted mic. AVCaptureSession is the same subsystem TCC governs,
    /// and it hands back CMSampleBuffers stamped on the host clock, the same
    /// timebase ScreenCaptureKit uses — so the two streams align directly
    /// instead of through a measured offset.
    func startMicCapture() throws {
        let device: AVCaptureDevice
        if let wanted = options.micDeviceName {
            // Match by name and leave the system's default input alone —
            // changing it would reconfigure the machine behind the user's back.
            let available = AVCaptureDevice.devices(for: .audio)
            guard let match = available.first(where: { $0.localizedName == wanted })
                    ?? available.first(where: {
                        $0.localizedName.localizedCaseInsensitiveContains(wanted) }) else {
                die("no input device matching '\(wanted)'. Available: "
                    + available.map(\.localizedName).joined(separator: ", "))
            }
            device = match
        } else {
            guard let fallback = AVCaptureDevice.default(for: .audio) else {
                die("no microphone available")
            }
            device = fallback
        }

        let input = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else { die("cannot use \(device.localizedName)") }
        captureSession.addInput(input)
        micOutput.setSampleBufferDelegate(self, queue: writeQueue)
        guard captureSession.canAddOutput(micOutput) else { die("cannot capture from microphone") }
        captureSession.addOutput(micOutput)
        captureSession.commitConfiguration()
        captureSession.startRunning()

        log("• capturing microphone: \(device.localizedName)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        noteAudio(pcm)

        if nearFile == nil {
            do {
                nearFile = try AVAudioFile(
                    forWriting: nearURL,
                    settings: Self.wavSettings(from: pcm.format),
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false)
            } catch {
                log("error: cannot open near.wav: \(error)")
                return
            }
            nearStartHost = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        do {
            try nearFile?.write(from: pcm)
            nearFrames += Int64(pcm.frameLength)
        } catch {
            log("error: near.wav write failed: \(error)")
        }
    }

    // MARK: Stop

    func stop() async {
        guard !finished else { return }
        finished = true

        if captureSession.isRunning { captureSession.stopRunning() }
        if let stream { try? await stream.stopCapture() }

        // Let any in-flight writes drain before closing the files.
        writeQueue.sync {}
        let farSR = farFile?.fileFormat.sampleRate ?? 48_000
        let nearSR = nearFile?.fileFormat.sampleRate ?? 48_000
        let farCh = farFile?.fileFormat.channelCount ?? 2
        let nearCh = nearFile?.fileFormat.channelCount ?? 1
        farFile = nil
        nearFile = nil

        // Positive offset => the mic started later than the app audio, so the
        // mic track must be delayed by that much to line up.
        var offset = 0.0
        if let f = farStartHost, let n = nearStartHost { offset = n - f }

        let meta: [String: Any] = [
            "session": sessionName,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "app": options.captureSystemAudio ? "system" : options.bundleID,
            "far": ["file": "far.wav", "sampleRate": farSR, "channels": farCh,
                    "frames": farFrames, "seconds": Double(farFrames) / farSR],
            "near": ["file": "near.wav", "sampleRate": nearSR, "channels": nearCh,
                     "frames": nearFrames, "seconds": Double(nearFrames) / nearSR],
            "nearOffsetSeconds": offset,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: metaURL)
        }

        if abs(offset) > 2.0 {
            log(String(format: "warning: streams started %.1fs apart — the transcript is "
                       + "aligned for it, but check the audio device woke up promptly", offset))
        }
        log(String(format: "• far end : %6.1fs  (%@)", Double(farFrames) / farSR, farURL.lastPathComponent))
        log(String(format: "• near end: %6.1fs  (%@)", Double(nearFrames) / nearSR, nearURL.lastPathComponent))
        if farFrames == 0 {
            log("warning: no app audio captured — check Screen Recording permission "
                + "and that the call is actually running in the target app")
        }
        if nearFrames == 0 {
            log("warning: no microphone audio captured — check Microphone permission "
                + "and that the right input device is selected")
        }
        print(sessionDirectory.path)
    }

    // MARK: Helpers

    /// RMS of a buffer in dBFS, or nil when the samples are not float32 —
    /// in which case the caller must assume sound rather than risk stopping a
    /// live call on an unreadable level.
    private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var sum: Float = 0
        var count = 0
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.assumingMemoryBound(to: Float.self)
            for index in 0..<samples { sum += pointer[index] * pointer[index] }
            count += samples
        }
        guard count > 0 else { return nil }
        let rms = sqrt(sum / Float(count))
        return rms > 0 ? 20 * log10(rms) : -Float.infinity
    }

    /// Called from both capture paths; resets the silence clock on real audio.
    private func noteAudio(_ buffer: AVAudioPCMBuffer) {
        guard let level = Self.levelDB(buffer) else {
            lastSoundHost = Double(mach_absolute_time()) * machToSeconds
            return
        }
        if level > soundThresholdDB {
            lastSoundHost = Double(mach_absolute_time()) * machToSeconds
        }
    }

    /// Seconds since either channel last carried audio.
    var silentFor: Double {
        Double(mach_absolute_time()) * machToSeconds - lastSoundHost
    }

    private static func wavSettings(from format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Deep-copies a CMSampleBuffer's audio into an AVAudioPCMBuffer.
    /// The copy matters: the AudioBufferList is only valid for the lifetime of
    /// `withAudioBufferList`, so a no-copy buffer would dangle by the time the
    /// file write runs.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames

        let ok = (try? sampleBuffer.withAudioBufferList { source, _ -> Bool in
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == destination.count else { return false }
            for index in 0..<source.count {
                guard let from = source[index].mData, let to = destination[index].mData else { return false }
                let bytes = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
                to.copyMemory(from: from, byteCount: bytes)
                destination[index].mDataByteSize = UInt32(bytes)
            }
            return true
        }) ?? false

        return ok ? copy : nil
    }

    // MARK: CoreAudio device selection

    private static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let name = deviceName(id) else { return nil }
            return (id, name)
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    static func currentInputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return deviceName(id)
    }

}

// MARK: - Audio device housekeeping

@available(macOS 13.0, *)
enum AudioDevices {
    struct Info {
        let id: AudioDeviceID
        let name: String
        let inputs: Int
        let outputs: Int
        let isAggregate: Bool
        let subDevices: [String]
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func all() -> [Info] {
        // UID -> name, so an aggregate's subdevice list can be shown by name.
        var namesByUID: [String: String] = [:]
        for id in deviceIDs() {
            if let name = string(id, kAudioObjectPropertyName),
               let uid = string(id, kAudioDevicePropertyDeviceUID) {
                namesByUID[uid] = name
            }
        }

        return deviceIDs().compactMap { id -> Info? in
            guard let name = string(id, kAudioObjectPropertyName) else { return nil }
            let aggregate = uint32(id, kAudioDevicePropertyTransportType)
                == kAudioDeviceTransportTypeAggregate
            var subs: [String] = []
            if aggregate,
               let list = composition(id)?[kAudioAggregateDeviceSubDeviceListKey as String]
                   as? [[String: Any]] {
                subs = list.compactMap { entry in
                    guard let uid = entry[kAudioSubDeviceUIDKey as String] as? String else { return nil }
                    return namesByUID[uid] ?? uid
                }
            }
            return Info(id: id, name: name,
                        inputs: channels(id, scope: kAudioDevicePropertyScopeInput),
                        outputs: channels(id, scope: kAudioDevicePropertyScopeOutput),
                        isAggregate: aggregate, subDevices: subs)
        }
    }

    private static func composition(_ id: AudioDeviceID) -> [String: Any]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var dict: CFDictionary?
        let status = withUnsafeMutablePointer(to: &dict) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return dict as? [String: Any]
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func list() {
        let rows = all().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let width = max(28, rows.map(\.name.count).max() ?? 28)
        print("DEVICE".padded(width) + "  IN   OUT   KIND")
        for device in rows {
            let kind: String
            if device.isAggregate {
                let sub = device.subDevices.isEmpty
                    ? "" : "  [" + device.subDevices.joined(separator: " + ") + "]"
                kind = "aggregate/multi-output — REMOVABLE" + sub
            } else {
                kind = "hardware or virtual driver"
            }
            print(device.name.padded(width)
                  + "  \(device.inputs)".padded(5)
                  + "  \(device.outputs)".padded(6)
                  + kind)
        }
    }

    static func remove(named wanted: String) {
        let candidates = all().filter {
            $0.isAggregate && ($0.name == wanted || $0.name.localizedCaseInsensitiveContains(wanted))
        }
        guard !candidates.isEmpty else {
            die("no aggregate or multi-output device matching '\(wanted)'. "
                + "Run --list-audio-devices to see what exists.")
        }
        for device in candidates {
            let status = AudioHardwareDestroyAggregateDevice(device.id)
            if status == noErr {
                print("removed: \(device.name)")
            } else {
                log("error: could not remove '\(device.name)' (OSStatus \(status)) — "
                    + "it may be in use by a running app")
            }
        }
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

// MARK: - Entry point

guard #available(macOS 13.0, *) else {
    die("macOS 13 or newer is required (ScreenCaptureKit audio capture)")
}

reexecAsResponsibleProcess()

let options = parseArgs()

if options.showPermissions {
    // Reported for *this app's* identity, which is the one that matters — the
    // terminal's own grants are irrelevant since the binary disclaims
    // responsibility on launch.
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    let micLabel: String
    switch mic {
    case .authorized:    micLabel = "granted"
    case .denied:        micLabel = "DENIED — enable in Settings > Privacy > Microphone"
    case .restricted:    micLabel = "restricted by policy"
    case .notDetermined: micLabel = "not yet requested"
    @unknown default:    micLabel = "unknown"
    }

    var screenLabel = "granted"
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        screenLabel = "DENIED — enable in Settings > Privacy > Screen & System Audio Recording"
    }

    print("bundle           \(Bundle.main.bundleIdentifier ?? "unknown")")
    print("screen recording \(screenLabel)  (captures the far end)")
    print("microphone       \(micLabel)  (captures your voice)")

    if mic == .notDetermined {
        print("\nrequesting microphone access — click Allow on the dialog…")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        print(granted ? "microphone       granted" : "microphone       DENIED")
    }
    exit(0)
}

if options.listAudioDevices {
    AudioDevices.list()
    exit(0)
}

if let target = options.removeAggregate {
    AudioDevices.remove(named: target)
    exit(0)
}

if options.listApps {
    let content = await shareableContent()
    let rows = content.applications
        .filter { !$0.bundleIdentifier.isEmpty }
        .map { ($0.applicationName, $0.bundleIdentifier) }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    for (name, bundle) in rows {
        print(String(format: "%-34s %@", (name as NSString).utf8String!, bundle))
    }
    exit(0)
}

let recorder = CallRecorder(options: options)

/// Parks the async top-level until capture is done.
///
/// `dispatchMain()` and `RunLoop.main.run()` are both invalid here: main.swift
/// uses `await` at the top level, so this code runs on a Task rather than on
/// the main thread, and either call makes the process exit immediately instead
/// of recording. Awaiting a continuation is the supported way to stay alive.
final class CaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        guard !opened else { return lock.unlock() }
        opened = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

let gate = CaptureGate()

// The signal source runs on its own queue, not `.main`: under async top-level
// nothing is draining the main queue, so a handler scheduled there never fires.
let signalQueue = DispatchQueue(label: "com.callcap.signal")

// SIGHUP and SIGTERM matter as much as SIGINT: closing the terminal window
// sends SIGHUP, and the default action would kill the process mid-write,
// losing the metadata sidecar and leaving the WAVs unfinalised.
let signalSources = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        log("\n• stopping…")
        Task {
            await recorder.stop()
            gate.open()
        }
    }
    source.resume()
    signal(number, SIG_IGN)  // let the source see it instead of dying on it
    return source
}
_ = signalSources

do {
    await CallRecorder.ensureMicrophoneAccess()
    // Microphone first: a Bluetooth headset can take tens of seconds to switch
    // into input mode, and whichever stream starts first accumulates that wait
    // as one-sided audio. Starting the slow side first keeps the two streams
    // within milliseconds of each other.
    try recorder.startMicCapture()
    try await recorder.startAppCapture()
} catch {
    die("could not start capture: \(error.localizedDescription)")
}

log("• recording to \(recorder.sessionDirectory.path)")
func humanDuration(_ seconds: Double) -> String {
    if seconds >= 3600 {
        return String(format: "%.0fh%02.0fm", (seconds / 3600).rounded(.down),
                      seconds.truncatingRemainder(dividingBy: 3600) / 60)
    }
    if seconds >= 60 { return String(format: "%.0fm", seconds / 60) }
    return String(format: "%.0fs", seconds)
}

if let duration = options.duration {
    // Fixed-length capture, used by the smoke test.
    log(String(format: "• recording for %.0fs (Ctrl-C stops early)", duration))
    Task {
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        await recorder.stop()
        gate.open()
    }
} else {
    var notes = ["press Ctrl-C to stop"]
    if options.silenceTimeout > 0 {
        notes.append("auto-stops after \(humanDuration(options.silenceTimeout)) of silence")
    }
    if options.maxDuration > 0 {
        notes.append("max \(humanDuration(options.maxDuration))")
    }
    log("• " + notes.joined(separator: "; "))

    if options.silenceTimeout > 0 || options.maxDuration > 0 {
        let started = Double(mach_absolute_time()) * machToSeconds
        Task {
            // Poll rather than schedule: the deadline moves every time audio
            // arrives, and a 5s granularity is far finer than the minutes-scale
            // timeouts it is enforcing.
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let elapsed = Double(mach_absolute_time()) * machToSeconds - started

                if options.maxDuration > 0, elapsed >= options.maxDuration {
                    log("\n• stopping: reached the \(humanDuration(options.maxDuration)) limit")
                    await recorder.stop()
                    gate.open()
                    return
                }
                if options.silenceTimeout > 0, await recorder.silentFor >= options.silenceTimeout {
                    log("\n• stopping: \(humanDuration(options.silenceTimeout)) with no audio "
                        + "on either channel")
                    await recorder.stop()
                    gate.open()
                    return
                }
            }
        }
    }
}

await gate.wait()
exit(0)
