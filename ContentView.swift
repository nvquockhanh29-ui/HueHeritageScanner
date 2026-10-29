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
            // CAMERA TRÀN VIỀN 100% TOÀN MÀN HÌNH
            ARViewContainer(manager: scanner)
                .ignoresSafeArea(.all)

            // GIAO DIỆN ĐIỀU KHIỂN: SÁT VIỀN TRÊN VÀ SÁT VIỀN DƯỚI
            VStack(spacing: 0) {
                // ==========================================
                // 1. THANH TIÊU ĐỀ NẰM SÁT VIỀN TRÊN
                // ==========================================
                HStack(spacing: 8) {
                    // Badge Digital Twin màu cam nổi bật
                    Text("DIGITAL TWIN")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.orange)
                        )

                    Text("HUẾ HERITAGE")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)

                    if scanner.isLiveStreaming {
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(4)
                    }

                    Spacer()

                    // NÚT BẬT / TẮT ĐÈN FLASH
                    Button(action: {
                        scanner.toggleTorch()
                    }) {
                        Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(scanner.isTorchOn ? .yellow : .white)
                            .padding(8)
                            .background(scanner.isTorchOn ? Color.yellow.opacity(0.3) : Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    // NÚT RESET QUÉT LẠI
                    Button(action: {
                        scanner.resetScan()
                        statusToast = "Đã làm mới dữ liệu quét"
                        withAnimation { showToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
                        }
                    }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    // NÚT CÀI ĐẶT
                    Button(action: { showingSettings.toggle() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 42) // Đặt sát mép trên vừa khít dưới đồng hồ
                .padding(.bottom, 6)
                .background(Color.black.opacity(0.85))

                // Cảnh báo vùng thưa điểm
                if scanner.missingAreaCount > 0 && scanner.highlightMissing {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 11))
                        Text("Phát hiện \(scanner.missingAreaCount) vùng thưa điểm (Đang đánh dấu ĐỎ)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.9))
                    .cornerRadius(16)
                    .padding(.top, 6)
                }

                Spacer()

                // Thông báo trạng thái nhanh
                if showToast {
                    Text(statusToast)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.92))
                        .cornerRadius(18)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ==========================================
                // 2. BẢNG ĐIỀU KHIỂN NẰM SÁT VIỀN DƯỚI
                // ==========================================
                VStack(spacing: 8) {
                    // Bảng thông số HBIM
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ĐIỂM LIÊN KẾT")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.gray)
                            Text("\(scanner.vertexCount.formatted())")
                                .font(.system(size: 15, weight: .black, design: .monospaced))
                                .foregroundColor(.green)
                        }

                        Divider().frame(height: 22).background(Color.gray.opacity(0.4))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("LƯỚI TAM GIÁC")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.gray)
                            Text("\(scanner.faceCount.formatted())")
                                .font(.system(size: 15, weight: .black, design: .monospaced))
                                .foregroundColor(.yellow)
                        }

                        Divider().frame(height: 22).background(Color.gray.opacity(0.4))

                        VStack(alignment: .leading, spacing: 1) {
                            Text("SAI SỐ HBIM")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.gray)
                            Text("±\(String(format: "%.1f", scanner.accuracyErrorMM)) mm")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(scanner.accuracyErrorMM <= 1.5 ? .green : .orange)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.12))
                    .cornerRadius(8)

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
                            HStack(spacing: 4) {
                                Image(systemName: scanner.isScanning ? "pause.fill" : "play.fill")
                                Text(scanner.isScanning ? "Tạm Dừng" : "Bắt Đầu")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(scanner.isScanning ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
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
                            HStack(spacing: 4) {
                                if scanner.isUploading {
                                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Đồng Bộ")
                                }
                            }
                            .font(.system(size: 12, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(scanner.isUploading || scanner.vertexCount == 0)

                        // Nút Live Stream
                        Button(action: {
                            scanner.toggleLiveStream(serverIP: serverIP)
                        }) {
                            Image(systemName: scanner.isLiveStreaming ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right")
                                .font(.system(size: 14, weight: .bold))
                                .padding(10)
                                .background(scanner.isLiveStreaming ? Color.red : Color(white: 0.18))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }

                        // Nút Chia sẻ file PLY
                        Button(action: {
                            scanner.sharePLYFile()
                        }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .padding(10)
                                .background(Color(white: 0.18))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .disabled(scanner.vertexCount == 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20) // Nằm sát mép đáy màn hình
                .background(Color.black.opacity(0.88))
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
