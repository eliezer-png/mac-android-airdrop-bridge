// Generates (once) and loads a self-signed TLS identity for the agent's listener.
//
// No CA, no system trust - the Android app pins this cert's fingerprint on first pairing
// (trust-on-first-use), per ../docs/PROTOCOL.md. Generation shells out to the system `openssl`
// (LibreSSL, present on every Mac) rather than hand-building X.509 in Swift - far less code,
// and this only ever runs once per install.

import Foundation
import Security
import os

private let identityLogger = Logger(subsystem: "com.airbridge.macos-agent", category: "tls")

enum TLSIdentityError: Error {
    case opensslFailed(String)
    case pkcs12ImportFailed(OSStatus)
    case noIdentityInImportResult
}

struct AgentTLSIdentity {
    let secIdentity: SecIdentity
    /// Hex-encoded SHA-256 fingerprint of the certificate, shown/advertised for the Android
    /// side to pin.
    let fingerprintHex: String
}

enum TLSIdentityStore {
    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirBridge", isDirectory: true)
    }

    private static var p12Path: URL { supportDirectory.appendingPathComponent("identity.p12") }
    private static var certPath: URL { supportDirectory.appendingPathComponent("cert.pem") }
    private static var keyPath: URL { supportDirectory.appendingPathComponent("key.pem") }

    /// Fixed, local-only passphrase for the PKCS12 container itself (not a secret the user
    /// needs to know - it only protects the file at rest on this same machine, where the
    /// private key file would be just as sensitive either way).
    private static let p12Passphrase = "airbridge-local"

    static func loadOrCreate() throws -> AgentTLSIdentity {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: p12Path.path) {
            try generateSelfSignedIdentity()
        }

        let p12Data = try Data(contentsOf: p12Path)
        var importResult: CFArray?
        let status = SecPKCS12Import(
            p12Data as CFData,
            [kSecImportExportPassphrase as String: p12Passphrase] as CFDictionary,
            &importResult
        )
        guard status == errSecSuccess, let items = importResult as? [[String: Any]], let first = items.first else {
            throw TLSIdentityError.pkcs12ImportFailed(status)
        }
        guard let identityRef = first[kSecImportItemIdentity as String] else {
            throw TLSIdentityError.noIdentityInImportResult
        }
        // swiftlint-disable-next-line force_cast - SecPKCS12Import's own documented result shape
        let secIdentity = identityRef as! SecIdentity

        let fingerprint = try sha256Fingerprint(ofCertificateAt: certPath)
        return AgentTLSIdentity(secIdentity: secIdentity, fingerprintHex: fingerprint)
    }

    private static func generateSelfSignedIdentity() throws {
        identityLogger.info("Generating new self-signed TLS identity")
        // keyUsage=digitalSignature is required here, not optional: without an explicit Key
        // Usage extension, Keychain imports the resulting private key with a CSSM attribute
        // mask that lacks signing capability, and the TLS 1.3 handshake's CertificateVerify
        // step fails with CSSMERR_CSP_INVALID_KEYATTR_MASK - confirmed by hitting this
        // exact failure during real end-to-end testing before adding this extension.
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-days", "3650",
            "-subj", "/CN=AirBridge Mac Agent",
            "-addext", "keyUsage=digitalSignature,keyEncipherment",
        ])
        try runOpenSSL([
            "pkcs12", "-export",
            "-out", p12Path.path,
            "-inkey", keyPath.path,
            "-in", certPath.path,
            "-passout", "pass:\(p12Passphrase)",
        ])
    }

    private static func sha256Fingerprint(ofCertificateAt path: URL) throws -> String {
        let output = try runOpenSSLCapturingOutput([
            "x509", "-in", path.path, "-noout", "-fingerprint", "-sha256",
        ])
        // Output looks like: "sha256 Fingerprint=AA:BB:CC:...\n"
        guard let equalsIndex = output.firstIndex(of: "=") else {
            throw TLSIdentityError.opensslFailed("Unexpected fingerprint output: \(output)")
        }
        let hexWithColons = output[output.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hexWithColons.replacingOccurrences(of: ":", with: "").lowercased()
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        _ = try runOpenSSLCapturingOutput(arguments)
    }

    @discardableResult
    private static func runOpenSSLCapturingOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? "(no output)"
            throw TLSIdentityError.opensslFailed(errorText)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
