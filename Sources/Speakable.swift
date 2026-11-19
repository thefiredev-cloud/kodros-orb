import Foundation

func speakable(_ raw: String) -> String {
    var text = raw
    text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " code block. ", options: .regularExpression)
    text = text.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: "#{1,6}\\s*", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\*\\*|__|\\*|_", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if text.count > 1500 { text = String(text.prefix(1500)) + " … truncated." }
    return text
}
