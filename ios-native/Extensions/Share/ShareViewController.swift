import IlyichShareInbox
import UIKit

/// The share sheet's page. Staging the files is ShareStaging's job; this only shows its progress
/// and hands over to the app.
@MainActor final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let continueButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var operation: Task<Void, Never>?
    private var staging: ShareStaging?
    private var saved = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.text = "Continue in Ilyich to choose files and upload. Your files stay available if you need to sign in first."
        continueButton.setTitle("Continue in Ilyich", for: .normal)
        continueButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        let title = UILabel(); title.text = "Ilyich"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [title, message, continueButton, cancelButton])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func close() {
        operation?.cancel()
        let staging = staging
        Task {
            // An unsaved batch is deleted before the extension goes away.
            await staging?.discard()
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @objc private func start() {
        if saved { openApp(); return }
        guard operation == nil else { return }
        continueButton.isEnabled = false
        operation = Task {
            do {
                let staging = try self.staging ?? ShareStaging(repository: ShareInboxRepository.appGroup())
                self.staging = staging
                let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                _ = try await staging.stage(providers) { index, count in
                    self.message.text = "Preparing \(index + 1) of \(count)"
                }
                try Task.checkCancellation()
                saved = true
                cancelButton.setTitle("Done", for: .normal)
                openApp()
            } catch is CancellationError { }
            catch {
                message.text = error.localizedDescription
                continueButton.setTitle("Try again", for: .normal)
            }
            continueButton.isEnabled = true; operation = nil
        }
    }

    private func openApp() {
        guard let url = URL(string: "immich://share") else { return }
        extensionContext?.open(url) { opened in
            Task { @MainActor in
                if opened { self.extensionContext?.completeRequest(returningItems: nil) }
                else { self.message.text = "Your files are saved. Open Ilyich to review and upload them." }
            }
        }
    }
}
