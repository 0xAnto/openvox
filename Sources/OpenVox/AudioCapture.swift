import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures mic audio, converts to 16 kHz mono Float32, and either streams
/// fixed 160 ms chunks or accumulates a whole utterance, depending on mode.
final class AudioCapture {
    enum Mode { case streaming, offline }

    /// 160 ms @ 16 kHz mono.
    static let chunkSize = 2560

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var mode: Mode = .offline
    private var pending: [Float] = []
    private var accumulated: [Float] = []
    private var currentInputUID: String?
    private var lastLevelDispatch = Date.distantPast
    private let levelInterval: TimeInterval = 1.0 / 30.0 // throttle level updates to ~30 Hz

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

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        // Re-apply the persisted mic selection every time capture starts:
        // the AVAudioEngine instance is reused across utterances, so a
        // stale device selection would otherwise stick. Must happen while
        // the engine is prepared but not yet running.
        applyInputDevice()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0) // don't leak a tap on a bus we're about to retry
            throw error
        }
    }

    /// Stops capture and returns the accumulated utterance (offline mode).
    /// In streaming mode this is empty -- audio already went out as chunks.
    @discardableResult
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Flush the sub-chunk tail: without this the last <160 ms of
        // speech never reaches the streaming engine. stop() runs on the
        // main thread (called from hotkeyUp before finalize), so this
        // onChunk call is synchronous and ordered before finalize.
        if mode == .streaming, !pending.isEmpty {
            onChunk?(pending)
        }
        let result = accumulated
        accumulated.removeAll()
        pending.removeAll()
        return result
    }

    /// `uid == nil` means "System Default": resolved and set explicitly
    /// (via kAudioHardwarePropertyDefaultInputDevice) rather than left
    /// alone, so switching back to Default actually un-sticks a previous
    /// explicit device pick.
    func setInputDevice(uid: String?) {
        currentInputUID = uid
        applyInputDevice()
    }

    private func applyInputDevice() {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        let deviceID: AudioDeviceID
        if let uid = currentInputUID, let resolved = Self.deviceID(forUID: uid) {
            deviceID = resolved
        } else if let defaultDevice = Self.defaultInputDeviceID() {
            deviceID = defaultDevice
        } else {
            return
        }
        var mutableID = deviceID
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                              &mutableID, UInt32(MemoryLayout<AudioDeviceID>.size))
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
