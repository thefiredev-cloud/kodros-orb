import XCTest

final class PiClientTests: XCTestCase {
    func testSendReportsDisconnectedClient() {
        let client = PiClient()
        let completed = expectation(description: "send completion")

        client.send(["type": "ping"]) { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected a disconnected-client failure")
                completed.fulfill()
                return
            }
            XCTAssertEqual(error.localizedDescription, "pi is not connected")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }

    func testSendCompletesFromPiResponse() throws {
        let client = PiClient()
        try client.start()
        defer { client.stop() }
        let completed = expectation(description: "RPC response")

        client.send(["type": "ping"]) { result in
            guard case .success(let response) = result else {
                XCTFail("Expected a successful RPC response")
                completed.fulfill()
                return
            }
            let data = response["data"] as? [String: Any]
            XCTAssertEqual(data?["text"] as? String, "pong")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
    }

    func testSendReportsUnencodableCommand() {
        let client = PiClient()
        let completed = expectation(description: "send completion")

        client.send(["invalid": Double.nan]) { result in
            guard case .failure(let error) = result else {
                XCTFail("Expected a JSON encoding failure")
                completed.fulfill()
                return
            }
            XCTAssertEqual(error.localizedDescription, "encode failed")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }
    func testSlashCompletionFindsFirstMatchingCommand() {
        XCTAssertEqual(
            SlashCommandCompletion.complete("/mo", from: ["/model ", "/more"]),
            "/model "
        )
    }

    func testSlashCompletionDoesNotReplaceExactOrNonSlashInput() {
        let commands = ["/help", "/model "]

        XCTAssertNil(SlashCommandCompletion.complete("/help", from: commands))
        XCTAssertNil(SlashCommandCompletion.complete("help", from: commands))
    }

    func testBuildRefusesToSignWithoutConfiguredIdentity() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let appMacOS = root.appendingPathComponent("Kodros Orb.app/Contents/MacOS", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let security = bin.appendingPathComponent("security")
        try "#!/bin/bash\nexit 0\n".write(to: security, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)

        let swiftc = bin.appendingPathComponent("swiftc")
        try """
        #!/bin/bash
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == "-o" ]]; then
            shift
            : > "$1"
            exit 0
          fi
          shift
        done
        exit 1
        """.write(to: swiftc, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swiftc.path)

        let codesignMarker = root.appendingPathComponent("codesign-ran")
        let codesign = bin.appendingPathComponent("codesign")
        try "#!/bin/bash\ntouch '\(codesignMarker.path)'\n".write(
            to: codesign,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path)
        try Data().write(to: root.appendingPathComponent("Info.plist"))
        try fileManager.createDirectory(
            at: root.appendingPathComponent("Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Resources/AppIcon.icns"))
        let buildScript = root.appendingPathComponent("build.sh")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build.sh"),
            to: buildScript
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [buildScript.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("signing identity"))
        XCTAssertFalse(fileManager.fileExists(atPath: codesignMarker.path))
    }

    func testSpeakableKeepsLinkLabelsAndRemovesMarkdown() {
        XCTAssertEqual(
            speakable("## **Hello** `world` [site](https://example.com)"),
            "Hello world site"
        )
    }

    func testSpeakableReplacesCodeBlocksWithReadableMarker() {
        XCTAssertEqual(
            speakable("Before\n```swift\nlet value = 1\n```\nAfter"),
            "Before code block. After"
        )
    }

    func testSpeakableTruncatesLongResponsesAtTheSpeechLimit() {
        let result = speakable(String(repeating: "a", count: 1_501))

        XCTAssertEqual(result, String(repeating: "a", count: 1_500) + " … truncated.")
    }


}

@main
enum PiClientTestRunner {
    static func main() {
        XCTMain([
            testCase([
                ("testSendCompletesFromPiResponse", PiClientTests.testSendCompletesFromPiResponse),
                ("testSendReportsDisconnectedClient", PiClientTests.testSendReportsDisconnectedClient),
                ("testSendReportsUnencodableCommand", PiClientTests.testSendReportsUnencodableCommand),
                ("testSlashCompletionFindsFirstMatchingCommand", PiClientTests.testSlashCompletionFindsFirstMatchingCommand),
                ("testSlashCompletionDoesNotReplaceExactOrNonSlashInput", PiClientTests.testSlashCompletionDoesNotReplaceExactOrNonSlashInput),
                ("testBuildRefusesToSignWithoutConfiguredIdentity", PiClientTests.testBuildRefusesToSignWithoutConfiguredIdentity),
                ("testSpeakableKeepsLinkLabelsAndRemovesMarkdown", PiClientTests.testSpeakableKeepsLinkLabelsAndRemovesMarkdown),
                ("testSpeakableReplacesCodeBlocksWithReadableMarker", PiClientTests.testSpeakableReplacesCodeBlocksWithReadableMarker),
                ("testSpeakableTruncatesLongResponsesAtTheSpeechLimit", PiClientTests.testSpeakableTruncatesLongResponsesAtTheSpeechLimit),
            ]),
        ])
    }
}
