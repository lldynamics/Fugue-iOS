import Foundation
import SwiftData

/// Repairs assistant messages left in `isStreaming == true` because the app was killed,
/// crashed, or suspended mid-generation. Must run once per launch, before any new
/// generation starts (no stream can legitimately be in flight at that point).
enum InterruptedStreamRecovery {
    static let interruptedNotice = "回复生成被中断（App 已退出或在后台被系统挂起），可点击重试。"

    @discardableResult
    static func run(in container: ModelContainer) -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.isStreaming == true }
        )
        guard let stuckMessages = try? context.fetch(descriptor), !stuckMessages.isEmpty else {
            return 0
        }
        for message in stuckMessages {
            message.isStreaming = false
            if message.errorMessage?.isEmpty ?? true {
                message.errorMessage = interruptedNotice
            }
        }
        try? context.save()
        return stuckMessages.count
    }
}
