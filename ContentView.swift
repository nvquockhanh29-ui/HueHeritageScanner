import SwiftUI
import ARKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var manager: ARScannerManager

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.debugOptions = [.showWorldOrigin]

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
    @State private var serverIP: String = "192.168.1.100"
    @State private var showingSettings = false
    @State private var showingShareSheet = false
    @State private var exportedURL: URL?

    var body: some View {
        ZStack {
            // Khung camera quét LiDAR AR thực tế
            ARViewContainer(manager: scanner)
                .edgesIgnoringSafeArea(.all)

            // Lớp giao diện HUD điều khiển phía trên
            VStack {
                // Header thanh trạng thái
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🏛️ HUẾ HERITAGE SCANNER")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text("Dự án Digital Twin & HBIM Di tích Cố Đô")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    Button(action: { showingSettings.toggle() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                .padding()
                .background(Color.black.opacity(0.4))

                Spacer()

                // Thông số kỹ thuật đo lường thời gian thực (LOD/LOI)
                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("ĐIỂM LIÊN KẾT (VERTICES)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.gray)
                        Text("\(scanner.vertexCount.formatted())")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    Divider().frame(height: 30).background(Color.gray)
                    VStack(alignment: .leading) {
                        Text("LƯỚI TAM GIÁC (FACES)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.gray)
                        Text("\(scanner.faceCount.formatted())")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color.black.opacity(0.65))
                .cornerRadius(12)
                .padding(.horizontal)

                // Hàng nút điều khiển tác vụ
                HStack(spacing: 12) {
                    // Nút Bật/Tắt quét
                    Button(action: {
                        if scanner.isScanning {
                            scanner.stopSession()
                        } else {
                            scanner.startSession()
                        }
                    }) {
                        HStack {
                            Image(systemName: scanner.isScanning ? "pause.fill" : "play.fill")
                            Text(scanner.isScanning ? "Tạm Dừng" : "Bắt Đầu")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(scanner.isScanning ? Color.orange : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }

                    // Nút Đồng bộ trực tiếp sang Laptop / Server
                    Button(action: {
                        scanner.uploadToServer(serverIP: serverIP) { success, msg in
                            // Thông báo hoàn thành
                        }
                    }) {
                        HStack {
                            if scanner.isUploading {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "icloud.and.arrow.up.fill")
                                Text("Đồng Bộ Laptop")
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(scanner.isUploading || scanner.vertexCount == 0)

                    // Nút Chia sẻ file độc lập (AirDrop/Zalo)
                    Button(action: {
                        if let url = scanner.exportToPLY() {
                            exportedURL = url
                            showingShareSheet = true
                        }
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(12)
                            .background(Color.gray.opacity(0.8))
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .disabled(scanner.vertexCount == 0)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationView {
                Form {
                    Section(header: Text("Cấu hình Máy Chủ Digital Twin Huế")) {
                        TextField("Địa chỉ IP Laptop (VD: 192.168.1.15)", text: $serverIP)
                            .keyboardType(.numbersAndPunctuation)
                        Text("Laptop và iPhone cần kết nối cùng một mạng WiFi hoặc Personal Hotspot.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Section(header: Text("Thông tin Ứng dụng")) {
                        Text("Phiên bản: 1.0.0 (Make in Vietnam)")
                        Text("Tác quyền: Dự án R&D-2026-0004")
                        Text("Trực thuộc: Tập đoàn Vietsoftpro & ĐH Huế")
                    }
                }
                .navigationTitle("Cài đặt Kết Nối")
                .navigationBarItems(trailing: Button("Đóng") { showingSettings = false })
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportedURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiView: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
