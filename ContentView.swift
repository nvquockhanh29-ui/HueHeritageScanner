import SwiftUI
import ARKit
import SceneKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var manager: ARScannerManager

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.automaticallyUpdatesLighting = true
        arView.delegate = manager
        arView.session.delegate = manager

        // Hiển thị khung dây 3D wireframe trên bề mặt vật thể thực
        arView.debugOptions = [.showWireframe]

        #if !targetEnvironment(simulator)
        manager.arView = arView
        manager.startSession()
        #endif

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

private enum ActiveSheet: Int, Identifiable {
    case settings
    case qrScanner

    var id: Int { rawValue }
}

struct ContentView: View {
    @StateObject private var scanner = ARScannerManager()
    @AppStorage("serverIP") private var serverIP: String = "192.168.137.1"
    @AppStorage("serverPort") private var serverPort: Int = 18080

    @State private var activeSheet: ActiveSheet? = nil
    @State private var pendingQRTransition = false
    @State private var presentedSheetWasQR = false
    @State private var pendingAutoConnectTarget: QRConnectionTarget? = nil

    @State private var statusToast: String = ""
    @State private var showToast = false

    private var validServerPort: UInt16 {
        (1...65535).contains(serverPort) ? UInt16(serverPort) : 18080
    }

    var body: some View {
        ZStack {
            // 1. CẢM BIẾN CAMERA & 3D WIREFRAME MESH (NỀN ĐEN PHỦ TOÀN BỘ MẶT KÍNH)
            Color.black.edgesIgnoringSafeArea(.all)

            ARViewContainer(manager: scanner)
                .edgesIgnoringSafeArea(.all)

            // 2. GIAO DIỆN ĐIỀU KHIỂN NẰM TRỌN TRONG 2 DẢI ĐEN TRÊN VÀ DƯỚI
            VStack(spacing: 0) {
                // ==============================================================
                // A. THANH TIÊU ĐỀ TRÊN CÙNG (DƯỚI TAI THỎ / DYNAMIC ISLAND)
                // ==============================================================
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        // Logo & Nhãn Dự Án
                        HStack(spacing: 6) {
                            Text("🏛️")
                                .font(.system(size: 18))

                            VStack(alignment: .leading, spacing: 1) {
                                Text("DIGITAL TWIN")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .foregroundColor(.orange)
                                Text("HUẾ HERITAGE")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .fixedSize()

                            if scanner.isLiveStreaming {
                                HStack(spacing: 3) {
                                    Circle().fill(Color.red).frame(width: 5, height: 5)
                                    Text("LIVE")
                                        .font(.system(size: 8, weight: .black))
                                        .foregroundColor(.red)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.25))
                                .cornerRadius(4)
                            }

                            // Trạng thái TCP ngắn gọn
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(scanner.isConnectedToLaptop ? Color.green : Color.gray)
                                    .frame(width: 5, height: 5)
                                Text(scanner.isConnectedToLaptop ? "TCP :\(validServerPort)" : "OFFLINE")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(scanner.isConnectedToLaptop ? .green : .gray)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(4)
                        }

                        Spacer()

                        // Các nút chức năng: Quét QR, Flash, Reset, Settings
                        HStack(spacing: 6) {
                            // Nút Quét QR kết nối nhanh PC
                            Button(action: {
                                openQRScannerDirectly()
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.system(size: 13, weight: .bold))
                                    Text("QR")
                                        .font(.system(size: 11, weight: .black))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 9)
                                .frame(height: 32)
                                .background(Color(red: 0.0, green: 0.384, blue: 0.255))
                                .cornerRadius(16)
                            }

                            // Nút Đèn Flash
                            Button(action: { scanner.toggleTorch() }) {
                                Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(scanner.isTorchOn ? .yellow : .white)
                                    .frame(width: 32, height: 32)
                                    .background(scanner.isTorchOn ? Color.yellow.opacity(0.3) : Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }

                            // Nút Làm Mới (Reset)
                            Button(action: {
                                scanner.resetScan()
                                showNotification("Đã làm mới phiên quét")
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }

                            // Nút Cài Đặt (Settings)
                            Button(action: {
                                presentedSheetWasQR = false
                                activeSheet = .settings
                            }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)

                    // Cảnh báo hệ thống / ARKit (nếu thiết bị không có LiDAR hoặc bị gián đoạn)
                    if let statusMsg = scanner.statusMessage {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 10))
                            Text(statusMsg)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.9))
                        .cornerRadius(8)
                        .padding(.top, 2)
                    }

                    // Cảnh báo vùng thưa điểm
                    if scanner.missingAreaCount > 0 && scanner.highlightMissing {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 10))
                            Text("Phát hiện \(scanner.missingAreaCount) vùng thưa điểm (Đang đánh dấu ĐỎ)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(8)
                        .padding(.top, 2)
                    }
                }
                .padding(.bottom, 4)

                // ==============================================================
                // B. KHUNG HÌNH CAMERA Ở GIỮA (HOÀN TOÀN SẠCH SẼ)
                // ==============================================================
                Spacer()

                // Toast thông báo ngắn nổi nhẹ (nếu có)
                if showToast {
                    Text(statusToast)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(14)
                        .padding(.bottom, 6)
                        .transition(.scale.combined(with: .opacity))
                }

                // ==============================================================
                // C. BẢNG ĐIỀU KHIỂN DƯỚI CÙNG
                // ==============================================================
                VStack(spacing: 6) {
                    // Dòng chỉ số kỹ thuật HBIM thu gọn + địa chỉ đích TCP
                    HStack {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                            Text("ĐIỂM: \(scanner.vertexCount.formatted())")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(Color.yellow).frame(width: 5, height: 5)
                            Text("LƯỚI: \(scanner.faceCount.formatted())")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text("HBIM: ±\(String(format: "%.1f", scanner.accuracyErrorMM))mm")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(scanner.accuracyErrorMM <= 1.5 ? .green : .orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(6)

                    // 4 Phím chức năng lớn
                    HStack(spacing: 8) {
                        // Nút Tạm Dừng / Bắt Đầu
                        Button(action: {
                            if scanner.isScanning {
                                scanner.stopSession()
                            } else {
                                scanner.startSession()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: scanner.isScanning ? "pause.fill" : "play.fill")
                                Text(scanner.isScanning ? "Tạm Dừng" : "Bắt Đầu")
                            }
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(scanner.isScanning ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }

                        // Nút Đồng Bộ tức thời qua TCP 18080
                        Button(action: {
                            scanner.uploadToServer(serverIP: serverIP, port: validServerPort) { _, msg in
                                showNotification(msg)
                            }
                        }) {
                            HStack(spacing: 4) {
                                if scanner.isUploading {
                                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Đồng Bộ")
                                }
                            }
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(scanner.isUploading || scanner.vertexCount == 0)

                        // Nút Live Stream Trực Tiếp qua TCP HUE1
                        Button(action: {
                            scanner.toggleLiveStream(serverIP: serverIP, port: validServerPort)
                            showNotification(
                                scanner.isLiveStreaming
                                    ? "Đang truyền trực tiếp HUE1 tới \(serverIP):\(validServerPort)"
                                    : "Đã tắt truyền trực tiếp"
                            )
                        }) {
                            Image(systemName: scanner.isLiveStreaming ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 44, height: 38)
                                .background(scanner.isLiveStreaming ? Color.red : Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        // Nút Chia Sẻ File PLY
                        Button(action: {
                            scanner.sharePLYFile()
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 44, height: 38)
                                .background(Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(scanner.vertexCount == 0)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
        }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(
                    scanner: scanner,
                    serverIP: $serverIP,
                    serverPort: $serverPort,
                    onRequestQRScan: {
                        pendingQRTransition = true
                        activeSheet = nil
                    },
                    onDismiss: {
                        activeSheet = nil
                    }
                )
            case .qrScanner:
                QRScannerView(
                    onCodeScanned: { target in
                        serverIP = target.host
                        serverPort = Int(target.port)
                        pendingAutoConnectTarget = target
                        activeSheet = nil
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )
            }
        }
    }

    private func openQRScannerDirectly() {
        scanner.pauseForQR()
        presentedSheetWasQR = true
        activeSheet = .qrScanner
    }

    private func handleSheetDismiss() {
        if pendingQRTransition {
            pendingQRTransition = false
            scanner.pauseForQR()
            DispatchQueue.main.async {
                presentedSheetWasQR = true
                activeSheet = .qrScanner
            }
            return
        }

        if presentedSheetWasQR {
            presentedSheetWasQR = false
            scanner.resumeAfterQR()
        }

        if let target = pendingAutoConnectTarget {
            pendingAutoConnectTarget = nil
            scanner.connectAndStartStream(serverIP: target.host, port: target.port)
            showNotification("Đã quét QR: \(target.host):\(target.port) — Đang kết nối Live Stream")
        }
    }

    private func showNotification(_ text: String) {
        statusToast = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation { showToast = false }
        }
    }
}

// MARK: - Màn hình Cài Đặt Kết Nối Mạng TCP & Quét QR (Cổng mặc định 18080)

struct SettingsSheet: View {
    @ObservedObject var scanner: ARScannerManager
    @Binding var serverIP: String
    @Binding var serverPort: Int
    var onRequestQRScan: () -> Void
    var onDismiss: () -> Void

    @State private var portInput: String = ""
    @State private var portValidationError: String? = nil
    @State private var testing = false
    @State private var testResult = ""

    private var validatedPort: UInt16 {
        (1...65535).contains(serverPort) ? UInt16(serverPort) : 18080
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Kết nối Live Stream PC (TCP 18080)")) {
                    Button(action: onRequestQRScan) {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 16, weight: .bold))
                            Text("Quét mã QR từ PC (hue1://)")
                                .font(.system(size: 14, weight: .bold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color(red: 0.0, green: 0.384, blue: 0.255))
                        .cornerRadius(8)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chọn nhanh địa chỉ mạng:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 6) {
                            Button("Hotspot PC\n192.168.137.1") {
                                serverIP = "192.168.137.1"
                                applyPort("18080")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(serverIP == "192.168.137.1" ? .green : .gray)

                            Button("Hotspot iPhone\n172.20.10.2") {
                                serverIP = "172.20.10.2"
                                applyPort("18080")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(serverIP == "172.20.10.2" ? .blue : .gray)

                            Button("LAN\n192.168.1.29") {
                                serverIP = "192.168.1.29"
                                applyPort("18080")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(serverIP == "192.168.1.29" ? .teal : .gray)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Text("IP")
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .leading)
                        TextField("192.168.137.1", text: $serverIP)
                            .keyboardType(.numbersAndPunctuation)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Text("Port")
                            .foregroundColor(.secondary)
                            .frame(width: 44, alignment: .leading)
                        TextField("18080", text: $portInput)
                            .keyboardType(.numberPad)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: portInput) { newVal in
                                applyPort(newVal)
                            }
                    }

                    if let portErr = portValidationError {
                        Text(portErr)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }

                    Button(action: {
                        testing = true
                        testResult = "Đang kiểm tra kết nối TCP tới \(serverIP):\(validatedPort)..."
                        scanner.testConnection(serverIP: serverIP, port: validatedPort) { _, msg in
                            testing = false
                            testResult = msg
                        }
                    }) {
                        HStack {
                            if testing {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text("Kiểm tra kết nối TCP tới Laptop")
                        }
                    }

                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.system(size: 12))
                            .foregroundColor(scanner.isConnectedToLaptop ? .green : .red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 Mobile Hotspot từ Laptop Windows: Bật Mobile Hotspot trên Windows -> iPhone bắt Wi-Fi của Laptop -> Quét QR trên LiDAR Mesh Studio (IP mặc định 192.168.137.1, cổng 18080).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("💡 Wi-Fi LAN / Hotspot iPhone: Đảm bảo iPhone và Laptop dùng chung mạng, không bật VPN hoặc mạng 4G riêng.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                Section(header: Text("Tùy chọn Khảo sát 3D Di tích")) {
                    Toggle("Cảnh báo vùng thưa điểm (Đỏ)", isOn: $scanner.highlightMissing)
                    Toggle("Lọc mượt nhiễu LiDAR (Smoothing)", isOn: $scanner.enableSmoothing)
                    Toggle("Tự động đồng bộ liên tục", isOn: $scanner.autoSyncEnabled)
                }

                Section(header: Text("Hiệu chuẩn Tỷ lệ Đo đạc Thực tế (Scale Calibration)")) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Hệ số co dãn:")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.4f x (%.1f%%)", scanner.scaleMultiplier, (scanner.scaleMultiplier - 1.0) * 100))
                                .font(.system(.subheadline, design: .monospaced))
                                .bold()
                                .foregroundColor(scanner.scaleMultiplier == 1.0 ? .secondary : .green)
                        }

                        Text("Khắc phục sai số cảm biến LiDAR (ví dụ viên gạch thực tế 60cm nhưng quét ra 51cm → chọn hệ số 1.1765x).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button("Chuẩn 1.0x") {
                                scanner.setScaleMultiplier(1.0)
                            }
                            .buttonStyle(.bordered)
                            .tint(scanner.scaleMultiplier == 1.0 ? .blue : .gray)

                            Button("Gạch 60cm / 51cm (1.1765x)") {
                                scanner.setScaleMultiplier(0.600 / 0.510)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(abs(scanner.scaleMultiplier - (0.600 / 0.510)) < 0.01 ? .green : .gray)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Thông tin Ứng dụng")) {
                    HStack {
                        Text("Dự án")
                        Spacer()
                        Text("HBIM Cố Đô Huế")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Giao thức")
                        Spacer()
                        Text("TCP HUE1 :\(validatedPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Phiên bản")
                        Spacer()
                        Text("v2.0 - QR + TCP HUE1 Z-up")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle("Cài Đặt", displayMode: .inline)
            .navigationBarItems(trailing: Button("Xong") { onDismiss() })
            .onAppear {
                let initialPort = (1...65535).contains(serverPort) ? serverPort : 18080
                serverPort = initialPort
                portInput = String(initialPort)
            }
        }
    }

    private func applyPort(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = Int(trimmed), (1...65535).contains(p) {
            serverPort = p
            portValidationError = nil
            if portInput != trimmed {
                portInput = trimmed
            }
        } else {
            portValidationError = "Cổng phải nằm trong khoảng 1–65535 (đang dùng mặc định \(validatedPort))."
        }
    }
}
