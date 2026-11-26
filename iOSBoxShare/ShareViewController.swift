import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    private var loadTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        presentContent(AnyView(NavigationStack {
            ProgressView(String(localized: "正在读取分享内容…"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { [weak self] in
                            self?.cancelRequest()
                        }
                    }
                }
        }))
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let input = try await ShareInputLoader.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
                try Task.checkCancellation()
                let store = try SystemEntryStore()
                let models = (try? store.models()) ?? []
                presentContent(AnyView(ReadingComposerView(input: input, models: models, connection: { entry in
                    // Recheck the manifest immediately before sending; revoked entries fail closed.
                    guard try store.models().contains(entry) else { throw SystemEntryError.noModel }
                    return try SharedConnectionKeychain().load(id: entry.connectionID)
                }, persist: { try store.save($0) }, saveDraft: { try store.saveDraft($0) }, close: { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                })))
            } catch is CancellationError {
                return
            } catch {
                presentContent(AnyView(NavigationStack {
                    ContentUnavailableView(String(localized: "无法处理分享"), systemImage: "exclamationmark.triangle",
                                           description: Text(error.localizedDescription))
                        .toolbar { Button("完成") { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) } }
                }))
            }
        }
    }

    private func cancelRequest() {
        loadTask?.cancel()
        loadTask = nil
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func presentContent(_ content: AnyView) {
        children.forEach { child in
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        let host = UIHostingController(rootView: content)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    deinit { loadTask?.cancel() }
}
