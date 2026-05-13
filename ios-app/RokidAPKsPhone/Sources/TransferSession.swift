import Foundation
import CryptoKit

/// Orchestrates the full Wi-Fi LAN transfer flow for an iOS phone acting as the sender.
///
/// Flow:
///  1. User selects an APK via the document picker.
///  2. iOS phone reads the file, computes MD5, and opens an APK TCP stream server.
///  3. Bonjour control server advertises "_rokidapks._tcp" on the local network.
///  4. Glasses companion (running the modified Android glasses-app) discovers the
///     service via NSD, connects to the control server, and receives the transfer offer.
///  5. Glasses pull the APK over TCP from the stream server port in the offer.
///  6. Glasses send a result JSON back over the control connection.
///  7. Install prompt appears on the glasses.
@MainActor
final class TransferSession: ObservableObject {
    @Published var phase: TransferPhase = .idle
    @Published var log: [String] = []
    @Published var selectedFileName: String?

    private var controlServer: BonjourControlServer?
    private var apkServer: ApkStreamServer?
    private var activeTask: Task<Void, Never>?

    // MARK: - Public API

    func startSession(with url: URL) {
        guard case .idle = phase else { return }
        selectedFileName = url.lastPathComponent
        activeTask = Task { await runSession(apkURL: url) }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        teardown()
        phase = .idle
        appendLog("Session cancelled.")
    }

    // MARK: - Session state machine

    private func runSession(apkURL: URL) async {
        phase = .waitingForGlasses

        let accessing = apkURL.startAccessingSecurityScopedResource()
        defer { if accessing { apkURL.stopAccessingSecurityScopedResource() } }

        do {
            // 1. Load APK
            appendLog("Reading \(apkURL.lastPathComponent)…")
            let apkData = try Data(contentsOf: apkURL)
            let apkSize = Int64(apkData.count)
            appendLog("APK size: \(formatBytes(apkSize))")

            // 2. Compute MD5
            let md5Hex = Insecure.MD5.hash(data: apkData)
                .map { String(format: "%02x", $0) }.joined()
            appendLog("MD5: \(md5Hex.prefix(8))…")

            // 3. Start APK stream server
            let apkServer = ApkStreamServer(apkData: apkData)
            self.apkServer = apkServer
            let apkPort = try await apkServer.start()
            appendLog("APK server ready on port \(apkPort)")

            // 4. Resolve Wi-Fi IP
            guard let hostIP = NetworkUtils.localWiFiIPAddress() else {
                throw TransferError.noWiFi
            }
            appendLog("Local address: \(hostIP)")

            // 5. Advertise over Bonjour and wait for glasses
            let controlServer = BonjourControlServer()
            self.controlServer = controlServer
            appendLog("Advertising \(BonjourControlServer.serviceType) via Bonjour…")
            appendLog("Open Rokid-APKs on the glasses to connect.")

            let connection = try await withTimeout(seconds: 120) {
                try await controlServer.startAndAwaitConnection()
            }
            appendLog("Glasses companion connected.")
            phase = .connected

            // 6. Send offer
            let offer = TransferOffer(
                hostIp: hostIP,
                port: apkPort,
                apkSize: apkSize,
                md5Hex: md5Hex,
                fileName: apkURL.lastPathComponent
            )
            try await controlServer.sendOffer(offer, on: connection)
            appendLog("Offer sent. Waiting for glasses to pull APK…")

            // 7. Track stream progress
            let progressTask = Task {
                var lastPct = -1
                for await p in apkServer.progress {
                    let pct = Int(p * 100)
                    if pct != lastPct && pct % 10 == 0 {
                        lastPct = pct
                        await MainActor.run {
                            phase = .transferring(progress: p)
                            appendLog("Transfer: \(pct)%")
                        }
                    }
                }
            }

            // 8. Await install result from glasses (90 s)
            let result = try await withTimeout(seconds: 90) {
                try await controlServer.receiveResult(from: connection)
            }
            progressTask.cancel()

            if result.success {
                phase = .complete(message: result.message.isEmpty ? "Install prompt shown on glasses." : result.message)
                appendLog("Done: \(result.message)")
            } else {
                throw TransferError.glassesFailed(result.message)
            }

        } catch is CancellationError {
            // cancelled by the user — already handled in cancel()
        } catch {
            let msg = error.localizedDescription
            phase = .failed(msg)
            appendLog("Error: \(msg)")
        }

        teardown()
    }

    // MARK: - Helpers

    private func teardown() {
        apkServer?.stop()
        controlServer?.stop()
        apkServer = nil
        controlServer = nil
    }

    private func appendLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(ts)] \(message)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes) B"
    }
}

// MARK: - Timeout helper

func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TransferError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
