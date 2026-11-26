import SwiftUI
import UIKit

@MainActor
final class ReplyTextSelection {
    weak var activeView: UITextView?

    var text: String? {
        guard let view = activeView, let range = view.selectedTextRange, !range.isEmpty else { return nil }
        return view.text(in: range)
    }
}

struct ReplySelectionContext {
    let selection: ReplyTextSelection
    let quote: (String) -> Void
}

struct SelectableReplyText: UIViewRepresentable {
    let content: AttributedString
    let size: CGFloat
    let serif: Bool
    let lineSpacing: CGFloat
    var weight: UIFont.Weight = .regular
    var color: UIColor = .label
    let followUp: ReplySelectionContext
    @Environment(\.openURL) private var openURL

    init(_ content: AttributedString, size: CGFloat, serif: Bool, lineSpacing: CGFloat,
         weight: UIFont.Weight, color: UIColor, followUp: ReplySelectionContext) {
        self.content = content
        self.size = size
        self.serif = serif
        self.lineSpacing = lineSpacing
        self.weight = weight
        self.color = color
        self.followUp = followUp
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "reply.paragraph"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        guard view.attributedText.length == 0 || previous.content != content || previous.size != size ||
                previous.serif != serif || previous.lineSpacing != lineSpacing || previous.weight != weight ||
                previous.color != color else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = serif ? (base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor) : base.fontDescriptor
        let styled = NSMutableAttributedString()
        for run in content.runs {
            let intent = run.inlinePresentationIntent ?? []
            let font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: size, weight: weight) : UIFont(descriptor: descriptor, size: size)
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            let renderedFont = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? font
            var attributes: [NSAttributedString.Key: Any] = [.font: renderedFont, .foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let url = run.link { attributes[.link] = url }
            styled.append(NSAttributedString(string: String(content[run.range].characters), attributes: attributes))
        }
        view.attributedText = styled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableReplyText
        init(_ parent: SelectableReplyText) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 {
                parent.followUp.selection.activeView = textView
            } else if parent.followUp.selection.activeView === textView {
                parent.followUp.selection.activeView = nil
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let selected = Range(range, in: textView.text) else { return nil }
            let quote = String(textView.text[selected])
            let followUp = UIAction(title: String(localized: "追问"), image: UIImage(systemName: "quote.opening")) { [weak self] _ in
                self?.parent.followUp.quote(quote)
            }
            return UIMenu(children: [followUp] + suggestedActions)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.parent.openURL(url) }
        }
    }
}
