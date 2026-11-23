import AppKit
import TiriCore

extension FileTreeController {
    private func refreshFolders(for node: FileNode?) -> [String] {
        guard let node else { return roots.map(\.path) }
        // A file has no listing of its own to fall behind, so only folders are refreshed.
        return node.isDirectory ? [node.path] : []
    }

    /// The folder and every folder showing its contents beneath it, parents first.
    private func listedFolders(under folder: String) -> [String] {
        var found: [String] = []
        func walk(_ node: FileNode) {
            guard node.isDirectory, node.children != nil else { return }
            found.append(node.path)
            node.children?.forEach(walk)
        }
        func find(_ node: FileNode) {
            if node.path == folder { return walk(node) }
            guard folder.hasPrefix(node.path + "/") else { return }
            node.children?.forEach(find)
        }
        roots.forEach(find)
        return found.isEmpty ? [folder] : found
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
                  connection.map.remote(folder) != nil else {
                reload(under: [folder])
                continue
            }
            guard connection.state.isReady else {
                model?.showToast(title: String(localized: "Not connected to \(SSHConfigFile.displayName(of: connection.destination))."),
                                 detail: nil, symbol: "exclamationmark.triangle", tint: .orange)
                continue
            }
            refreshingFolders.insert(folder)
            // Listing the local mirror alone cannot discover a missed server event. Ask the server
            // about each folder that's showing, removals included, before reusing the tree's
            // expansion-preserving reload. What isn't showing is left for when it's opened and refreshed.
            let name = (folder as NSString).lastPathComponent
            connection.relist(folders: listedFolders(under: folder).compactMap(connection.map.remote)) { [weak self] outcome in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshingFolders.remove(folder)
                    self.reload(under: [folder])
                    switch outcome {
                    case .complete: break
                    case .partial:
                        self.model?.showToast(title: String(localized: "Only part of \(name) could be refreshed"),
                                              detail: String(localized: "Files removed on the server may still be listed."),
                                              symbol: "exclamationmark.triangle", tint: .orange)
                    case .failed:
                        self.model?.showToast(title: String(localized: "Couldn't refresh \(name)"),
                                              detail: String(localized: "\(SSHConfigFile.displayName(of: connection.destination)) didn't list it."),
                                              symbol: "exclamationmark.triangle", tint: .orange)
                    }
                }
            }
        }
    }
}
