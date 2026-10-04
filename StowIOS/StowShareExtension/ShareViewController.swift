import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WidgetKit
import StowShared

/// Hosts the share sheet. Saving goes through AppModel into the App Group's data.json and
/// the share inbox, which the app absorbs and uploads the next time it is active.
final class ShareViewController: UIViewController {
    private var host: UIHostingController<ShareSheetView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            guard let (url, sharedTitle) = await sharedLink() else {
                cancel()
                return
            }
            show(url: url, sharedTitle: sharedTitle)
        }
    }

    private func show(url: URL, sharedTitle: String?) {
        let model = ShareSheetModel(
            url: url,
            sharedTitle: sharedTitle,
            store: AppGroup.makeStore(),
            inbox: ShareInbox(),
            fetchTitle: ShareSheetModel.liveTitleFetcher
        )
        let view = ShareSheetView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onSave: { [weak self] in
                Task { @MainActor in
                    await model.saveWhenTitleIsReady()
                    WidgetCenter.shared.reloadAllTimelines()
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            }
        )
        let host = UIHostingController(rootView: view)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    /// The first web URL among the shared items, plus whatever title the sharing app attached.
    private func sharedLink() async -> (URL, String?)? {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            let title = item.attributedContentText?.string ?? item.attributedTitle?.string
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
                   url.scheme?.hasPrefix("http") == true {
                    return (url, title)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true {
                    return (url, title)
                }
            }
        }
        return nil
    }
}
