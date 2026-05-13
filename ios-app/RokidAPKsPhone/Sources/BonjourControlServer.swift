import Foundation
import Network

/// Advertises the phone over Bonjour as "_rokidapks._tcp" and handles the JSON
/// control channel with the glasses companion app.
///
/// Wire format (identical to the original Kotlin SppControlChannel):
///   [4-byte big-endian Int32 length][UTF-8 JSON body]
///
/// The glasses companion discovers this service via Android NSD and connects over TCP
/// instead of Bluetooth SPP, which is unavailable on iOS.
final class BonjourControlServer {
    static let serviceType = "_rokidapks._tcp"
    static let serviceName = "RokidAPKsPhone"

    private var listener: NWListener?

    // MARK: - Lifecycle

    /// Starts the Bonjour listener and waits (suspending) until the first glasses
    /// connection arrives. Returns the accepted NWConnection ready for use.
    func startAndAwaitConnection() async throws -> NWConnection {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.service = NWListener.Service(
            name: Self.serviceName,
            type: Self.serviceType
        )

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false

            listener.newConnectionHandler = { connection in
                guard !resumed else { return }
                resumed = true
                connection.start(queue: .global(qos: .userInitiated))
                continuation.resume(returning: connection)
            }

            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Control channel I/O

    /// Sends the transfer offer to the glasses companion.
    func sendOffer(_ offer: TransferOffer, on connection: NWConnection) async throws {
        let body = try offer.toJSONData()
        var header = Data(count: 4)
        let length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: length) { header.replaceSubrange(0..<4, with: $0) }
        let frame = header + body

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Waits for the result JSON from the glasses (sent after install attempt).
    func receiveResult(from connection: NWConnection) async throws -> TransferResult {
        let headerData = try await receive(from: connection, exactly: 4)
        let length = headerData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 65_536 else {
            throw TransferError.connectionClosed
        }

        let bodyData = try await receive(from: connection, exactly: Int(length))
        guard
            let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            throw NSError(
                domain: "RokidAPKs", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Malformed result JSON from glasses"]
            )
        }

        return TransferResult(
            success: json["success"] as? Bool ?? false,
            message: json["message"] as? String ?? ""
        )
    }

    // MARK: - Private helpers

    private func receive(from connection: NWConnection, exactly length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == length {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: TransferError.connectionClosed)
                }
            }
        }
    }
}
