import Foundation
import Speech

enum LocalSpeechTranscriber {
    static func resolvedLocale(for languageCode: String?) -> Locale {
        let raw = (languageCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            if let preferred = Locale.preferredLanguages.first?.lowercased(), preferred.hasPrefix("zh") {
                return Locale(identifier: preferred.contains("hant") || preferred.contains("tw") || preferred.contains("hk") ? "zh-TW" : "zh-CN")
            }
            return Locale.current
        }

        let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        switch normalized {
        case "zh", "zh-cn", "zh-hans":
            return Locale(identifier: "zh-CN")
        case "zh-tw", "zh-hant":
            return Locale(identifier: "zh-TW")
        case "zh-hk":
            return Locale(identifier: "zh-HK")
        case "en", "en-us":
            return Locale(identifier: "en-US")
        case "ja", "ja-jp":
            return Locale(identifier: "ja-JP")
        case "ko", "ko-kr":
            return Locale(identifier: "ko-KR")
        default:
            return Locale(identifier: raw.replacingOccurrences(of: "_", with: "-"))
        }
    }

    static func transcribe(
        audioData: Data,
        fileExtension: String,
        languageCode: String? = nil
    ) async throws -> String {
        guard !audioData.isEmpty else {
            throw LLMError.apiError(String(localized: "音频数据为空，无法进行本地识别。"))
        }

        let status = await requestAuthorizationStatus()
        guard status == .authorized else {
            throw LLMError.apiError(String(localized: "请在系统设置中允许“语音识别”权限，或切换到 Whisper 云端接口。"))
        }

        let cleanExt = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let ext = cleanExt.isEmpty ? "m4a" : cleanExt
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fugue-local-asr-\(UUID().uuidString).\(ext)")
        try audioData.write(to: tempURL, options: [.atomic])
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let locale = resolvedLocale(for: languageCode)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw LLMError.apiError(String(localized: "当前系统暂不支持所选语言的本地语音识别。"))
        }
        guard recognizer.isAvailable else {
            throw LLMError.apiError(String(localized: "系统语音识别服务当前不可用，请稍后重试或改用 Whisper 接口。"))
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        configureRecognitionRequest(request, supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition)

        let taskBox = RecognitionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeBox = SingleResumeBox<String>(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        resumeBox.recordPartial(text)
                        if result.isFinal {
                            if text.isEmpty {
                                resumeBox.resume(with: .failure(LLMError.apiError(String(localized: "未识别出有效语音内容。"))))
                            } else {
                                resumeBox.resume(with: .success(text))
                            }
                            return
                        }
                    }

                    if let error {
                        let partial = resumeBox.latestPartial()
                        if !partial.isEmpty {
                            resumeBox.resume(with: .success(partial))
                        } else {
                            resumeBox.resume(with: .failure(error))
                        }
                    }
                }
                taskBox.setTask(task)
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    static func configureRecognitionRequest(
        _ request: SFSpeechURLRecognitionRequest,
        supportsOnDeviceRecognition: Bool
    ) {
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
    }

    private static func requestAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private final class SingleResumeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var bestPartial = ""

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func recordPartial(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        bestPartial = text
        lock.unlock()
    }

    func latestPartial() -> String {
        lock.lock()
        let copy = bestPartial
        lock.unlock()
        return copy
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

private final class RecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var isCancelled = false

    func setTask(_ newTask: SFSpeechRecognitionTask) {
        lock.lock()
        task = newTask
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            newTask.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
}
