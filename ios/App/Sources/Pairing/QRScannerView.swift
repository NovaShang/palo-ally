import SwiftUI
#if !targetEnvironment(macCatalyst)
import VisionKit
#endif

/// Camera QR scanner (VisionKit DataScanner). Unavailable on Mac Catalyst
/// and devices without a camera — the pairing screen falls back to pasting.
struct QRScannerView {
    @MainActor static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return DataScannerViewController.isSupported
        #endif
    }
}

struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onFound: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                #if targetEnvironment(macCatalyst)
                ContentUnavailableView("这台设备不能扫码", systemImage: "qrcode")
                #else
                if DataScannerViewController.isAvailable {
                    DataScannerRepresentable(onFound: onFound)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView("没法使用相机", systemImage: "camera",
                                           description: Text("请在「设置」里允许 PaloAlly 使用相机，或者改用粘贴链接。"))
                }
                #endif
            }
            .navigationTitle("扫一扫电脑上的二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}

#if !targetEnvironment(macCatalyst)
private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue,
                   payload.lowercased().hasPrefix("paloally://") {
                    done = true
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onFound(payload)
                    return
                }
            }
        }
    }
}
#endif
