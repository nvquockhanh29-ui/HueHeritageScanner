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

        // Hiển thị lưới tam giác AR LiDAR thời gian thực đè lên vật thể
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
        VStack(spacing: 0) {
            // ==========================================
            // 1. VIỀN ĐEN PHÍA TRÊN (TOP BAR ĐỘC LẬP)
            // ==========================================
            HStack(spacing: 8) {
                // Nhãn Digital Twin cam nổi bật
                Text("DIGITAL TWIN")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange)
                    )

                Text("HUẾ HERITAGE")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                if scanner.isLiveStreaming {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15))
                    .cornerRadius(4)
                }

                Spacer()

                // NÚT BẬT / TẮT ĐÈN FLASH
                Button(action: {
                    scanner.toggleTorch()
                }) {
                    Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(scanner.isTorchOn ? .yellow : .white)
                        .padding(9)
                        .background(scanner.isTorchOn ? Color.yellow.opacity(0.25) : Color.white.opacity(0.12))
                        .clipShape(Circle())
                }

                // NÚT CÀI ĐẶT
                Button(action: { showingSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(9)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 50) // Chừa khoảng cách cho notch / dynamic island
            .padding(.bottom, 10)
            .background(Color.black)

            // ==========================================
            // 2. VÙNG CAMERA CHÍNH (VIEWPORT KHÔNG BỊ CHE)
            // ==========================================
            ZStack(alignment: .top) {
                ARViewContainer(manager: scanner)
                    .clipped()

                // Cảnh báo vùng thưa điểm (hiện nổi nhỏ gọn)
                if scanner.missingAreaCount > 0 && scanner.highlightMissing {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 12))
                        Text("Phát hiện \(scanner.missingAreaCount) vùng thưa điểm (Đang đánh dấu ĐỎ)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.85))
                    .cornerRadius(20)
                    .padding(.top, 10)
                }

                // Thông báo trạng thái nhanh
                if showToast {
                    VStack {
                        Spacer()
                        Text(statusToast)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.88))
                            .cornerRadius(20)
                            .padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ==========================================
            // 3. VIỀN ĐEN PHÍA DƯỚI (BOTTOM BAR ĐỘC LẬP)
            // ==========================================
            VStack(spacing: 12) {
                // Bảng thông số phân tích độ chính xác HBIM
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ĐIỂM LIÊN KẾT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.gray)
                        Text("\(scanner.vertexCount.formatted())")
                            .font(.system(size: 17, weight: .black, design: .monospaced))
                            .foregroundColor(.green)
                    }

                    Divider().frame(height: 25).background(Color.gray.opacity(0.4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("LƯỚI TAM GIÁC")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.gray)
                        Text("\(scanner.faceCount.formatted())")
                            .font(.system(size: 17, weight: .black, design: .monospaced))
                            .foregroundColor(.yellow)
                    }

                    Divider().frame(height: 25).background(Color.gray.opacity(0.4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SAI SỐ HBIM")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.gray)
                        Text("±\(String(format: "%.1f", scanner.accuracyErrorMM)) mm")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(scanner.accuracyErrorMM <= 1.5 ? .green : .orange)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(white: 0.12))
                .cornerRadius(10)

                // Hàng nút điều khiển chức năng
                HStack(spacing: 10) {
                    // Nút Tạm Dừng / Tiếp Tục
                    Button(action: {
                        if scanner.isScanning {
                            scanner.stopSession()
                        } else {
                            scanner.startSession()
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: scanner.isScanning ? "pause.fill" : "play.fill")
                            Text(scanner.isScanning ? "Tạm Dừng" : "Bắt Đầu")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(scanner.isScanning ? Color.orange : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }

                    // Nút ĐỒNG BỘ
                    Button(action: {
                        scanner.uploadToServer(serverIP: serverIP) { success, msg in
                            statusToast = msg
                            withAnimation { showToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { showToast = false }
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            if scanner.isUploading {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Đồng Bộ")
                            }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(scanner.isUploading || scanner.vertexCount == 0)

                    // Nút Real-time Stream (USB / WiFi)
                    Button(action: {
                        scanner.toggleLiveStream(serverIP: serverIP)
                    }) {
                        Image(systemName: scanner.isLiveStreaming ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 15, weight: .bold))
                            .padding(12)
                            .background(scanner.isLiveStreaming ? Color.red : Color(white: 0.2))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }

                    // Nút CHIA SẺ FILE (Mở trực tiếp native iOS Share Sheet chuẩn)
                    Button(action: {
                        scanner.sharePLYFile()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .padding(12)
                            .background(Color(white: 0.2))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(scanner.vertexCount == 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 36) // Chừa khoảng cách cho thanh gạt home indicator
            .background(Color.black)
        }
        .background(Color.black)
        .edgesIgnoringSafeArea(.all)
        .sheet(isPresented: $showingSettings) {
            NavigationView {
                Form {
                    Section(header: Text("Kết nối Đồng Bộ Laptop")) {
                        HStack {
                            Button("Cáp USB (172.20.10.2)") {
                                serverIP = "172.20.10.2"
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)

                            Button("WiFi (192.168.1.8)") {
                                serverIP = "192.168.1.8"
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)

                        TextField("Địa chỉ IP Laptop:Port", text: $serverIP)
                            .keyboardType(.numbersAndPunctuation)

                        Text("💡 Mẹo cắm cáp USB: Trên iPhone bật 'Điểm truy cập cá nhân' -> Laptop sẽ nhận mạng USB độ trễ 1ms.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    Section(header: Text("Hỗ trợ Phân tích Độ chính xác HBIM")) {
                        Toggle("Đánh dấu ĐỎ vùng thiếu/chưa quét", isOn: $scanner.highlightMissing)
                        Toggle("Bộ lọc mượt nhiễu bề mặt (Smoothing)", isOn: $scanner.enableSmoothing)
                        HStack {
                            Text("Tiêu chuẩn độ chính xác")
                            Spacer()
                            Text("HBIM LOD 300 (±1.5mm)")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
                .navigationTitle("Cài Đặt")
                .navigationBarItems(trailing: Button("Xong") { showingSettings = false })
            }
        }
    }
}
