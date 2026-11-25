# Hướng Dẫn Nạp & Kết Nối Ứng Dụng "Huế Heritage Scanner" (iPhone LiDAR)

Ứng dụng iOS Native (**SwiftUI + ARKit + Network.framework + AVFoundation**) dành cho dự án **Digital Twin & Bảo tồn Di tích Huế**, kết nối trực tiếp với phần mềm máy tính **`lidar_mesh_studio`** qua giao thức nhị phân **`HUE1`** trên **TCP cổng `18080`**.

## Tính Năng Chính
- Quét lưới 3D LiDAR thực địa kèm lấy mẫu màu ảnh thật từ camera.
- Quét mã **QR (`hue1://<ip>:<port>`)** trực tiếp từ hộp thoại *Live Stream* trên `lidar_mesh_studio` để tự động điền IP/Port và truyền luồng ngay lập tức (vẫn hỗ trợ nhập IP/Port thủ công, mặc định cổng `18080`).
- Hỗ trợ truyền dữ liệu qua **Mobile Hotspot từ Laptop Windows** (`192.168.137.1`), **Wi-Fi LAN**, hoặc **Điểm truy cập cá nhân trên iPhone** (`172.20.10.2`) không cần Internet.
- Xuất và chia sẻ tệp **.PLY** chuẩn tọa độ Z-up tương thích trực tiếp với `lidar_mesh_studio`.

---

## 🛠️ Các Bước Biên Dịch & Cài Đặt Lên iPhone

### Yêu cầu:
- 1 máy tính Mac (hoặc GitHub Actions `macos-14` qua `.github/workflows/build_ipa.yml`).
- Phần mềm **Xcode 15/16** và công cụ **XcodeGen** (`brew install xcodegen`).
- Cáp kết nối iPhone Pro / iPad Pro có cảm biến LiDAR (iOS 16.0+).

### Bước 1: Tạo tệp dự án Xcode từ `project.yml`
Thư mục mã nguồn chuẩn duy nhất nằm tại `HueHeritageScanner/` (gồm `HueHeritageScannerApp.swift`, `ContentView.swift`, `ARScannerManager.swift`, `TCPStreamClient.swift`, `QRScannerView.swift`, `Info.plist`, và các tệp biểu tượng ứng dụng).

```bash
cd HueHeritageScanner_iOS
xcodegen generate
open HueHeritageScanner.xcodeproj
```

### Bước 2: Cấu hình Signing & Nạp vào iPhone
1. Chọn target **`HueHeritageScanner`** ➔ tab **Signing & Capabilities**.
2. Ở dòng **Team**, chọn tài khoản Apple ID cá nhân (**Personal Team**).
3. Cắm iPhone có LiDAR vào máy Mac, chọn thiết bị trên thanh công cụ Xcode và nhấn **`Command + R`** (Build & Run).
4. Nếu iPhone báo *"Nhà phát triển không tin cậy"*, vào **Cài đặt ➔ Cài đặt chung ➔ Quản lý VPN & Thiết bị** để bấm **Tin cậy (Trust)**.

---

## 📡 Hướng Dẫn Kết Nối Hiện Trường Với `lidar_mesh_studio`

### Cách 1: Dùng Mobile Hotspot từ Laptop Windows (Khuyên dùng ngoài hiện trường)
1. Bật **Mobile Hotspot** trên Windows (IP mặc định của laptop thường là `192.168.137.1`).
2. Trên iPhone, kết nối vào mạng Wi-Fi do laptop phát.
3. Mở `lidar_mesh_studio` trên laptop ➔ mở mục **Live Stream (Cổng `18080`)** ➔ chọn giao diện mạng Mobile Hotspot để hiển thị mã QR `hue1://192.168.137.1:18080`.
4. Trên app **Huế Scanner**, bấm nút **QR** ở góc trên bên phải (hoặc trong **Cài Đặt**) và hướng camera vào mã QR trên màn hình laptop. App sẽ tự động lưu IP/Port, kết nối TCP `:18080` và bắt đầu truyền mô hình 3D trực tiếp.

### Cách 2: Nhập IP & Port Thủ Công
1. Bấm biểu tượng **Cài Đặt (⚙️)** trên app iOS.
2. Chọn nút nhanh **Hotspot PC (`192.168.137.1`)**, **Hotspot iPhone (`172.20.10.2`)**, **LAN (`192.168.1.29`)** hoặc nhập trực tiếp địa chỉ IP và Port (`18080`).
3. Bấm **"Kiểm tra kết nối TCP tới Laptop"** để xác nhận thông mạch trước khi quét.

### Quyền Hệ Thống iOS Cần Cấp
- **Camera (`NSCameraUsageDescription`)**: Dùng cho cảm biến ARKit LiDAR và quét mã QR kết nối.
- **Mạng cục bộ (`NSLocalNetworkUsageDescription`)**: Bắt buộc trên iOS để gửi gói tin TCP `HUE1` tới máy tính trong mạng Hotspot / Wi-Fi LAN.
