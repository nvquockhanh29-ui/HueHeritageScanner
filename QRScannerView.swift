import SwiftUI
import AVFoundation
import UIKit
import Darwin

struct QRConnectionTarget: Equatable {
    let host: String
    let port: UInt16
}

enum QRParseError: LocalizedError, Equatable {
    case emptyPayload
    case unsupportedScheme(String)
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "Mã QR trống, không chứa địa chỉ kết nối."
        case .unsupportedScheme(let scheme):
            return "Mã QR không hợp lệ ('\(scheme)://'). Cần mã QR hue1://<ip>:<port> từ phần mềm PC."
        case .invalidHost:
            return "Địa chỉ IP hoặc tên máy chủ trong mã QR không hợp lệ."
        case .invalidPort:
            return "Cổng kết nối trong mã QR không hợp lệ (phải từ 1 đến 65535)."
        }
    }
}

enum QRCodePayloadParser {
    static let defaultPort: UInt16 = 18080

    static func parse(_ raw: String) -> Result<QRConnectionTarget, QRParseError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyPayload)
        }

        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound])
            guard scheme.lowercased() == "hue1" else {
                return .failure(.unsupportedScheme(scheme))
            }

            let remainder = String(trimmed[schemeRange.upperBound...])
            let authority = remainder
                .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let cleanAuthority = authority
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""

            guard !cleanAuthority.isEmpty,
                  cleanAuthority.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                return .failure(.invalidHost)
            }

            if cleanAuthority.contains(":") {
                let parts = cleanAuthority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else {
                    return .failure(.invalidHost)
                }
                let host = parts[0]
                let portStr = parts[1]
                guard isValidIPv4(host) || isValidHostname(host) else {
                    return .failure(.invalidHost)
                }
                guard let portVal = parsePort(portStr) else {
                    return .failure(.invalidPort)
                }
                return .success(QRConnectionTarget(host: host, port: portVal))
            } else {
                guard isValidIPv4(cleanAuthority) || isValidHostname(cleanAuthority) else {
                    return .failure(.invalidHost)
                }
                return .success(QRConnectionTarget(host: cleanAuthority, port: defaultPort))
            }
        }

        // Fallback không có scheme: chỉ chấp nhận IPv4 (<ip>:<port> hoặc <ip>) để tránh nhận nhầm văn bản bất kỳ
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return .failure(.invalidHost)
        }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                return .failure(.invalidHost)
            }
            let host = parts[0]
            let portStr = parts[1]
            guard isValidIPv4(host) else {
                return .failure(.invalidHost)
            }
            guard let portVal = parsePort(portStr) else {
                return .failure(.invalidPort)
            }
            return .success(QRConnectionTarget(host: host, port: portVal))
        } else {
            guard isValidIPv4(trimmed) else {
                return .failure(.invalidHost)
            }
            return .success(QRConnectionTarget(host: trimmed, port: defaultPort))
        }
    }

    private static func parsePort(_ portStr: String) -> UInt16? {
        guard !portStr.isEmpty,
              portStr.allSatisfy({ $0 >= "0" && $0 <= "9" && $0.isASCII }),
              let portVal = Int(portStr),
              (1...65535).contains(portVal) else {
            return nil
        }
        return UInt16(portVal)
    }

    static func isValidIPv4(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.count <= 253,
              !host.hasPrefix("."),
              !host.hasSuffix(".") else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        var hasASCIILetter = false
        for label in labels {
            guard (1...63).contains(label.count),
                  !label.hasPrefix("-"),
                  !label.hasSuffix("-") else {
                return false
            }
            for scalar in label.unicodeScalars {
                let v = scalar.value
                let isUpper = (v >= 65 && v <= 90)
                let isLower = (v >= 97 && v <= 122)
                let isDigit = (v >= 48 && v <= 57)
                let isHyphen = (v == 45)
                guard isUpper || isLower || isDigit || isHyphen else {
                    return false
                }
                if isUpper || isLower {
                    hasASCIILetter = true
                }
            }
        }
        return hasASCIILetter
    }
}

