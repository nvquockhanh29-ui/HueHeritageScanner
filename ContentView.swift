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

        // Hiển thị khung dây 3D wireframe trên vật thể thực
        arView.debugOptions = [.showWireframe]

        #if !targetEnvironment(simulator)
        manager.arView = arView
        manager.startSession()
        #endif

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var scanner = ARScannerManager()
    @State private var serverIP: String = "192.168.1.8"
    @State private var showingSettings = false
    @State private var statusToast: String = ""
    @State private var showToast = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // 1. THANH TIÊU ĐỀ: NẰM 100% TRONG VÙNG ĐEN TRÊN CÙNG (KHÔNG HỀ LẤN VÀO CAMERA)
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text("🏛️")
                                .font(.system(size: 15))
                            Text("DIGITAL TWIN")
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange))
                            Text("HUẾ HERITAGE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }

                        if scanner.isLiveStreaming {
                            HStack(spacing: 3) {
                                Circle().fill(Color.red).frame(width: 6, height: 6)
                                Text("LIVE")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundColor(.red)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18))
                            .cornerRadius(4)
                        }

                        Spacer()

                        // Nút Đèn Flash
                        Button(action: { scanner.toggleTorch() }) {
                            Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(scanner.isTorchOn ? .yellow : .white)
                                .padding(7)
                                .background(scanner.isTorchOn ? Color.yellow.opacity(0.3) : Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }

                        // Nút Làm Mới Quét (Xóa bộ đệm & Báo Laptop dọn sạch)
                        Button(action: {
                            scanner.resetScan()
                            showNotification("Đã làm mới phiên quét")
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(7)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }

                        // Nút Cài Đặt
                        Button(action: { showingSettings.toggle() }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(7)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, max(geo.safeAreaInsets.top, 44))

                    // Cảnh báo vùng thưa điểm (nằm trong vùng đen)
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
                        .cornerRadius(10)
                        .padding(.bottom, 2)
                    }
                }
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
                .background(Color.black)

                // 2. KHUNG HÌNH CAMERA 100% SẠCH SẼ Ở GIỮA (KHÔNG BỊ BẤT KỲ NÚT NÀO ĐÈ LÊN)
                ARViewContainer(manager: scanner)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                // 3. THANH ĐIỀU KHIỂN: NẰM 100% TRONG VÙNG ĐEN DƯỚI CÙNG (KHÔNG HỀ LẤN VÀO CAMERA)
                VStack(spacing: 6) {
                    // Toast thông báo ngắn
                    if showToast {
                        Text(statusToast)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(Color.gray.opacity(0.5))
                            .cornerRadius(12)
                            .transition(.scale.combined(with: .opacity))
                    }

                    // Dòng chỉ số kỹ thuật HBIM thu gọn 1 hàng duy nhất
                    HStack {
                        HStack(spacing: 3) {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                            Text("ĐIỂM: \(scanner.vertexCount.formatted())")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        HStack(spacing: 3) {
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
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(6)

                    // 4 phím chức năng cốt lõi
                    HStack(spacing: 6) {
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
                            .padding(.vertical, 9)
                            .background(scanner.isScanning ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }

                        // Nút Đồng Bộ lên Laptop
                        Button(action: {
                            scanner.uploadToServer(serverIP: serverIP) { success, msg in
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
                            .padding(.vertical, 9)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }

                        // Nút Live Stream Trực Tiếp
                        Button(action: {
                            scanner.toggleLiveStream(serverIP: serverIP)
                            showNotification(scanner.isLiveStreaming ? "Đang truyền trực tiếp 3D tới Laptop" : "Đã tắt truyền trực tiếp")
                        }) {
                            Image(systemName: scanner.isLiveStreaming ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 42, height: 34)
                                .background(scanner.isLiveStreaming ? Color.red : Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        // Nút Chia Sẻ File
                        Button(action: {
                            scanner.sharePLYFile()
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 42, height: 34)
                                .background(Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 22))
                .frame(maxWidth: .infinity)
                .background(Color.black)
            }
            .background(Color.black)
            .edgesIgnoringSafeArea(.all)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(scanner: scanner, serverIP: $serverIP, onDismiss: { showingSettings = false })
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

// MARK: - Màn hình Cài Đặt Kết Nối Mạng (Hỗ trợ Cáp USB & WiFi)
struct SettingsSheet: View {
    @ObservedObject var scanner: ARScannerManager
    @Binding var serverIP: String
    var onDismiss: () -> Void
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Kết nối Đồng Bộ Laptop")) {
                    HStack {
                        Button("Cáp USB (172.20.10.2)") {
                            serverIP = "172.20.10.2"
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(serverIP == "172.20.10.2" ? .blue : .gray)

                        Spacer()

                        Button("WiFi (192.168.1.8)") {
                            serverIP = "192.168.1.8"
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(serverIP == "192.168.1.8" ? .blue : .gray)
                    }

                    TextField("Địa chỉ IP Máy chủ Laptop", text: $serverIP)
                        .keyboardType(.numbersAndPunctuation)
                        .font(.system(.body, design: .monospaced))

                    Button(action: {
                        testing = true
                        testResult = "Đang kiểm tra kết nối..."
                        scanner.testConnection(serverIP: serverIP) { success, msg in
                            testing = false
                            testResult = msg
                        }
                    }) {
                        HStack {
                            if testing {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text("Kiểm tra kết nối tới Laptop")
                        }
                    }

                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.system(size: 12))
                            .foregroundColor(scanner.isConnectedToLaptop ? .green : .red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("💡 Mẹo cắm cáp USB: Trên iPhone bật 'Điểm truy cập cá nhân' -> Laptop sẽ nhận mạng USB độ trễ 1ms.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("💡 Mẹo WiFi: iPhone và Laptop phải bắt cùng một mạng WiFi.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }

                Section(header: Text("Tùy chọn Khảo sát 3D Di tích")) {
                    Toggle("Cảnh báo vùng thưa điểm (Đỏ)", isOn: $scanner.highlightMissing)
                    Toggle("Tự động đồng bộ liên tục", isOn: $scanner.autoSyncEnabled)
                }

                Section(header: Text("Thông tin Ứng dụng")) {
                    HStack {
                        Text("Dự án")
                        Spacer()
                        Text("HBIM Cố Đô Huế")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Phiên bản")
                        Spacer()
                        Text("v1.4 - Clean Camera Viewport & Live 3D Mesh")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle("Cài Đặt", displayMode: .inline)
            .navigationBarItems(trailing: Button("Xong") { onDismiss() })
        }
    }
}
