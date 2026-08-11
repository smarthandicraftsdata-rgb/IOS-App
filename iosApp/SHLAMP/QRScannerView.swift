import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.resultHandler = { context.coordinator.handle($0) }
        controller.errorHandler = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator {
        let parent: QRScannerView
        private var completed = false
        init(parent: QRScannerView) { self.parent = parent }
        func handle(_ value: String) {
            guard !completed else { return }
            completed = true
            parent.onResult(value)
        }
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var resultHandler: ((String) -> Void)?
    var errorHandler: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { allowed ? self?.setupSession() : self?.errorHandler?("Camera permission is required to scan a lamp QR code.") }
            }
        default: errorHandler?("Enable camera access for SH Lamp in iPhone Settings.")
        }
    }

    private func setupSession() {
        guard session.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            errorHandler?("The camera is not available."); return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { errorHandler?("QR scanning is unavailable."); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = object.stringValue else { return }
        session.stopRunning()
        resultHandler?(value)
    }
}
