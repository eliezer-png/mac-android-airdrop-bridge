// TLS listener + the one direction implemented in this pass: pairing, and pushing a file down
// the already-paired connection. See ../docs/PROTOCOL.md for the full design and what is
// explicitly NOT yet implemented (the reverse, Android -> Mac direction).

import Foundation
import Network
import os

private let serverLogger = Logger(subsystem: "com.airbridge.macos-agent", category: "server")

struct WireMessage: Codable {
    var type: String
    var code: String?
    var ok: Bool?
    var token: String?
    var filename: String?
    var bodyLength: Int?
    var message: String?
    var listenPort: Int?
}

enum WireError: Error {
    case connectionClosed
}

extension NWConnection {
    func syncSend(_ data: Data) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?
        send(content: data, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        semaphore.wait()
        if let sendError { throw sendError }
    }

    func syncReceive(maximumLength: Int = 65536) throws -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        var isComplete = false
        receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
            resultData = data
            resultError = error
            isComplete = complete
            semaphore.signal()
        }
        semaphore.wait()
        if let resultError { throw resultError }
        if isComplete && (resultData == nil || resultData!.isEmpty) { return nil }
        return resultData
    }
}

/// Accumulates bytes from a connection so the line-based header and the raw body that follows
/// it can both be read out of the same underlying stream.
final class ConnectionBuffer {
    private var buffer = Data()
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func readLine() throws -> Data {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return Data(line)
            }
            guard let chunk = try connection.syncReceive() else {
                throw WireError.connectionClosed
            }
            buffer.append(chunk)
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        while buffer.count < count {
            guard let chunk = try connection.syncReceive() else {
                throw WireError.connectionClosed
            }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }
}

func sendMessage(_ message: WireMessage, on connection: NWConnection) throws {
    var payload = try JSONEncoder().encode(message)
    payload.append(0x0A)
    try connection.syncSend(payload)
}

func readMessage(_ buffer: ConnectionBuffer) throws -> WireMessage {
    let line = try buffer.readLine()
    return try JSONDecoder().decode(WireMessage.self, from: line)
}

final class AgentServer {
    private var listener: NWListener?
    private var pairingRecord: PairingRecord
    private let identity: AgentTLSIdentity
    /// v1 scope: a single paired Android device, kept as the one connection from pairing.
    private var pairedConnection: NWConnection?
    /// Serializes access to `pairingRecord`/`pairedConnection`: `pushFile` reads them from
    /// whatever queue called it (the FSEvents callback runs on .main; the manual "Send File to
    /// Phone…" menu action also runs on .main), while every handshake path
    /// (`handlePairRequest`/`handleReconnect`/`handleIncomingFilePush`) mutates them from
    /// `.global()`. Without this, a reconnect landing mid-push could read a half-updated
    /// `pairedConnection` - this was a real, observed bug (not hypothetical): a push would grab
    /// the about-to-be-replaced connection just as a concurrent reconnect cancelled it, failing
    /// with "Operation canceled" even though the new connection was perfectly healthy.
    private let stateQueue = DispatchQueue(label: "com.airbridge.macos-agent.state")
    /// Called (off the main queue - caller is responsible for hopping to main if needed) with
    /// the path of a file pushed from Android, i.e. the Android -> Mac direction. See
    /// handleIncomingFilePush below and docs/PROTOCOL.md.
    private let onFileReceived: (URL) -> Void

    init(identity: AgentTLSIdentity, onFileReceived: @escaping (URL) -> Void) {
        self.identity = identity
        self.onFileReceived = onFileReceived
        self.pairingRecord = PairingStateStore.loadOrCreate()
    }

    var currentPairingCode: String { stateQueue.sync { pairingRecord.code } }
    var isPaired: Bool { stateQueue.sync { pairedConnection != nil } }

    func regeneratePairingCode() {
        stateQueue.sync {
            pairingRecord = PairingStateStore.regenerate()
            pairedConnection?.cancel()
            pairedConnection = nil
        }
    }

    func start() {
        let tlsOptions = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.secIdentity) else {
            serverLogger.error("Failed to wrap SecIdentity for Network.framework")
            return
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)

        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        parameters.includePeerToPeer = false

        guard let port = NWEndpoint.Port(rawValue: 47835),
              let listener = try? NWListener(using: parameters, on: port)
        else {
            serverLogger.error("Failed to create listener on port 47835")
            return
        }

