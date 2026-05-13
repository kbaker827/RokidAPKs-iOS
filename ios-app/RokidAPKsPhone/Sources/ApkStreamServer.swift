import Foundation
import Network

/// Raw TCP server that streams the APK bytes to the glasses companion.
/// The glasses connect to hostIp:port (from the offer) and receive the full APK
/// as a contiguous byte stream — no framing, matching PhoneApkSocketServer.kt.
final class ApkStreamServer {
    private let apkData: Data
    private var listener: NWListener?

    private let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()

    /// Async sequence of normalised progress values [0.0 … 1.0].
    var progress: AsyncStream<Double> { progressStream }

    init(apkData: Data) {
        self.apkData = apkData
    }

    // MARK: - Lifecycle

    /// Starts the TCP server and returns the assigned port number.
    func start() async throws -> Int {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !didResume, let port = listener.port {
                        didResume = true
                        continuation.resume(returning: Int(port.rawValue))
                    }
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global(qos: .userInitiated))
                self?.stream(apk: self!.apkData, over: connection)
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        progressContinuation.finish()
    }

    // MARK: - Streaming

    private func stream(apk: Data, over connection: NWConnection) {
        let chunkSize = 61_440 // 60 KB — matches CHUNK_SIZE in SppTransferConstants
        let total = apk.count
        var offset = 0

        func sendNext() {
            guard offset < total else {
                progressContinuation.yield(1.0)
                connection.cancel()
                return
            }
            let end = min(offset + chunkSize, total)
            let chunk = apk[offset..<end]
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil else { return }
                offset = end
                self?.progressContinuation.yield(Double(offset) / Double(total))
                sendNext()
            })
        }

        sendNext()
    }
}
