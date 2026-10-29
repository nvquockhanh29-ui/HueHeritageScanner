import SwiftUI
import ARKit
import SceneKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var manager: ARScannerManager

    func makeUIView(context: Context) -> ARSCNView {
        let screenBounds = UIScreen.main.bounds
        let arView = ARSCNView(frame: screenBounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.automaticallyUpdatesLighting = true
        arView.delegate = manager
        arView.session.delegate = manager

        // Hiển thị khung dây 3D wireframe đè lên vật thể
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
        ZStack {
            // CAMERA TRÀN VIỀN 100% TOÀN MÀN HÌNH (KHÔNG VIỀN ĐEN, KHÔNG MÀN HÌNH CO NHỎ)
            ARViewContainer(manager: scanner)
                .ignoresSafeArea(.all)

            // LỚP ĐIỀU KHIỂN NỔI: TOP BAR VÀ BOTTOM BAR RÕ NÉT
            VStack(spacing: 0) {
                // ==========================================
                // 1. THANH TRÊN CÙNG (TOP BAR)
                // ==========================================
                HStack(spacing: 8) {
                    // Badge Digital Twin màu cam nổi bật
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
                            .background(scanner.isTorchOn ? Color.yellow.opacity(0.3) : Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    // NÚT XÓA QUÉT LẠI (RESET)
                    Button(action: {
                        scanner.resetScan()
                        statusToast = "Đã làm mới dữ liệu quét"
                        withAnimation { showToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
                        }
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .padding(9)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    // NÚT CÀI ĐẶT
                    Button(action: { showingSettings.toggle() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .padding(9)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 48)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.85), Color.black.opacity(0.4), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Cảnh báo vùng thưa điểm
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
                    .padding(.top, 8)
                }

                Spacer()

                // Thông báo trạng thái nhanh
                if showToast {
                    Text(statusToast)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.9))
                        .cornerRadius(20)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ==========================================
                // 2. THANH DƯỚI CÙNG (BOTTOM BAR)
                // ==========================================
                VStack(spacing: 10) {
                    // Bảng thông số HBIM
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
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(10)

                    // 4 Nút điều khiển chính
                    HStack(spacing: 8) {
                        // Nút Tạm Dừng / Bắt Đầu
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
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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

                        // Nút Live Stream
                        Button(action: {
                            scanner.toggleLiveStream(serverIP: serverIP)
                        }) {
                            Image(systemName: scanner.isLiveStreaming ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 15, weight: .bold))
                                .padding(12)
                                .background(scanner.isLiveStreaming ? Color.red : Color.black.opacity(0.65))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        // Nút Chia sẻ file PLY
                        Button(action: {
                            scanner.sharePLYFile()
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .padding(12)
                                .background(Color.black.opacity(0.65))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(scanner.vertexCount == 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 36)
                .background(
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.6), Color.black.opacity(0.9)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .ignoresSafeArea(.all)
        }
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

                        Button(action: {
                            scanner.testConnection(serverIP: serverIP) { success, msg in
                                statusToast = msg
                                withAnimation { showToast = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                    withAnimation { showToast = false }
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: "network")
                                Text("Kiểm tra kết nối tới Laptop")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("💡 HƯỚNG DẪN KẾT NỐI:")
                                .font(.caption).bold().foregroundColor(.orange)
                            Text("• Nếu dùng Wi-Fi: Hãy chắc chắn iPhone đang BẬT WI-FI và cùng mạng với Laptop (không dùng 4G LTE).")
                                .font(.caption).foregroundColor(.gray)
                            Text("• Nếu dùng Cáp USB: Bật 'Điểm truy cập cá nhân' trên iPhone -> Chọn nút Cáp USB (172.20.10.2).")
                                .font(.caption).foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }

                    Section(header: Text("Tối ưu Độ chính xác")) {
                        Toggle("Đánh dấu ĐỎ vùng thiếu/chưa quét", isOn: $scanner.highlightMissing)
                        Toggle("Lọc mượt nhiễu LiDAR (Smoothing)", isOn: $scanner.enableSmoothing)
                    }
                }
                .navigationTitle("Cài Đặt Kết Nối")
                .navigationBarItems(trailing: Button("Xong") { showingSettings = false })
            }
        }
    }
}