        var txtRecord = NWTXTRecord()
        txtRecord["fp"] = identity.fingerprintHex
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "AirBridge Mac Agent",
            type: "_airbridge._tcp",
            txtRecord: txtRecord
        )

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: .global())
        self.listener = listener
        serverLogger.info("Listening on port 47835, fingerprint \(self.identity.fingerprintHex, privacy: .public)")
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.global().async {
                    self?.handleHandshake(connection)
                }
            }
        }
        connection.start(queue: .global())
    }

    /// First message on any new connection is one of:
    /// - `pair_request` - first-ever pairing.
    /// - `reconnect` - the app's foreground Service (re)connecting with an already-issued token;
    ///   covers both "just paired" and "app relaunched, already paired" since neither case can
    ///   reuse a single already-closed socket across process/Service boundaries.
    /// - `file_push` - Android -> Mac direction (share-target send). Unlike `reconnect`, this
    ///   connection is short-lived: Android opens it just for this one file, per
    ///   docs/PROTOCOL.md, so it is not adopted as `pairedConnection`.
    private func handleHandshake(_ connection: NWConnection) {
        let buffer = ConnectionBuffer(connection: connection)
        do {
            let message = try readMessage(buffer)
            switch message.type {
            case "pair_request":
                try handlePairRequest(message, on: connection)
            case "reconnect":
                try handleReconnect(message, on: connection)
            case "file_push":
                try handleIncomingFilePush(message, buffer, on: connection)
            default:
                try? sendMessage(WireMessage(type: "error", message: "unexpected message type"), on: connection)
                connection.cancel()
            }
        } catch {
            serverLogger.error("Handshake failed: \(String(describing: error), privacy: .public)")
            connection.cancel()
        }
    }

    private func handlePairRequest(_ message: WireMessage, on connection: NWConnection) throws {
        let expectedCode = stateQueue.sync { pairingRecord.code }
        guard message.code == expectedCode else {
            try? sendMessage(WireMessage(type: "error", message: "invalid code"), on: connection)
            connection.cancel()
            return
        }
        let token = stateQueue.sync { () -> String in
            let token = pairingRecord.pairedToken ?? UUID().uuidString
            pairingRecord.pairedToken = token
            PairingStateStore.save(pairingRecord)
            return token
        }
        try sendMessage(WireMessage(type: "pair_response", ok: true, token: token), on: connection)
        serverLogger.info("Paired with a client")
        adoptAsPairedConnection(connection)
    }

    private func handleReconnect(_ message: WireMessage, on connection: NWConnection) throws {
        let expectedToken = stateQueue.sync { pairingRecord.pairedToken }
        guard let token = message.token, token == expectedToken else {
            try? sendMessage(WireMessage(type: "error", message: "invalid token"), on: connection)
            connection.cancel()
            return
        }
        try sendMessage(WireMessage(type: "reconnect_ack", ok: true), on: connection)
        serverLogger.info("Reconnected with paired client")
        adoptAsPairedConnection(connection)
    }

    /// Android -> Mac direction: a one-shot push over its own short-lived connection (not the
    /// long-held `pairedConnection`). Saves the body directly into ~/Downloads - the Mac is the
    /// final destination for this direction, mirroring how Mac->Android just lands the file in
    /// the phone's Downloads with no extra step.
    private func handleIncomingFilePush(_ message: WireMessage, _ buffer: ConnectionBuffer, on connection: NWConnection) throws {
        let expectedToken = stateQueue.sync { pairingRecord.pairedToken }
        guard let token = message.token, token == expectedToken else {
            try? sendMessage(WireMessage(type: "error", message: "invalid token"), on: connection)
            connection.cancel()
            return
        }
        let bodyLength = message.bodyLength ?? 0
        let data = try buffer.readExactly(bodyLength)

        // Strip any directory components from the Android-supplied filename before using it
        // as a path component - this is untrusted input arriving over the network.
        let safeFilename = (message.filename as NSString?)?.lastPathComponent ?? "received_file"
        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniquePath(for: safeFilename, in: downloadsDirectory)
        try data.write(to: destination)

        try sendMessage(WireMessage(type: "ack", ok: true), on: connection)
        connection.cancel()
        serverLogger.info("Received \(safeFilename, privacy: .public) from paired client, saved to Downloads")
        onFileReceived(destination)
    }

    /// Avoids silently overwriting an unrelated same-named file already in Downloads - appends
    /// " (n)" before the extension, same convention Android's MediaStore insert uses.
    private static func uniquePath(for filename: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 1
        repeat {
            let suffixed = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private func adoptAsPairedConnection(_ connection: NWConnection) {
        stateQueue.sync {
            pairedConnection?.cancel()
            pairedConnection = connection
        }
        // Connection stays open; Android never writes again after this handshake (see
        // docs/PROTOCOL.md), so there is nothing further to read here. pushFile() uses
        // this same connection later, inline, from the FSEvents callback.
    }

    /// Pushes a file to the paired Android device over the connection kept open since
    /// pairing. Called either from the FSEvents callback or from a manual "Send File to
    /// Phone…" menu action (both on .main); `completion` lets either caller surface
    /// success/failure (e.g. as a notification).
    func pushFile(at url: URL, completion: ((Bool) -> Void)? = nil) {
        guard let (connection, token) = stateQueue.sync(execute: { () -> (NWConnection, String)? in
            guard let connection = pairedConnection, let token = pairingRecord.pairedToken else { return nil }
            return (connection, token)
        }) else {
            serverLogger.info("No paired client - skipping push for \(url.lastPathComponent, privacy: .public)")
            completion?(false)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let header = WireMessage(
                type: "file_push",
                token: token,
                filename: url.lastPathComponent,
                bodyLength: data.count
            )
            try sendMessage(header, on: connection)
            try connection.syncSend(data)
            let reply = try readMessage(ConnectionBuffer(connection: connection))
            if reply.type == "ack", reply.ok == true {
                serverLogger.info("Pushed \(url.lastPathComponent, privacy: .public)")
                completion?(true)
            } else {
                serverLogger.error("Push rejected: \(reply.message ?? "unknown", privacy: .public)")
                completion?(false)
            }
        } catch {
            serverLogger.error("Push failed, dropping connection: \(String(describing: error), privacy: .public)")
            // Only clear pairedConnection if it's still the same connection this push used -
            // a concurrent reconnect may have already replaced it with a healthy new one,
            // which must not be thrown away just because the old one (correctly) failed.
            stateQueue.sync {
                if pairedConnection === connection {
                    pairedConnection = nil
                }
            }
            completion?(false)
        }
    }
}
