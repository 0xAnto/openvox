import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures mic audio, converts to 16 kHz mono Float32, and either streams
/// fixed 160 ms chunks or accumulates a whole utterance, depending on mode.
final class AudioCapture {
    enum Mode { case streaming, offline }

    struct CaptureError: LocalizedError {
        let errorDescription: String?
        static let microphoneUnavailable = CaptureError(errorDescription: "Microphone unavailable")
    }

    /// 160 ms @ 16 kHz mono.
    static let chunkSize = 2560
    /// 150 ms @ 16 kHz mono: below this, an offline utterance is treated as
    /// an accidental tap, not real speech (see AppDelegate.finishDictation).
    static let minSamplesToTranscribe = 2400

    /// One engine for the life of the app. The first start() makes it.
    /// A new engine for each utterance creates and destroys a CoreAudio IO
    /// unit each time. Sometimes a destroyed IO unit leaves a device
    /// listener behind. The next IO unit at the same address then fails
    /// its device switch, and `inputNode` loops forever on the main thread
    /// (the v1.0.15 freeze). start() runs only after the mic grant:
    /// `inputNode` before the TCC prompt resolves wedges the format at
    /// 0 Hz. stop() stops the IO, so the orange mic indicator still clears
    /// between utterances.
    private var engine: AVAudioEngine?
    /// The device that the IO unit of `engine` uses. start() switches the
    /// device only when the wanted device changes.
    private var boundDeviceID: AudioDeviceID?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var mode: Mode = .offline
    private var pending: [Float] = []
    private var accumulated: [Float] = []
    private var currentInputUID: String?
    private var lastLevelDispatch = Date.distantPast
    private let levelInterval: TimeInterval = 1.0 / 30.0 // throttle level updates to ~30 Hz

    /// Number of streaming chunks handed to onChunk this utterance (plus
    /// the tail flush in stop()). Used in place of a wall-clock guard: a
    /// quick toggle-mode tap that never sends a chunk skips finalize.
    private(set) var chunkCount = 0

    /// Called directly from the audio render thread. Must not touch
    /// AppState/AppKit; the receiver hands raw samples straight to
    /// SidecarClient's write queue.
    var onChunk: (([Float]) -> Void)?
    /// Called on main (see `process`), already throttled.
    var onLevel: ((Float) -> Void)?

    func start(mode: Mode) throws {
        self.mode = mode
        pending.removeAll()
        accumulated.removeAll()
        chunkCount = 0

        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine

        // Apply the persisted mic selection before reading the input
        // format: picking a device can change it.
        applyInputDevice(engine: engine)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            // A 0 Hz format can stay wedged. The next start() makes a new engine.
            self.engine = nil
            boundDeviceID = nil
            throw CaptureError.microphoneUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0) // don't leak a tap on a bus we're about to retry
            self.converter = nil
            throw error
        }
    }

    /// Stops capture and returns the accumulated utterance (offline mode).
    /// In streaming mode this is empty -- audio already went out as chunks.
    @discardableResult
    func stop() -> [Float] {
        guard let engine, converter != nil else { return [] } // not capturing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        // Flush the sub-chunk tail: without this the last <160 ms of
        // speech never reaches the streaming engine. stop() runs on the
        // main thread (called before finalize), so this onChunk call is
        // synchronous and ordered before finalize.
        if mode == .streaming, !pending.isEmpty {
            onChunk?(pending)
            chunkCount += 1
        }
        let result = accumulated
        accumulated.removeAll()
        pending.removeAll()
        return result
    }

    /// `uid == nil` means "System Default". Pure state store -- has no side
    /// effect on any live engine; the next start() applies the value, via
    /// applyInputDevice(engine:).
    func setInputDevice(uid: String?) {
        currentInputUID = uid
    }

    /// Switches the IO unit to the picked mic, else to the system default
    /// mic. It does nothing when the unit already uses that device. A
    /// failed switch does not change `boundDeviceID`, so the next start()
    /// tries again on the same IO unit. Do not make a new engine after a
    /// failed switch: the new IO unit can get the address of the old one
    /// and hang.
    private func applyInputDevice(engine: AVAudioEngine) {
        let deviceID: AudioDeviceID
        if let uid = currentInputUID, let resolved = Self.deviceID(forUID: uid) {
            deviceID = resolved
        } else if let defaultDevice = Self.defaultInputDeviceID() {
            deviceID = defaultDevice
        } else {
            return
        }
        guard deviceID != boundDeviceID, let audioUnit = engine.inputNode.audioUnit else { return }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &mutableID, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr { boundDeviceID = deviceID }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))

        // This runs on the real-time audio render thread: never touch
        // AppState/AppKit here. Level updates hop to main (throttled);
        // chunks go straight to the onChunk closure, which only hands them
        // to SidecarClient's own write queue (see SidecarClient.stream).
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        let now = Date()
        if now.timeIntervalSince(lastLevelDispatch) >= levelInterval {
            lastLevelDispatch = now
            DispatchQueue.main.async { [weak self] in self?.onLevel?(rms) }
        }

        switch mode {
        case .offline:
            accumulated.append(contentsOf: samples)
        case .streaming:
            pending.append(contentsOf: samples)
            while pending.count >= Self.chunkSize {
                let chunk = Array(pending.prefix(Self.chunkSize))
                pending.removeFirst(Self.chunkSize)
                onChunk?(chunk)
                chunkCount += 1
            }
        }
    }

    // MARK: - Device enumeration (CoreAudio)

    static func inputDevices() -> [(uid: String, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [(String, String)] = []
        for id in deviceIDs {
            guard hasInputChannels(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { continue }
            result.append((uid, name))
        }
        return result
    }

    /// Name of the device macOS records from right now. The Settings picker
    /// puts it next to "System Default", so the row says which mic that is.
    static func defaultInputName() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return false }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, listPtr) == noErr else { return false }
        let bufferList = listPtr.assumingMemoryBound(to: AudioBufferList.self)
        let channels = UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var uidCF: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr -> OSStatus in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPtr -> OSStatus in
                var translation = AudioValueTranslation(
                    mInputData: uidPtr,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: deviceIDPtr,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)
            }
        }
        return status == noErr ? deviceID : nil
    }
}
