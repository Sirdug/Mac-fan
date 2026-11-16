// Signs releases for the in-app updater. Used by Scripts/release.sh.
//
//   swift Scripts/update-tool.swift generate <key-file>     make a new signing key, print its public half
//   swift Scripts/update-tool.swift public <key-file>       print the public half of an existing key
//   swift Scripts/update-tool.swift manifest <key-file> <zip> <version> <build> <url> <min-os> <notes>
//                                                            print the update feed JSON for a zip
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-tool: \(message)\n".utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("can't read a signing key from \(path)")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate" where arguments.count == 2:
    let path = arguments[1]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists") }
    let key = Curve25519.Signing.PrivateKey()
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    // Readable only by you: anyone with this file can sign updates your app will install.
    guard FileManager.default.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
        fail("can't write \(path)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public" where arguments.count == 2:
    print(loadKey(arguments[1]).publicKey.rawRepresentation.base64EncodedString())

case "manifest" where arguments.count == 8:
    let key = loadKey(arguments[1])
    guard let zip = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else { fail("can't read \(arguments[2])") }
    guard let build = Int(arguments[4]) else { fail("build must be a number") }
    guard let signature = try? key.signature(for: zip) else { fail("signing failed") }
    var manifest: [String: Any] = [
        "version": arguments[3],
        "build": build,
        "url": arguments[5],
        "minimumSystemVersion": arguments[6],
        "signature": signature.base64EncodedString(),
    ]
    if !arguments[7].isEmpty { manifest["notes"] = arguments[7] }
    let json = try! JSONSerialization.data(
        withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    print(String(decoding: json, as: UTF8.self))

default:
    fail("usage: update-tool.swift generate|public <key-file> | manifest <key-file> <zip> <version> <build> <url> <min-os> <notes>")
}
