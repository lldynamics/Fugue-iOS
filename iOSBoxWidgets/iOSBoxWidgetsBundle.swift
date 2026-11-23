import SwiftUI
import WidgetKit

@main
struct iOSBoxWidgetsBundle: WidgetBundle {
    var body: some Widget {
        IOSBoxGenerationLiveActivity()
        IOSBoxQuickLaunchWidget()
        IOSBoxNewChatControl()
        IOSBoxVoiceNoteControl()
        IOSBoxScanDocumentControl()
        IOSBoxBookmarksControl()
    }
}
