import AudioToolbox
import Foundation
import os

/// A single full-duplex audio unit gives the system echo canceller the exact speaker reference.
final class VoiceProcessingAudioIO: @unchecked Sendable {
    private struct Playback {
        var chunks: [Data] = []
        var head = 0
        var offset = 0
        var queued = 0
        var rendered: Int64 = 0
        var playing = false
        var complete = false
        var hasRendered = false
        var gapFrames = 0
        var longestGapFrames = 0
        var gaps = 0
        var firstOutputTime: UInt64?
        var lastOutputTime: UInt64 = 0
    }

    private let output = OSAllocatedUnfairLock(initialState: Playback())
    private let captured = OSAllocatedUnfairLock(initialState: 0)
    private let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(32))
    private var unit: AudioUnit?
    private let sampleCapacity = 8192
    private let input: UnsafeMutablePointer<Int16>
    private let startupBytes: Int
    private(set) var isRunning = false
    var microphone: AsyncStream<Data> { stream.stream }
    var capturedFrames: Int { captured.withLock { $0 } }
    var renderedFrames: Int64 { output.withLock { $0.rendered } }
    var longestGapFrames: Int { output.withLock { $0.longestGapFrames } }
    var gapCount: Int { output.withLock { $0.gaps } }
    var firstOutputTime: UInt64? { output.withLock { $0.firstOutputTime } }
    var speakerRecentlyRendered: Bool {
        let last = output.withLock { $0.lastOutputTime }
        return last != 0 && DispatchTime.now().uptimeNanoseconds - last < 280_000_000
    }

    init(bufferMilliseconds: Int = 240) {
        startupBytes = max(1, bufferMilliseconds) * 48
        input = .allocate(capacity: sampleCapacity)
    }
    deinit { stop(); input.deallocate() }

    func start() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw CocoaError(.featureUnsupported) }
        try check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw CocoaError(.featureUnsupported) }
        do {
            var enabled: UInt32 = 1
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled)
            var format = AudioStreamBasicDescription(mSampleRate: 24_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                mBitsPerChannel: 16, mReserved: 0)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
            try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
            let ref = Unmanaged.passUnretained(self).toOpaque()
            var record = AURenderCallbackStruct(inputProc: { ref, flags, time, bus, frames, _ in
                Unmanaged<VoiceProcessingAudioIO>.fromOpaque(ref).takeUnretainedValue()
                    .capture(flags, time: time, bus: bus, frames: frames)
            }, inputProcRefCon: ref)
            var play = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, buffers in
                guard let destination = buffers?.pointee.mBuffers.mData else { return noErr }
                let bytes = Int(frames) * 2
                Unmanaged<VoiceProcessingAudioIO>.fromOpaque(ref).takeUnretainedValue().render(into: destination, count: bytes)
                buffers?.pointee.mBuffers.mDataByteSize = UInt32(bytes)
                return noErr
            }, inputProcRefCon: ref)
            try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &record)
            try set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &play)
            try check(AudioUnitInitialize(unit))
            try check(AudioOutputUnitStart(unit))
            isRunning = true
        } catch { stop(); throw error }
    }

    private func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ bus: AudioUnitElement, _ value: inout T) throws {
        try withUnsafePointer(to: &value) { pointer in
            try check(AudioUnitSetProperty(unit, property, scope, bus, pointer, UInt32(MemoryLayout<T>.size)))
        }
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>,
                         bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit, frames > 0, frames <= sampleCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
            mDataByteSize: frames * 2, mData: UnsafeMutableRawPointer(input)))
        let status = AudioUnitRender(unit, flags, time, bus, frames, &list)
        if status == noErr, list.mBuffers.mDataByteSize > 0, let bytes = list.mBuffers.mData {
            let count = Int(list.mBuffers.mDataByteSize)
            captured.withLock { $0 += count / 2 }
            stream.continuation.yield(Data(bytes: bytes, count: count))
        }
        return status
    }

    func enqueue(_ data: Data) {
        output.withLock {
            if $0.head > 0 { $0.chunks.removeFirst($0.head); $0.head = 0 }
            $0.chunks.append(data)
            $0.queued += data.count
            $0.complete = false
        }
    }

    func finishEnqueuing() { output.withLock { $0.complete = true } }

    /// A completed short reply plays immediately. Longer streams first build a reserve against network stalls.
    func render(into destination: UnsafeMutableRawPointer, count: Int) {
        destination.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        // The render buffer belongs to this callback and is valid for this synchronous lock only.
        output.withLockUnchecked { state in
            if !state.playing { state.playing = state.queued >= startupBytes || (state.complete && state.queued > 0) }
            guard state.playing else {
                if state.hasRendered && !state.complete { state.gapFrames += count / 2 }
                return
            }
            state.hasRendered = true
            if state.gapFrames > 0 { state.gaps += 1 }
            state.longestGapFrames = max(state.longestGapFrames, state.gapFrames)
            state.gapFrames = 0
            var written = 0
            while written < count && state.head < state.chunks.count {
                let chunk = state.chunks[state.head]
                let length = min(chunk.count - state.offset, count - written)
                chunk.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        destination.advanced(by: written).copyMemory(from: base.advanced(by: state.offset), byteCount: length)
                    }
                }
                written += length
                state.offset += length
                if state.offset == chunk.count { state.head += 1; state.offset = 0 }
            }
            state.queued -= written
            state.rendered += Int64(written / 2)
            if written > 0 {
                state.lastOutputTime = DispatchTime.now().uptimeNanoseconds
                if state.firstOutputTime == nil { state.firstOutputTime = state.lastOutputTime }
            }
            if state.queued == 0 {
                state.playing = false
                if !state.complete { state.gapFrames = (count - written) / 2 }
            }
        }
    }

    func beginItem() {
        output.withLock { $0.hasRendered = false; $0.gapFrames = 0; $0.longestGapFrames = 0; $0.gaps = 0; $0.firstOutputTime = nil }
    }
    func discardPlayback() { output.withLock { $0 = Playback() } }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        isRunning = false
        stream.continuation.finish()
    }
}
