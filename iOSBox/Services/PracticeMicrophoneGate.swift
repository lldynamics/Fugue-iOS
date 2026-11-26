import Foundation

/// Suppress short residual speaker echoes after system voice processing. Audio before a real interruption
/// stays in a short lookback, so opening the gate preserves the learner's first consonant.
struct PracticeMicrophoneGate {
    private var backgroundRMS = 0.0015
    private var evidenceFrames = 0
    private var holdFrames = 0
    private var lookback: [Data] = []
    private var lookbackFrames = 0

    mutating func process(_ packet: Data, speakerAudible: Bool) -> Data? {
        let frames = packet.count / 2
        guard frames > 0 else { return nil }
        let rms = packet.withUnsafeBytes { raw -> Double in
            var power = 0.0
            for i in stride(from: 0, to: frames, by: 4) {
                let sample = Double(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768
                power += sample * sample
            }
            return sqrt(power / Double((frames + 3) / 4))
        }
        if !speakerAudible {
            if rms < max(0.008, backgroundRMS * 2) { backgroundRMS += (rms - backgroundRMS) * 0.04 }
            evidenceFrames = 0
            holdFrames = 0
            guard lookbackFrames > 0 else { return packet }
            var audio = Data(repeating: 0, count: lookbackFrames * 2)
            lookback.removeAll(keepingCapacity: true)
            lookbackFrames = 0
            audio.append(packet)
            return audio
        }

        let threshold = max(0.004, min(0.02, backgroundRMS * 3.3))
        if rms >= threshold {
            evidenceFrames = min(2_160, evidenceFrames + frames)
        } else {
            evidenceFrames = max(0, evidenceFrames - frames)
        }
        if evidenceFrames >= 2_160 { holdFrames = 7_200 } // 90 ms of voice opens a 300 ms release.
        if holdFrames > 0 {
            holdFrames = max(0, holdFrames - frames)
            guard !lookback.isEmpty else { return packet }
            var audio = Data(capacity: lookbackFrames * 2 + packet.count)
            for previous in lookback { audio.append(previous) }
            audio.append(packet)
            lookback.removeAll(keepingCapacity: true)
            lookbackFrames = 0
            return audio
        }

        lookback.append(packet)
        lookbackFrames += frames
        guard lookbackFrames > 3_600 else { return nil }
        let oldest = lookback.removeFirst()
        lookbackFrames -= oldest.count / 2
        return Data(repeating: 0, count: oldest.count)
    }
}
