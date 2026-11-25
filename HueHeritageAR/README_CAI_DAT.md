# Hướng Dẫn Cài Đặt & Sử Dụng — HueHeritageAR (iOS Native)

> **Dự án**: Bảo tồn Di tích Cố đô Huế — Phủ Công chúa Ngọc Sơn (1921)  
> **Phân hệ**: Ứng dụng Thực tế Tăng cường (Augmented Reality - AR) Độc Lập  
> **Target Bundle ID**: `com.vietsoftpro.hueheritagear`  
> **Nền tảng**: iOS 16.0+ (SwiftUI, ARKit 6, SceneKit)

---

## 1. Giới Thiệu Phân Định Hai Ứng Dụng Độc Lập

Dự án phân tách thành 2 ứng dụng iOS Native chuyên biệt:

| Tiêu chí | Ứng Dụng Quét Hiện Trường (`HueHeritageScanner_iOS`) | Ứng Dụng Trải Nghiệm AR (`HueHeritageAR_iOS`) |
| :--- | :--- | :--- |
| **Mục đích** | Quét dữ liệu không gian LiDAR dToF + RGB tại di tích | Xem và tương tác mô hình 3D AR di sản ngoài không gian |
| **Người dùng** | Kỹ sư khảo sát, chuyên gia đo đạc bảo tồn | Khách tham quan, nhà nghiên cứu, kiến trúc sư, công chúng |
| **Giao thức** | Truyền luồng nhị phân TCP `HUE1` cổng 18080 tới PC | Độc lập (Standalone ARKit World Tracking) |
| **Tính năng AR** | Reticle đo khoảng cách, Depth map | **2 Chế độ Tỷ Lệ (Để bàn 1:10 & Thực tế 1:1)** + **Rã mộng 4 pha** |

---

## 2. Hai Chế Độ Tỷ Lệ Không Gian (Dual Scale Modes)

Ứng dụng tối ưu hóa chuyên sâu cho cấu kiện mộng ngàm gỗ truyền thống Huế:

### 🔹 Chế độ 1: Tỷ Lệ Nhỏ Để Bàn (`Tabletop` — 1:10, ~25cm)
- **Mục đích**: Nghiên cứu, học tập, thuyết minh và trưng bày sa bàn.
- **Không gian**: Phù hợp đặt trên bàn làm việc, bàn trà, bục triển lãm.
- **Thao tác**: Dễ dàng dùng tay xoay 360°, phóng to/thu nhỏ (pinch), kéo thanh trượt bóc tách từng chốt gỗ, con bọ và mộng đuôi én từ mọi góc nhìn trên cao hoặc ngang tầm mắt.

### 🔹 Chế độ 2: Tỷ Lệ Thực Tế Ngoài Đời (`Life-Size` — 1:1, ~2.5m)
- **Mục đích**: Trải nghiệm thực tế không gian (Spatial Heritage Immersion).
- **Không gian**: Đặt trên mặt sàn phòng rộng, hội trường triển lãm, sân đình hoặc trong khuôn viên di tích thật.
- **Thao tác**: Tận dụng 6DOF World Tracking của ARKit, người dùng tự do bước đi xung quanh (walk-around), đứng dưới vì kèo ngửa cổ ngắm kết cấu chịu lực, bước sát vào để xem kích thước thực của cột cái (đường kính 32cm), trến ngang và con bọ ở tỷ lệ 100%.

---

## 3. Động Học Bóc Tách Mộng Ngàm 4 Pha (Kinematic Explode)

Thanh trượt từ 0% đến 100% mô phỏng chuẩn xác thứ tự tháo dỡ vì kèo nhà rường Huế cổ truyền:

1. **Pha 1 (0% → 25%) — Rút Chốt Âm Dương**: Rút chốt gỗ khóa xuyên tâm theo phương thẳng đứng ($+Y$).
2. **Pha 2 (25% → 50%) — Tháo Con Bọ & Xà Hạ**: Trượt con bọ đỡ dạ kèo và xà hạ ngang ($+Z, +X$).
3. **Pha 3 (50% → 75%) — Nhấc Trến Ngang**: Trến trượt nhấc ra khỏi mộng sập đầu cột cái ($+Y, -X$).
4. **Pha 4 (75% → 100%) — Bóc Tách Kèo Suốt**: Kèo suốt trượt theo góc xiên 28° hé lộ toàn bộ mộng đuôi én đầu xòe cánh quạt hoàn hảo không sử dụng đinh sắt.

---

## 4. Hướng Dẫn Biên Dịch & Nạp Vào iPhone / iPad

### Yêu Cầu Thiết Bị
- Mac chạy macOS Ventura (13.0+) hoặc Sonoma (14.0+) kèm Xcode 15+.
- Thiết bị iOS: iPhone 6s trở lên (Khuyến nghị iPhone 12 Pro trở lên có LiDAR để nhận diện mặt phẳng lập tức).
- Cài đặt công cụ [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  ```bash
  brew install xcodegen
  ```

### Các Bước Cài Đặt

1. **Sinh Xcode Project từ cấu hình `project.yml`**:
   ```bash
   cd HueHeritageAR_iOS
   xcodegen generate
   ```
   *Lệnh trên sẽ tạo tệp `HueHeritageAR.xcodeproj`.*

2. **Mở dự án trong Xcode**:
   ```bash
   open HueHeritageAR.xcodeproj
   ```

3. **Cấu hình Signing & Capabilities**:
   - Chọn Target `HueHeritageAR`.
   - Vào tab **Signing & Capabilities**.
   - Chọn **Team** (tài khoản Apple ID cá nhân miễn phí).
   - Bundle Identifier tự động: `com.vietsoftpro.hueheritagear`.

4. **Biên dịch & Chạy trên thiết bị thật**:
   - Cắm iPhone/iPad qua cáp USB hoặc Wi-Fi.
   - Chọn thiết bị của bạn trên thanh công cụ Xcode.
   - Nhấn **Run** (`Cmd + R`).
   - Trên iPhone: Vào *Cài đặt > Cài đặt chung > Quản lý VPN & Thiết bị* > Chọn tin cậy chứng chỉ nhà phát triển của bạn.

---

## 5. Hướng Dẫn Sử Dụng Nhanh

1. Mở ứng dụng **Huế Heritage AR**.
2. Hướng camera vào mặt bàn hoặc sàn nhà có đủ ánh sáng, di chuyển nhẹ nhàng.
3. Khi vòng tròn tiêu điểm màu vàng hoàng gia xuất hiện, **chạm vào màn hình để đặt mô hình**.
4. Chuyển đổi giữa tab **"Để Bàn (1:10)"** và **"Thực Tế (1:1)"** trên thanh chọn tỷ lệ.
5. Kéo thanh trượt **Động học rã mộng** hoặc nhấn **"Tự động"** để thưởng thức diễn hoạt bóc tách.
6. Nhấn nút **Camera (📷)** để lưu ảnh kỷ niệm AR độ nét cao kèm watermark di sản vào Photos.
