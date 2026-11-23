import AppKit
import TiriCore

extension FileTreeController {
    private func refreshFolders(for node: FileNode?) -> [String] {
        guard let node else { return roots.map(\.path) }
        // A file has no listing of its own to fall behind, so only folders are refreshed.
        return node.isDirectory ? [node.path] : []
    }

    func appendRefreshItem(to menu: NSMenu, node: FileNode?) {
        // Only a server's listing can fall behind: local folders are watched directly.
        let folders = refreshFolders(for: node).filter { RemoteRegistry.shared.isRemote($0) }
        guard !folders.isEmpty else { return }
        let busy = !refreshingFolders.isDisjoint(with: folders)
        let item = NSMenuItem(title: busy ? String(localized: "Refreshing…") : String(localized: "Refresh"),
                              action: #selector(menuRefresh), keyEquivalent: "")
        // A nil target leaves the in-progress entry disabled by AppKit's menu validation.
        item.target = busy ? nil : self
        item.action = busy ? nil : #selector(menuRefresh)
        item.representedObject = node
        menu.addItem(.separator())
        menu.addItem(item)
    }

    @objc func menuRefresh(_ sender: NSMenuItem) {
        let folders = refreshFolders(for: sender.representedObject as? FileNode).filter { RemoteRegistry.shared.isRemote($0) }
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
