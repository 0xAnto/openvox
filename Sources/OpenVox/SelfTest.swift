import Foundation

/// Pure-logic self-check: no UI, no permissions, no sidecar process. Exits
/// 0 and prints "ok" when every assertion passes. `precondition` (not
/// `assert`) is used throughout so the checks still run under
/// `swift build -c release`, where `assert` is compiled out.
func runSelfTest() {
    testSuffixDiff()
    testNDJSON()
    testChunker()
    testSurrogateChunking()
    testFocusTargetRoles()
    testPartialTyperCancel()
    print("ok")
}

private func testSuffixDiff() {
    precondition(TextInserter.suffixToType(typed: "", full: "hello") == "hello")
    precondition(TextInserter.suffixToType(typed: "hel", full: "hello") == "lo")
    precondition(TextInserter.suffixToType(typed: "hello", full: "hello") == "")
    precondition(TextInserter.suffixToType(typed: "hello", full: "hel") == nil, "full shorter than typed is not a valid prefix extension")
    precondition(TextInserter.suffixToType(typed: "cat", full: "dog") == nil, "mismatch: typed is not a prefix of full")
    precondition(TextInserter.suffixToType(typed: "café", full: "café au lait") == " au lait", "multi-byte UTF-16 prefix must still diff correctly")
    precondition(TextInserter.suffixToType(typed: "hello world", full: "hello") == nil, "full growing shorter is a mismatch, not a valid partial")
}

