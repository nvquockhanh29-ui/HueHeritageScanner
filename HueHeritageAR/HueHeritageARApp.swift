//
//  HueHeritageARApp.swift
//  HueHeritageAR
//
//  Dự án: Bảo tồn Di tích Cố đô Huế — Phủ Công chúa Ngọc Sơn (1921)
//  Ứng dụng Thực tế Tăng cường (AR) Độc Lập Chuyên Sâu
//  Tách biệt hoàn toàn với App Quét LiDAR hiện trường (HueHeritageScanner)
//

import SwiftUI

@main
struct HueHeritageARApp: App {
    @StateObject private var arManager = ARHeritageManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(arManager)
                .preferredColorScheme(.dark)
        }
    }
}
