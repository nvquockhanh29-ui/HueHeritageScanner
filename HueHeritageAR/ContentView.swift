//
//  ContentView.swift
//  HueHeritageAR
//
//  Dự án: Bảo tồn Di tích Cố đô Huế — Phủ Công chúa Ngọc Sơn (1921)
//  Giao diện người dùng SwiftUI (Imperial Glassmorphism Theme)
//  Tách biệt hoàn toàn: Chuyên sâu Trải nghiệm Thực tế Tăng cường AR
//  - Chế độ 2 Tỷ Lệ: Để bàn (~25cm, 1:10) vs Thực tế (~2.5m, 1:1)
//  - Thanh trượt động học rã mộng 4 pha chuyên biệt cho mộng ngàm gỗ
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var arManager: ARHeritageManager
    @State private var showPhotoSavedAlert: Bool = false

    // Màu sắc chủ đạo Hoàng Gia Huế (Imperial Hue Palette)
    private let royalGold = Color(red: 0.78, green: 0.61, blue: 0.24)
    private let darkGold = Color(red: 0.60, green: 0.45, blue: 0.16)
    private let vermilionRed = Color(red: 0.62, green: 0.16, blue: 0.17)
    private let glassBg = Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.82)

    var body: some View {
        ZStack {
            // Lớp 1: Camera ARKit toàn màn hình
            ARHeritageView()
                .edgesIgnoringSafeArea(.all)

            // Lớp 2: Giao diện điều khiển nổi (Floating HUD)
            VStack(spacing: 12) {
                // Header Bar
                topHeaderBar

                // Bộ chọn Chế độ Tỷ Lệ Không Gian (Dual Scale Selector)
                scaleModeSelectorCard

                // Bộ chọn Mô hình Di sản (Model Tabs)
                modelTabsBar

                // Dòng trạng thái Tracking
                statusPill

                Spacer()

                // Bảng điều khiển Động học Rã Mộng (Explode Kinematics)
                if arManager.selectedModel == .mortiseJoint {
                    explodeControlCard
                } else {
                    houseInfoCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)

            // Reticle Prompt khi chưa đặt
            if !arManager.isPlaced && arManager.isPlaneDetected {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 16))
                            .foregroundColor(royalGold)
                        Text("Chạm vào màn hình để đặt mô hình")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(glassBg)
                    .cornerRadius(24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(royalGold.opacity(0.6), lineWidth: 1)
                    )
                    .padding(.bottom, 180)
                }
            }
        }
        .sheet(isPresented: $arManager.showGuide) {
            GuideSheetView()
        }
        .alert("Đã lưu ảnh!", isPresented: $showPhotoSavedAlert) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Ảnh chụp AR kèm watermark di tích đã được lưu an toàn vào Thư viện Ảnh của bạn.")
        }
    }

    // MARK: - Top Header Bar
    private var topHeaderBar: some View {
        HStack {
            // Logo & Tiêu đề
            HStack(spacing: 8) {
                Text("🏛️")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("HUẾ HERITAGE AR")
                        .font(.system(size: 14, weight: .black))
                        .foregroundColor(royalGold)
                        .tracking(1.2)
                    Text("Phủ Công chúa Ngọc Sơn (1921)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.8))
                }
            }

            Spacer()

            // Các nút hành động nhanh
            HStack(spacing: 10) {
                // Nút Chụp ảnh Snapshot
                Button(action: {
                    arManager.takeSnapshot()
                    showPhotoSavedAlert = true
                }) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(glassBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(royalGold.opacity(0.4), lineWidth: 1))
                }

                // Nút Reset đặt lại
                Button(action: {
                    arManager.resetPlacement()
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(glassBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }

                // Nút Hướng dẫn
                Button(action: {
                    arManager.showGuide = true
                }) {
                    Image(systemName: "questionmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(glassBg)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(glassBg)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(royalGold.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Bộ chọn Tỷ Lệ Không Gian (Dual Scale Selector)
    private var scaleModeSelectorCard: some View {
        VStack(spacing: 6) {
            Picker("Chế độ Tỷ Lệ", selection: $arManager.selectedScale) {
                ForEach(ARScaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .colorMultiply(royalGold)

            // Dòng gợi ý trải nghiệm theo tỷ lệ
            HStack(spacing: 6) {
                Image(systemName: arManager.selectedScale == .tabletop ? "table.furniture" : "figure.walk")
                    .font(.system(size: 12))
                    .foregroundColor(royalGold)
                Text(arManager.selectedScale.description)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.88))
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
        .padding(10)
        .background(glassBg)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Bộ chọn Mô hình Di sản
    private var modelTabsBar: some View {
        HStack(spacing: 8) {
            ForEach(HeritageModelType.allCases) { model in
                Button(action: {
                    arManager.selectedModel = model
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: model == .mortiseJoint ? "puzzlepiece.extension.fill" : "house.fill")
                            .font(.system(size: 12))
                        Text(model.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(arManager.selectedModel == model ? .black : .white)
                    .background(arManager.selectedModel == model ? royalGold : Color.white.opacity(0.08))
                    .cornerRadius(10)
                }
            }
        }
        .padding(6)
        .background(glassBg)
        .cornerRadius(14)
    }

    // MARK: - Dòng trạng thái Tracking
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(arManager.isPlaced ? Color.green : (arManager.isPlaneDetected ? royalGold : Color.orange))
                .frame(width: 8, height: 8)
            Text(arManager.trackingStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.92))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.65))
        .cornerRadius(20)
    }

    // MARK: - Bảng điều khiển Động học Rã Mộng 4 Pha
    private var explodeControlCard: some View {
        VStack(spacing: 10) {
            // Header tiêu đề tiến độ
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ĐỘNG HỌC RÃ MỘNG 4 PHA")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(royalGold)
                        .tracking(0.8)
                    Text(phaseDescription(for: arManager.explodeProgress))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer()
                Text("\(Int(arManager.explodeProgress * 100))%")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(royalGold)
            }

            // Thanh trượt rã mộng
            Slider(value: $arManager.explodeProgress, in: 0.0...1.0)
                .accentColor(royalGold)

            // Dấu mốc các pha
            HStack {
                Text("0% Ghép")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                Text("25% Chốt")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                Text("50% Con bọ")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                Text("75% Trến")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                Text("100% Rã")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
            }

            Divider()
                .background(Color.white.opacity(0.15))

            // Các nút thao tác nhanh
            HStack(spacing: 8) {
                // Nút Lắp Ghép (0%)
                Button("0% Ghép") {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        arManager.explodeProgress = 0.0
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)

                // Nút Bóc Tách (50%)
                Button("50% Bóc") {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        arManager.explodeProgress = 0.5
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)

                // Nút Tách Hẳn (100%)
                Button("100% Rã") {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        arManager.explodeProgress = 1.0
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)

                // Nút Tự động Chạy Animation
                Button(action: {
                    arManager.toggleAutoExplode()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: arManager.isAutoExploding ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(arManager.isAutoExploding ? "Dừng" : "Tự động")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(royalGold)
                    .cornerRadius(8)
                }
            }
        }
        .padding(14)
        .background(glassBg)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(royalGold.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Bảng Thông Tin Nhà Rường
    private var houseInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🏛️ TOÀN CẢNH NHÀ RƯỜNG HUẾ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(royalGold)
                    .tracking(0.8)
                Spacer()
                Text("1921")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(vermilionRed.opacity(0.8))
                    .cornerRadius(6)
                    .foregroundColor(.white)
            }

            Text("Phủ Công chúa Ngọc Sơn — Kiến trúc ba gian hai chái cổ truyền với kết cấu khung chịu lực hoàn toàn bằng gỗ kiền kiền và mít nài. Hệ mái ngói liệt đất nung 2 lớp bền vững qua hơn một thế kỷ.")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Color.white.opacity(0.9))
                .lineLimit(3)

            HStack(spacing: 12) {
                Label("Tỷ lệ: \(arManager.selectedScale.title)", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                Label("Khẩu độ: 12.4m", systemImage: "ruler")
                Label("Gỗ: Lim/Kiền", systemImage: "leaf")
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(royalGold)
        }
        .padding(14)
        .background(glassBg)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(royalGold.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Chú giải từng pha động học
    private func phaseDescription(for p: Float) -> String {
        switch p {
        case 0.0..<0.05:
            return "Khóa ngàm hoàn chỉnh (Chịu lực ổn định)"
        case 0.05..<0.25:
            return "Pha 1: Rút chốt âm dương thẳng đứng (+Y)"
        case 0.25..<0.50:
            return "Pha 2: Tháo con bọ đỡ kèo & xà hạ ngang (+Z)"
        case 0.50..<0.75:
            return "Pha 3: Nhấc trến ngang mộng sập cột cái (+Y)"
        case 0.75...1.00:
            return "Pha 4: Bóc tách kèo suốt mộng đuôi én (+X)"
        default:
            return "Rã hoàn toàn cấu kiện"
        }
    }
}

// MARK: - Màn hình Hướng Dẫn Trải Nghiệm (Guide Sheet)
struct GuideSheetView: View {
    @Environment(\.dismiss) var dismiss
    private let royalGold = Color(red: 0.78, green: 0.61, blue: 0.24)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    guideSection(
                        icon: "cube.transparent",
                        title: "1. Hai Chế Độ Tỷ Lệ Không Gian",
                        description: "• Để Bàn (1:10): Kích thước khoảng 25cm. Đặt trên bàn làm việc, dùng tay xoay 360 độ hoặc thu phóng để xem chi tiết mộng.\n• Thực Tế (1:1): Kích thước thật 100% (~2.5m). Đặt trên mặt sàn, bạn có thể tự do bước đi xung quanh (6DOF tracking) và ngửa cổ nhìn lên vì kèo như đang ở trong di tích thật."
                    )

                    guideSection(
                        icon: "puzzlepiece.extension",
                        title: "2. Khám Phá Động Học Rã Mộng 4 Pha",
                        description: "Kéo thanh trượt từ 0% đến 100% để bóc tách 6 cấu kiện gỗ:\n• Pha 1: Rút chốt âm dương\n• Pha 2: Tháo con bọ đỡ & xà hạ\n• Pha 3: Nhấc trến ngang mộng sập\n• Pha 4: Tách mộng đuôi én kèo suốt"
                    )

                    guideSection(
                        icon: "hand.draw",
                        title: "3. Cử Chỉ Tương Tác",
                        description: "• Chạm: Đặt mô hình khi vòng nhắm vàng xuất hiện\n• Vuốt 1 ngón: Xoay mô hình quanh trục đứng\n• Chụm 2 ngón: Phóng to hoặc thu nhỏ\n• Xoay 2 ngón: Xoay định hướng theo ý muốn"
                    )

                    guideSection(
                        icon: "exclamationmark.triangle",
                        title: "4. Lưu Ý An Toàn (Tỷ Lệ 1:1)",
                        description: "Khi trải nghiệm tỷ lệ 1:1 trong phòng rộng hoặc ngoài trời, hãy chú ý các vật cản xung quanh để di chuyển an toàn."
                    )
                }
                .padding(20)
            }
            .navigationTitle("Hướng Dẫn AR Di Sản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { dismiss() }
                        .foregroundColor(royalGold)
                }
            }
        }
    }

    private func guideSection(icon: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(royalGold)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
            }
            Text(description)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.secondary)
                .lineSpacing(4)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
