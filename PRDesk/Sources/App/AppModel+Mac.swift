import AppKit

/// The Mac's own parts of the model: the mouse's back and forward buttons, and Yab.
extension AppModel {
    /// A mouse's back and forward buttons move through the history like ⌘[ and ⌘].
    func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            let button = event.buttonNumber
            guard button == 3 || button == 4 else { return event }
            MainActor.assumeIsolated {
                if button == 3 { self?.goBack() } else { self?.goForward() }
            }
            return nil
        }
    }

    /// Shows the issue or PR on the tab in front in Yab, bringing the window up.
    func showBrowserTab() {
        Task {
            do {
                guard let tab = try await YabFrontTab.read() else {
                    linkError = "Yab has no tab in front."
                    return
                }
                guard let link = ItemLink(tab.url) ?? ItemLink(pageTitle: tab.title) else {
                    linkError = "The tab in front in Yab isn't an issue or PR of \(SyncEngine.repo):\n\(tab.url)"
                    return
                }
                showWindow?()
                open(link)
            } catch {
                logger.error("Reading Yab's tab failed: \(error.localizedDescription, privacy: .public)")
                linkError = "Couldn't read Yab's tab in front: \(error.localizedDescription)"
            }
        }
    }
}
