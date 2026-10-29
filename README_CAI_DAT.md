# Hướng Dẫn Nạp Ứng Dụng "Huế Heritage Scanner" Vào iPhone (Miễn Phí 100%)

Dự án ứng dụng iOS này được xây dựng độc lập bằng **SwiftUI + ARKit** dành riêng cho đề tài **R&D-04 Digital Twin Di tích Huế**, giúp:
- Tự động lấy lưới đo LiDAR và đám mây điểm thô.
- Xuất tệp chuẩn mở **.PLY**.
- Bấm 1 nút **"Đồng Bộ Laptop"** là dữ liệu tự động bắn qua WiFi về Server [http://localhost:8000](http://localhost:8000).
- Không có bất kỳ quảng cáo, tường phí hay giới hạn nào.

---

## 🛠️ Các Bước Cài Đặt Lên iPhone

### Yêu cầu:
- 1 máy tính Mac (MacBook hoặc Mac Mini).
- Cáp sạc kết nối iPhone vào máy Mac.
- Phần mềm **Xcode** (Tải miễn phí trên Mac App Store).

---

### Bước 1: Sao chép thư mục dự án
Chép toàn bộ thư mục `d:\DU_AN_BAO_TON_DI_TICH\HueHeritageScanner_iOS` sang máy Mac.

### Bước 2: Mở dự án trong Xcode
1. Mở Xcode ➔ Chọn **Create New Project** (hoặc mở folder vừa chép).
2. Chọn loại ứng dụng: **iOS ➔ App**.
3. Điền thông tin:
   - **Product Name:** `HueHeritageScanner`
   - **Interface:** `SwiftUI`
   - **Language:** `Swift`
4. Kéo các tệp mã nguồn vào dự án:
   - `ARScannerManager.swift`
   - `ContentView.swift`
   - `Info.plist`

### Bước 3: Cấu hình tài khoản Apple ID Miễn phí
1. Bấm vào biểu tượng dự án ở cột ngoài cùng bên trái (mục `HueHeritageScanner`).
2. Chọn tab **Signing & Capabilities**.
3. Ở dòng **Team**: Chọn Apple ID cá nhân của bạn (bấm *Add Account* và đăng nhập tài khoản iCloud đang dùng trên iPhone nếu chưa có).
4. Xcode sẽ tự động tạo chứng chỉ phát triển miễn phí (**Personal Team**).

### Bước 4: Nạp vào iPhone
1. Cắm iPhone của bạn vào máy Mac qua cáp USB/Lightning.
2. Ở thanh công cụ trên cùng của Xcode, tại mục thiết bị (bên cạnh nút Play ▶️), chọn tên chiếc **iPhone của bạn**.
3. Nhấn nút **Play (Build & Run)** hoặc bấm tổ hợp phím `Command + R`.

---

## 📲 Cho Phép Ứng Dụng Chạy Trên iPhone Lần Đầu Tiên

Khi ứng dụng đã được nạp vào iPhone, nếu mở lên hiện thông báo *"Nhà phát triển không tin cậy"*:
1. Vào **Cài đặt (Settings)** trên iPhone.
2. Chọn **Cài đặt chung (General)** ➔ **Quản lý VPN & Thiết bị (VPN & Device Management)**.
3. Bấm vào mục tài khoản Apple ID của bạn ➔ Chọn **Tin cậy (Trust)**.

Từ nay, bạn đã sở hữu một công cụ quét 3D LiDAR chính chủ, độc lập hoàn toàn cho dự án bảo tồn di tích Huế!
