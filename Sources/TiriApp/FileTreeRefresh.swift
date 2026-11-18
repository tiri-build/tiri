import AppKit
import TiriCore

extension FileTreeController {
    private func refreshFolders(for node: FileNode?) -> [String] {
        guard let node else { return roots.map(\.path) }
        return [node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent]
    }

    func appendRefreshItem(to menu: NSMenu, node: FileNode?) {
        let folders = refreshFolders(for: node)
        let busy = !refreshingFolders.isDisjoint(with: folders)
        let item = NSMenuItem(title: busy ? String(localized: "Refreshing…") : String(localized: "Refresh"),
                              action: #selector(menuRefresh), keyEquivalent: "")
        // A nil target leaves the in-progress entry disabled by AppKit's menu validation.
        item.target = busy || folders.isEmpty ? nil : self
        item.action = busy || folders.isEmpty ? nil : #selector(menuRefresh)
        item.representedObject = node
        menu.addItem(.separator())
        menu.addItem(item)
    }

    @objc func menuRefresh(_ sender: NSMenuItem) {
        let folders = refreshFolders(for: sender.representedObject as? FileNode)
        for folder in folders where !refreshingFolders.contains(folder) {
            guard let connection = RemoteRegistry.shared.connection(forLocal: folder),
                  let remote = connection.map.remote(folder) else {
                reload(under: [folder])
                continue
            }
            guard connection.state.isReady else {
                model?.showToast(title: String(localized: "Not connected to \(SSHConfigFile.displayName(of: connection.destination))."),
                                 detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
                continue
            }
            refreshingFolders.insert(folder)
            // Listing the local mirror alone cannot discover a missed server event. Wait for the
            // authoritative scan, including removals, before reusing the tree's expansion-preserving reload.
            connection.rescan(folders: [remote]) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshingFolders.remove(folder)
                    self.reload(under: [folder])
                }
            }
        }
    }
}
