import AppKit
import TiriCore

/// A picture of this copy's own window, for an agent that changed how something looks and has to see it.
/// The window's own views draw it, so macOS is never asked for permission to record the screen. Test copies
/// only: the real app's window belongs to the person using it.
extension AppModel {
    func windowShot(_ request: ControlRequest) async -> ControlResponse {
        guard AppModel.isTestCopy else {
            return .failure(id: request.id, "Only for a test copy. `tiri change look` takes a picture of the copy built from a change.")
        }
        guard let window, let content = window.contentView else { return .failure(id: request.id, "There's no window to take a picture of.") }
        let folder = (RemoteMirror.root as NSString).deletingLastPathComponent + "/Screenshots"
        let path = request.args["path"]?.stringValue ?? folder + "/window-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        // A terminal drawn by the graphics chip keeps its text in a layer no view can draw from. The CPU draws
        // the same text where the picture can see it, so it's used for as long as the picture takes.
        let onMetal = terminalControllers.filter { $0.terminalView.isUsingMetalRenderer }
        // A window nobody can see is never asked for a frame, so what each terminal would draw is brought up to date first.
        for terminal in onMetal { terminal.terminalView.drawMetalFrameNow() }
        for terminal in onMetal { try? terminal.terminalView.setUseMetal(false) }
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        let image: NSImage? = await withCheckedContinuation { continuation in
            WindowPicture.take(CGRect(origin: .zero, size: content.bounds.size), of: window) { image in
                nonisolated(unsafe) let shot = image
                continuation.resume(returning: shot)
            }
        }
        // The window's picture leaves terminals' text out, so each terminal draws its own and it's laid over its place.
        let withText = image.map { picture in
            let root = content.superview ?? content
            let whole = NSImage(size: picture.size)
            whole.lockFocus()
            picture.draw(in: CGRect(origin: .zero, size: picture.size))
            for terminal in terminalControllers {
                let view = terminal.terminalView
                guard view.window === window, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 1, view.bounds.height > 1,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                // Both count from the bottom left here: the picture is the content's size, and the content sits at the bottom of the frame.
                let inRoot = view.convert(view.bounds, to: root)
                let fromBottom = root.isFlipped ? CGRect(x: inRoot.minX, y: root.bounds.height - inRoot.maxY, width: inRoot.width, height: inRoot.height) : inRoot
                let text = NSImage(size: view.bounds.size)
                text.addRepresentation(rep)
                text.draw(in: fromBottom)
            }
            whole.unlockFocus()
            return whole
        }
        for terminal in onMetal { try? terminal.terminalView.setUseMetal(true) }
        guard let image = withText, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return .failure(id: request.id, "Couldn't take a picture of the window.")
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return .failure(id: request.id, "Couldn't write the picture to \(path): \(error.localizedDescription)")
        }
        return .success(id: request.id, .object(["path": .string(path), "width": .int(bitmap.pixelsWide), "height": .int(bitmap.pixelsHigh)]))
    }
}
