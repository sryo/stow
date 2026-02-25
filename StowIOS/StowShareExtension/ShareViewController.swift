import UIKit
import UniformTypeIdentifiers
import StowShared

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            completeRequest()
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, error in
                        guard let url = item as? URL else {
                            self?.completeRequest()
                            return
                        }
                        self?.saveLink(url: url)
                    }
                    return
                }
            }
        }

        completeRequest()
    }

    private func saveLink(url: URL) {
        let baseDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.stow.app"
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stow")

        let store = DataStore(baseDirectory: baseDir)
        var state = store.load()

        // Add link to first workspace
        if !state.workspaces.isEmpty {
            let link = StowShared.Link(
                id: UUID(),
                title: url.host ?? url.absoluteString,
                url: url.absoluteString,
                faviconPath: nil
            )
            state.workspaces[0].items.append(.link(link))
            store.save(state)
        }

        completeRequest()
    }

    private func completeRequest() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