// MARK: - Camera AVCaptureSession ViewController

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((QRConnectionTarget) -> Void)?
    var onScanError: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "vn.hueheritage.qrCaptureQueue")
    private let scanStateLock = NSLock()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var _hasDeliveredValidScan = false
    private var lastErrorMessage = ""
    private var lastErrorTime: TimeInterval = 0

    private var hasDeliveredValidScan: Bool {
        scanStateLock.lock()
        defer { scanStateLock.unlock() }
        return _hasDeliveredValidScan
    }

    private func claimValidScanDelivery() -> Bool {
        scanStateLock.lock()
        defer { scanStateLock.unlock() }
        guard !_hasDeliveredValidScan else { return false }
        _hasDeliveredValidScan = true
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        startCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startCapture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
    }

    func startCapture() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureCaptureSessionIfNeeded()
            guard self.isConfigured,
                  !self.captureSession.isRunning,
                  !self.hasDeliveredValidScan else {
                return
            }
            self.captureSession.startRunning()
        }
    }

    func stopCapture() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setTorchInternal(enabled: false)
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            self?.setTorchInternal(enabled: enabled)
        }
    }

    private func setTorchInternal(enabled: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if enabled {
                if device.torchMode != .on {
                    try device.setTorchModeOn(level: 1.0)
                }
            } else if device.torchMode != .off {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
        } catch {
            // Bỏ qua lỗi khóa phần cứng flash nếu thiết bị đang chuyển trạng thái
        }
    }

    private func configureCaptureSessionIfNeeded() {
        guard !isConfigured else { return }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            DispatchQueue.main.async { [weak self] in
                self?.onScanError?("Không thể khởi tạo camera để quét mã QR.")
            }
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            DispatchQueue.main.async { [weak self] in
                self?.onScanError?("Camera không hỗ trợ đọc mã QR.")
            }
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            metadataOutput.metadataObjectTypes = [.qr]
        }

        isConfigured = true
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDeliveredValidScan else { return }
        guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              readable.type == .qr,
              let rawString = readable.stringValue else {
            return
        }

        switch QRCodePayloadParser.parse(rawString) {
        case .success(let target):
            guard claimValidScanDelivery() else { return }
            stopCapture()
            let feedback = UIImpactFeedbackGenerator(style: .medium)
            feedback.impactOccurred()
            onCodeScanned?(target)
        case .failure(let error):
            let now = Date().timeIntervalSince1970
            let msg = error.localizedDescription
            if now - lastErrorTime >= 1.5 || msg != lastErrorMessage {
                lastErrorTime = now
                lastErrorMessage = msg
                onScanError?(msg)
            }
        }
    }
}

struct QRCameraRepresentable: UIViewControllerRepresentable {
    @Binding var isTorchOn: Bool
    var onCodeScanned: (QRConnectionTarget) -> Void
    var onScanError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = onCodeScanned
        controller.onScanError = onScanError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.setTorchEnabled(isTorchOn)
    }

    static func dismantleUIViewController(_ uiViewController: QRScannerViewController, coordinator: ()) {
        uiViewController.stopCapture()
    }
}

// MARK: - SwiftUI Modal QR Scanner View

struct QRScannerView: View {
    var onCodeScanned: (QRConnectionTarget) -> Void
    var onCancel: () -> Void

    @State private var authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isTorchOn = false
    @State private var scanError: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch authStatus {
            case .authorized:
                QRCameraRepresentable(
                    isTorchOn: $isTorchOn,
                    onCodeScanned: onCodeScanned,
                    onScanError: { msg in
                        withAnimation {
                            scanError = msg
                        }
                    }
                )
                .ignoresSafeArea()

                // Lớp phủ khung ngắm quét QR
                VStack(spacing: 16) {
                    HStack {
                        Button(action: {
                            isTorchOn.toggle()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                Text(isTorchOn ? "Tắt đèn" : "Bật đèn")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isTorchOn ? .yellow : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(20)
                        }

                        Spacer()

                        Button(action: onCancel) {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark")
                                Text("Đóng")
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(20)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                    Spacer()

                    // Khung ngắm QR
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color(red: 0.0, green: 0.72, blue: 0.48), lineWidth: 3)
                            .frame(width: 240, height: 240)
                            .background(Color.white.opacity(0.03).cornerRadius(18))

                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 56, weight: .thin))
                            .foregroundColor(Color.white.opacity(0.22))
                    }

                    if let errorText = scanError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text(errorText)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.88))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)
                    }

                    Spacer()

                    VStack(spacing: 6) {
                        Text("Quét mã QR từ LiDAR Mesh Studio")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text("Hướng camera vào mã QR (hue1://<ip>:18080) hiển thị trên máy tính để tự động kết nối qua Mobile Hotspot hoặc Wi-Fi LAN.")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.82))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(14)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }

            case .notDetermined:
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Đang yêu cầu quyền sử dụng Camera để quét mã QR...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .onAppear {
                    AVCaptureDevice.requestAccess(for: .video) { granted in
                        DispatchQueue.main.async {
                            authStatus = granted ? .authorized : .denied
                        }
                    }
                }

            case .denied, .restricted:
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)

                    Text("Chưa có quyền truy cập Camera")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("Ứng dụng cần quyền Camera để quét mã QR kết nối với phần mềm máy tính và cảm biến LiDAR. Vui lòng bật quyền Camera trong Cài đặt iPhone.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button(action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Text("Mở Cài Đặt iPhone")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color(red: 0.0, green: 0.384, blue: 0.255))
                            .cornerRadius(10)
                    }

                    Button("Đóng", action: onCancel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 4)
                }
                .padding()

            @unknown default:
                Button("Đóng", action: onCancel)
                    .foregroundColor(.white)
            }
        }
    }
}
