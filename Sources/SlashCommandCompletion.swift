import Foundation

enum SlashCommandCompletion {
    static func complete(_ value: String, from commands: [String]) -> String? {
        guard value.hasPrefix("/") else { return nil }
        return commands.first { $0.hasPrefix(value) && $0 != value }
    }
}
