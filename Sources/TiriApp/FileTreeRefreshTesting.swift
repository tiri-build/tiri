import AppKit
import TiriCore

extension FileTreeController {
    /// Exercise the real menu and its target without bringing a test window onto the screen.
    func refreshMenuForTest(_ request: ControlRequest) throws -> JSONValue? {
        guard AppModel.isTestCopy, let row = request.args["menuRow"]?.intValue else { return nil }
        guard row >= -1, row < outline.numberOfRows, let menu = contextMenu(forRow: row) else {
            throw ControlHandler.ControlFailure("No explorer row \(row).")
        }
        if request.args["refresh"]?.boolValue == true {
            guard let item = menu.items.first(where: { $0.action == #selector(menuRefresh) }) else {
                throw ControlHandler.ControlFailure("Refresh is unavailable.")
            }
            menu.performActionForItem(at: menu.index(of: item))
        }
        return .object([
            "menu": .array(menu.items.filter { !$0.isSeparatorItem }.map { .string($0.title) }),
            "refreshing": .array(refreshingFolders.sorted().map(JSONValue.string)),
            "selected": .array(selectedNodes().map { .string($0.path) }),
        ])
    }
}
