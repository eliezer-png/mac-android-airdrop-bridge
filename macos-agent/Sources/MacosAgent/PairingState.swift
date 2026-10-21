// Pairing code + issued-token storage. See ../docs/PROTOCOL.md for the pairing flow.

import Foundation

struct PairingRecord: Codable {
    var code: String
    var pairedToken: String?
}

enum PairingStateStore {
    private static var path: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirBridge", isDirectory: true).appendingPathComponent("pairing.json")
    }

    static func loadOrCreate() -> PairingRecord {
        if let data = try? Data(contentsOf: path), let record = try? JSONDecoder().decode(PairingRecord.self, from: data) {
            return record
        }
        let fresh = PairingRecord(code: generateCode(), pairedToken: nil)
        save(fresh)
        return fresh
    }

    static func save(_ record: PairingRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: path)
    }

    /// Regenerates the pairing code and clears any previously issued token, forcing re-pairing.
    static func regenerate() -> PairingRecord {
        let fresh = PairingRecord(code: generateCode(), pairedToken: nil)
        save(fresh)
        return fresh
    }

    private static func generateCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