private func testNDJSON() {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    func roundtrip(_ msg: SidecarOpMessage) -> SidecarOpMessage {
        let data = try! encoder.encode(msg)
        return try! decoder.decode(SidecarOpMessage.self, from: data)
    }
    func roundtripEvent(_ msg: SidecarEventMessage) -> SidecarEventMessage {
        let data = try! encoder.encode(msg)
        return try! decoder.decode(SidecarEventMessage.self, from: data)
    }

    let load = SidecarOpMessage.load(engine: "moonshine")
    precondition(roundtrip(load) == load)
    let loadRaw = String(data: try! encoder.encode(load), encoding: .utf8)!
    precondition(loadRaw.contains(#""op":"load""#) && loadRaw.contains(#""engine":"moonshine""#) && !loadRaw.contains("pcm"))

    let transcribe = SidecarOpMessage.transcribe(pcm: "AAAA")
    precondition(roundtrip(transcribe) == transcribe)

    let stream = SidecarOpMessage.stream(pcm: "AAAA")
    precondition(roundtrip(stream) == stream)

    precondition(roundtrip(.finalize) == .finalize)
    precondition(roundtrip(.ping) == .ping)

    let progress = SidecarEventMessage(ev: "progress", stage: "download", pct: 42, engine: nil, text: nil, message: nil, code: nil)
    precondition(roundtripEvent(progress) == progress)

    let ready = SidecarEventMessage(ev: "ready", stage: nil, pct: nil, engine: "nemotron", text: nil, message: nil, code: nil)
    precondition(roundtripEvent(ready) == ready)

    let partial = SidecarEventMessage(ev: "partial", stage: nil, pct: nil, engine: nil, text: "hello wor", message: nil, code: nil)
    precondition(roundtripEvent(partial) == partial)

    let final = SidecarEventMessage(ev: "final", stage: nil, pct: nil, engine: nil, text: "hello world", message: nil, code: nil)
    precondition(roundtripEvent(final) == final)

    let plainError = SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil, message: "boom", code: nil)
    precondition(roundtripEvent(plainError) == plainError)

    let missingDeps = SidecarEventMessage(ev: "error", stage: nil, pct: nil, engine: nil, text: nil, message: nil, code: "missing-streaming-deps")
    precondition(roundtripEvent(missingDeps) == missingDeps)
    let missingDepsRaw = String(data: try! encoder.encode(missingDeps), encoding: .utf8)!
    precondition(missingDepsRaw.contains(#""code":"missing-streaming-deps""#))

    let pong = SidecarEventMessage(ev: "pong", stage: nil, pct: nil, engine: nil, text: nil, message: nil, code: nil)
    precondition(roundtripEvent(pong) == pong)
}

private func testSurrogateChunking() {
    // "🎉" (U+1F389) is a UTF-16 surrogate pair. Put it exactly on the
    // default 20-unit chunk boundary: 19 plain units, then the pair.
    let emoji = "🎉"
    precondition(Array(emoji.utf16).count == 2, "emoji fixture must be a surrogate pair")
    let text = String(repeating: "a", count: 19) + emoji + "b"

    let chunked = TextInserter.chunks(for: text)
    precondition(chunked.count >= 2, "text longer than 20 units must split")
    precondition(chunked[0].count == 19, "boundary must back off before a lone high surrogate")
    let secondChunk = String(utf16CodeUnits: chunked[1], count: chunked[1].count)
    precondition(secondChunk.hasPrefix(emoji), "the surrogate pair must stay together in the next chunk")

    // Rejoining every chunk must reproduce the exact original text.
    let rejoined = chunked.flatMap { $0 }
    precondition(String(utf16CodeUnits: rejoined, count: rejoined.count) == text)

    // A chunk boundary that doesn't touch a surrogate pair is unaffected.
    let plain = String(repeating: "b", count: 45)
    let plainChunks = TextInserter.chunks(for: plain)
    precondition(plainChunks.map(\.count) == [20, 20, 5])
}

private func testFocusTargetRoles() {
    precondition(FocusTarget.isTextInputRole("AXTextField"))
    precondition(FocusTarget.isTextInputRole("AXTextArea"))
    precondition(FocusTarget.isTextInputRole("AXSearchField"))
    precondition(FocusTarget.isTextInputRole("AXComboBox"))
    precondition(!FocusTarget.isTextInputRole("AXButton"), "a non-text-input role must never be treated as a target")
    precondition(!FocusTarget.isTextInputRole(""), "an empty/unknown role must never be treated as a target")
}

private func testPartialTyperCancel() {
    // Regression smoke test for a bug caught during design: cancelling
    // used to reset state outright, so the orphaned `final` that still
    // arrives afterwards (streaming sends finalize to reset the sidecar's
    // stream state even on cancel) would see typed == "" and retype the
    // entire transcript. cancel() must instead make partial()/final()
    // no-ops without touching `typed`. Exercises the real call sequence
    // (posts harmless CGEvents, same as any --selftest run without
    // Accessibility trust) -- the check is that this never traps.
    let typer = PartialTyper()
    typer.partial("hello")
    typer.cancel()
    typer.partial("hello world") // must be a no-op post-cancel
    typer.final("hello world and more") // must be a no-op post-cancel (but still resets)
    typer.reset()
    typer.partial("fresh utterance") // must behave normally again after reset
}

private func testChunker() {
    // 160 ms @ 16 kHz mono.
    precondition(Int(16000.0 * 0.160) == 2560)
    precondition(AudioCapture.chunkSize == 2560)
    // 150 ms @ 16 kHz mono: the offline accidental-tap guard (item 3).
    precondition(Int(16000.0 * 0.150) == 2400)
    precondition(AudioCapture.minSamplesToTranscribe == 2400)

    // Mirrors AudioCapture's accumulate-then-slice logic in streaming mode.
    var pending: [Float] = []
    var chunksEmitted = 0
    func feed(_ n: Int) {
        pending.append(contentsOf: [Float](repeating: 0, count: n))
        while pending.count >= AudioCapture.chunkSize {
            pending.removeFirst(AudioCapture.chunkSize)
            chunksEmitted += 1
        }
    }
    feed(1000)
    feed(2000) // total 3000 -> 1 chunk, 440 left
    precondition(chunksEmitted == 1 && pending.count == 440)
    feed(2200) // total 2640 -> 1 more chunk, 80 left
    precondition(chunksEmitted == 2 && pending.count == 80)
    feed(0)
    precondition(chunksEmitted == 2, "feeding zero samples must not spuriously emit a chunk")
}
