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

    /// One HAL input unit for the life of the app. The first start() makes
    /// it, after the mic grant. Do not use AVAudioEngine here:
    /// - It reads the mic through a private CADefaultDeviceAggregate that
    ///   holds the default mic, also while the engine is stopped. When that
    ///   mic is a Bluetooth speaker or headset, the device stays in call
    ///   mode (HFP) and mutes music until the app quits (v1.0.18).
    /// - A new engine for each utterance leaves stale listeners on that
    ///   aggregate, and `inputNode` then loops forever on the main thread
    ///   (the v1.0.15 freeze).
    /// The HAL unit binds straight to one device, so no aggregate exists.
    /// stop() stops the unit, which releases the device: the orange mic
    /// indicator clears, and Bluetooth goes back to A2DP in about 3 s.
    private var unit: AudioUnit?
    /// The device that `unit` uses. start() switches the device only when
    /// the wanted device changes.
    private var boundDeviceID: AudioDeviceID?
    /// The render callback pulls each slice of mic audio into this buffer.
    /// start() makes it before the unit starts, so the callback never
    /// allocates it.
    private var inputBuffer: AVAudioPCMBuffer?
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

        let unit = try self.unit ?? makeUnit()
        self.unit = unit

        // The stream format can change only while the unit is not
        // initialized. Read the hardware format on each start: a Bluetooth
        // headset can change its mic format between two utterances (v1.0.17).
        AudioUnitUninitialize(unit)
        // Apply the persisted mic selection before reading the input
        // format: picking a device can change it.
        applyInputDevice(unit: unit)
        // AUHAL does not resample input, so the client side keeps the
        // hardware rate, and AVAudioConverter makes it 16 kHz. AUHAL takes
        // the first channel when the client side asks for one.
        guard let sampleRate = Self.hardwareInputSampleRate(unit: unit),
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.microphoneUnavailable
        }
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                            inputFormat.streamDescription,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        try Self.check(AudioUnitInitialize(unit))

        var maxFrames: UInt32 = 4096
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxFrames)
        self.converter = converter
        do {
            try Self.check(AudioOutputUnitStart(unit))
        } catch {
            self.converter = nil
            throw error
        }
    }

    /// Makes the HAL unit: input on, output off, and a render callback that
    /// pulls the mic audio. The unit is not initialized; start() does that.
    private func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        var made: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &made) == noErr, let unit = made else {
            throw CaptureError.microphoneUnavailable
        }
        var on: UInt32 = 1
        var off: UInt32 = 0
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                                &on, UInt32(MemoryLayout<UInt32>.size)))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                                &off, UInt32(MemoryLayout<UInt32>.size)))
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    /// Runs on the real-time audio thread for each slice of mic audio.
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, let buffer = inputBuffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames // also sets mDataByteSize for AudioUnitRender
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        if status == noErr { process(buffer) }
        return status
    }

    /// The sample rate that the mic hardware runs at. Element 1 is the
    /// input element, and its input scope is the hardware side. Returns nil
    /// for a 0 Hz or 0 channel format: that describes no usable stream.
    private static func hardwareInputSampleRate(unit: AudioUnit) -> Double? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &size) == noErr,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return asbd.mSampleRate
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Stops capture and returns the accumulated utterance (offline mode).
    /// In streaming mode this is empty -- audio already went out as chunks.
    @discardableResult
    func stop() -> [Float] {
        guard let unit, converter != nil else { return [] } // not capturing
        AudioOutputUnitStop(unit) // waits for the last render callback to return
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
    /// effect on a running unit; the next start() applies the value, via
    /// applyInputDevice(unit:).
    func setInputDevice(uid: String?) {
        currentInputUID = uid
    }

    /// Switches the unit to the picked mic, else to the system default mic.
    /// It does nothing when the unit already uses that device. A failed
    /// switch does not change `boundDeviceID`, so the next start() tries
    /// again.
    private func applyInputDevice(unit: AudioUnit) {
        let deviceID: AudioDeviceID
        if let uid = currentInputUID, let resolved = Self.deviceID(forUID: uid) {
            deviceID = resolved
        } else if let defaultDevice = Self.defaultInputDeviceID() {
            deviceID = defaultDevice
        } else {
            return
        }
        guard deviceID != boundDeviceID else { return }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
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

    /// TranslateUIDToDevice takes the UID as qualifier data. It does not
    /// take an AudioValueTranslation: with one, it never found the device,
    /// so the picked mic fell back to the system default.
    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var uidCF: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &uidCF) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }
}
