import SwiftUI
import WidgetKit

struct IOSBoxNewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.iosbox.control.new-chat") {
            ControlWidgetButton(action: QuickNewChatIntent()) {
                Label("新建对话", systemImage: "square.and.pencil")
            }
        }
        .displayName("夜奔 · 新建对话")
        .description("一键打开「夜奔」开始新对话。")
    }
}

struct IOSBoxVoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.iosbox.control.voice-note") {
            ControlWidgetButton(action: QuickVoiceNoteIntent()) {
                Label("录音纪要", systemImage: "waveform.and.mic")
            }
        }
        .displayName("夜奔 · 录音纪要")
        .description("一键打开「夜奔」开始录音并生成纪要。")
    }
}

struct IOSBoxScanDocumentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.iosbox.control.scan-document") {
            ControlWidgetButton(action: QuickScanDocumentIntent()) {
                Label("扫描文档", systemImage: "doc.viewfinder")
            }
        }
        .displayName("夜奔 · 扫描文档")
        .description("一键打开「夜奔」扫描文档并本地 OCR 转文字。")
    }
}

struct IOSBoxBookmarksControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.iosbox.control.bookmarks") {
            ControlWidgetButton(action: QuickBookmarksIntent()) {
                Label("收藏知识库", systemImage: "bookmark.fill")
            }
        }
        .displayName("夜奔 · 收藏知识库")
        .description("一键打开「夜奔」收藏夹。")
    }
}
