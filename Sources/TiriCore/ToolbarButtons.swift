import Foundation

/// The buttons the toolbar can show beside +, which is always there. Which of them show is a setting.
public enum ToolbarButton: String, CaseIterable, Identifiable, Sendable {
    case start, conversations, addFiles, write, splitRight, splitDown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .start: "Start"
        case .conversations: "Past Conversations"
        case .addFiles: "Add Files"
        case .write: "Write"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        }
    }

    public var symbol: String {
        switch self {
        case .start: "play"
        case .conversations: "clock.arrow.circlepath"
        case .addFiles: "paperclip"
        case .write: "square.and.pencil"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        }
    }

    /// What a new Tiri shows: the ones with no other place in sight.
    public static let defaults: [ToolbarButton] = [.start, .conversations, .write, .splitRight]

    /// The ones named, once each, in the toolbar's own order. A name that isn't a button is dropped.
    public static func tidy(_ names: [String]) -> [ToolbarButton] {
        allCases.filter { names.contains($0.rawValue) }
    }
}
