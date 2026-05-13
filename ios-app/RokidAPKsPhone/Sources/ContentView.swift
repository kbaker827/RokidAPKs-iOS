import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = TransferSession()
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                statusCard
                    .padding()

                Divider()

                logView

                Divider()

                actionBar
                    .padding()
            }
            .navigationTitle("Rokid APK Installer")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showPicker) {
            DocumentPicker(
                allowedTypes: [UTType(filenameExtension: "apk") ?? .data]
            ) { url in
                session.startSession(with: url)
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack(spacing: 14) {
            phaseIcon
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(phaseTitle)
                    .font(.headline)
                if let detail = phaseDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding()
        .background(phaseColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(phaseColor.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch session.phase {
        case .idle:
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.blue)
        case .waitingForGlasses:
            ProgressView()
                .scaleEffect(1.3)
        case .connected:
            Image(systemName: "link.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
        case .transferring(let p):
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: p)
                Text("\(Int(p * 100))%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red)
        }
    }

    private var phaseTitle: String {
        switch session.phase {
        case .idle:                    return "Ready"
        case .waitingForGlasses:       return "Waiting for glasses…"
        case .connected:               return "Connected"
        case .transferring(let p):     return "Transferring \(Int(p * 100))%"
        case .complete:                return "Transfer complete"
        case .failed:                  return "Transfer failed"
        }
    }

    private var phaseDetail: String? {
        switch session.phase {
        case .idle:
            return session.selectedFileName.map { "Last: \($0)" }
                ?? "Select an APK to install on the glasses"
        case .waitingForGlasses:
            return "Open Rokid-APKs on the glasses to connect"
        case .connected:
            return "Sending transfer offer…"
        case .transferring:
            return session.selectedFileName
        case .complete(let msg):
            return msg
        case .failed(let msg):
            return msg
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .idle:                    return .blue
        case .waitingForGlasses:       return .orange
        case .connected:               return .orange
        case .transferring:            return .blue
        case .complete:                return .green
        case .failed:                  return .red
        }
    }

    // MARK: - Log

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(session.log.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.75))
                            .padding(.horizontal, 12)
                            .id(idx)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: session.log.count) { _ in
                if let last = session.log.indices.last {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        Group {
            if isSessionActive {
                Button(role: .destructive) {
                    session.cancel()
                } label: {
                    Label("Cancel Transfer", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    showPicker = true
                } label: {
                    Label("Select APK", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var isSessionActive: Bool {
        switch session.phase {
        case .idle, .complete, .failed: return false
        default: return true
        }
    }
}

// MARK: - Document picker bridge

struct DocumentPicker: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
