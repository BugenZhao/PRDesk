import UIKit
import UniformTypeIdentifiers

/// "Open in PR Desk" in the share sheet: takes the page shared (Safari's, or a link the GitHub
/// app shares) and, if it is a GitHub issue or PR, opens it in the app as
/// `prdesk://open?url=` and the link, which the app reads as any other link (`ExternalLinks`).
/// Which repositories the app shows is the app's to say: here it is only GitHub's shape.
///
/// An extension has no `UIApplication.shared`, and `extensionContext.open` opens nothing from the
/// share sheet; the application is reached up the responder chain instead.
final class OpenActionViewController: UIViewController {
    /// The app's URL scheme, as its Info.plist registers it (Project.swift).
    private static let scheme = "prdesk"

    nonisolated(unsafe) private static let itemPath = /^\/[^\/]+\/[^\/]+\/(?:pull|issues)\/\d+(?:\/.*)?$/

    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private func run() async {
        guard let url = await sharedURL() else {
            showMessage("Nothing to open.")
            return
        }
        guard Self.isItem(url), let target = Self.appURL(for: url) else {
            showMessage("Not a GitHub issue or pull request:\n\(url.absoluteString)")
            return
        }
        if openApp(target) {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            showMessage("Couldn't open PR Desk.")
        }
    }

    private static func isItem(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return false }
        return (try? itemPath.wholeMatch(in: url.path(percentEncoded: false))) != nil
    }

    private static func appURL(for url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }

    /// The first web link among what was shared.
    private func sharedURL() async -> URL? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: URL.self) { continuation.resume(returning: try? $0.get()) }
            }
            if let url, url.scheme == "https" || url.scheme == "http" { return url }
        }
        return nil
    }

    private func openApp(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// Why nothing opened, with a button to go back.
    private func showMessage(_ text: String) {
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        let done = UIButton(configuration: .glass(), primaryAction: UIAction(title: "Done") { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let stack = UIStackView(arrangedSubviews: [label, done])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}
