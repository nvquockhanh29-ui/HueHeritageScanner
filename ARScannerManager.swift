import Foundation
import ARKit
import Combine
import SceneKit
import Metal
import simd
import AVFoundation
import UIKit

class ARScannerManager: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    @Published var isScanning = false
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var coverageQuality = "Chưa quét"
    @Published var isUploading = false
    @Published var isLiveStreaming = false
    @Published var enableSmoothing = true
    @Published var highlightMissing = true
    @Published var accuracyErrorMM: Double = 1.8
    @Published var scaleMultiplier: Float = 1.0
    @Published var missingAreaCount: Int = 0
    @Published var isTorchOn = false
    @Published var isConnectedToLaptop = false
    @Published var connectionStatusMsg = "Chưa kết nối"
    @Published var autoSyncEnabled = true
    @Published var statusMessage: String? = nil

    var arView: ARSCNView?

    // Bộ nhớ đệm thread-safe (Bảo toàn 100% dữ liệu quét trong phiên)
    private let meshQueue = DispatchQueue(label: "vn.hueheritage.meshQueue")
    private var allMeshAnchors: [UUID: ARMeshAnchor] = [:]
    private var anchorColors: [UUID: [UInt8]] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    private var currentAccuracyMM: Double = 1.8

    // Throttling để tối ưu hiệu năng và tránh nghẽn bộ nhớ
    private var lastMetricsUpdate: TimeInterval = 0
    private let colorTimeLock = NSLock()
    private var lastColorSampleTime: TimeInterval = 0

    // Kênh truyền TCP nhị phân HUE1 trên cổng 18080
    private let tcpClient = TCPStreamClient()
    private var liveStreamTimer: Timer?
    private var currentServerIP: String = "192.168.137.1"
    private var currentServerPort: UInt16 = 18080
    private var wasScanningBeforeQR = false
    private var wasScanningBeforeInterruption = false

    override init() {
        super.init()
        let savedScale = UserDefaults.standard.float(forKey: "scanner_scale_multiplier")
        if savedScale > 0.1 && savedScale < 10.0 {
            self.scaleMultiplier = savedScale
        }
        tcpClient.onStateChange = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .idle:
                self.isConnectedToLaptop = false
                self.connectionStatusMsg = "Chưa kết nối"
            case .connecting:
                self.isConnectedToLaptop = false
                self.connectionStatusMsg = "Đang kết nối TCP \(self.currentServerIP):\(self.currentServerPort)..."
            case .ready(let host, let port):
                self.isConnectedToLaptop = true
                self.connectionStatusMsg = "Đã kết nối TCP \(host):\(port)"
                if let msg = self.statusMessage, msg.contains("TCP") {
                    self.statusMessage = nil
                }
            case .waiting(let reason):
                self.isConnectedToLaptop = false
                self.connectionStatusMsg = "Đang chờ mạng: \(reason)"
            case .failed(let reason):
                self.isConnectedToLaptop = false
                self.connectionStatusMsg = "Mất kết nối TCP: \(reason)"
            case .disconnected:
                self.isConnectedToLaptop = false
                self.connectionStatusMsg = "Đã ngắt kết nối TCP"
            }
        }
    }

    deinit {
        liveStreamTimer?.invalidate()
        tcpClient.disconnect()
    }

    // MARK: - Cấu hình ARKit LiDAR

    private func makeTrackingConfiguration() -> ARWorldTrackingConfiguration? {
        guard ARWorldTrackingConfiguration.isSupported else {
            DispatchQueue.main.async {
                self.statusMessage = "Thiết bị không hỗ trợ ARKit World Tracking."
            }
            return nil
        }

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        } else {
            DispatchQueue.main.async {
                self.statusMessage = "Thiết bị này không có cảm biến LiDAR để dựng lưới 3D."
            }
            return nil
        }

        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]
        return configuration
    }

    func startSession() {
        guard let configuration = makeTrackingConfiguration() else {
            DispatchQueue.main.async {
                self.isScanning = false
            }
            return
        }

        DispatchQueue.main.async {
            self.statusMessage = nil
        }

        arView?.session.delegate = self
        arView?.delegate = self

        let hasData = meshQueue.sync { !allMeshAnchors.isEmpty }
        if !hasData {
            arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            arView?.session.run(configuration, options: [])
        }
        isScanning = true
    }

    func stopSession() {
        arView?.session.pause()
        isScanning = false
        stopLiveStream()
        if isTorchOn {
            toggleTorch()
        }
    }

    /// Tạm dừng ARSession trước khi mở camera quét QR mà vẫn giữ nguyên dữ liệu lưới và ý định Live Stream.
    func pauseForQR() {
        wasScanningBeforeQR = isScanning
        if isTorchOn {
            toggleTorch()
        }
        arView?.session.pause()
        isScanning = false
    }

    /// Khôi phục ARSession sau khi đóng màn hình quét QR mà không xóa các anchor đã quét.
    func resumeAfterQR() {
        if wasScanningBeforeQR {
            wasScanningBeforeQR = false
            startSession()
        }
    }

    func resetScan() {
        meshQueue.sync {
            allMeshAnchors.removeAll()
            anchorColors.removeAll()
            meshNodes.removeAll()
            currentAccuracyMM = 1.8
        }
        DispatchQueue.main.async {
            self.vertexCount = 0
            self.faceCount = 0
            self.missingAreaCount = 0
            self.coverageQuality = "Chưa quét"
            self.accuracyErrorMM = 1.8
        }

        // Gửi thông điệp xóa phiên hiển thị trên phần mềm máy tính
        notifyLaptopReset()

        guard let configuration = makeTrackingConfiguration() else {
            DispatchQueue.main.async {
                self.isScanning = false
            }
            return
        }
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
    }

    private func notifyLaptopReset() {
        tcpClient.sendControlJSON(["type": "reset_session"])
    }

    // MARK: - Điều khiển Đèn Flash

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if isTorchOn {
                device.torchMode = .off
                isTorchOn = false
            } else {
                try? device.setTorchModeOn(level: 1.0)
                device.torchMode = .on
                isTorchOn = true
            }
            device.unlockForConfiguration()
        } catch {
            print("Lỗi flash: \(error)")
        }
    }

    // MARK: - ARSessionDelegate & ARSessionObserver

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processMeshAnchors(anchors, in: session)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        processMeshAnchors(anchors, in: session)
    }

    private func processMeshAnchors(_ anchors: [ARAnchor], in session: ARSession) {
        let meshList = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshList.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        var shouldSampleColors = false
        colorTimeLock.lock()
        if now - lastColorSampleTime > 0.25 {
            lastColorSampleTime = now
            shouldSampleColors = true
        }
        colorTimeLock.unlock()

        let currentFrame = shouldSampleColors ? session.currentFrame : nil

        meshQueue.async { [weak self] in
            guard let self = self else { return }
            for anchor in meshList {
                self.allMeshAnchors[anchor.identifier] = anchor
            }

            // Quét và sơn màu ảnh thật lên các khối kiến trúc trong bán kính 5m trước camera
            if let frame = currentFrame {
                let camPos = simd_float3(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )
                for (id, anchor) in self.allMeshAnchors {
                    let anchorPos = simd_float3(
                        anchor.transform.columns.3.x,
                        anchor.transform.columns.3.y,
                        anchor.transform.columns.3.z
                    )
                    if simd_distance(camPos, anchorPos) < 5.0 {
                        let oldColors = self.anchorColors[id]
                        let colors = self.sampleCameraColors(for: anchor, frame: frame, existingColors: oldColors)
                        if !colors.isEmpty {
                            self.anchorColors[id] = colors
                        }
                    }
                }
            }
            self.throttledUpdateMeshMetrics()
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Bảo tồn toàn bộ các phần di tích đã quét trong bộ nhớ khi ARKit phân trang vùng đệm
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isScanning = false
            self.statusMessage = "Lỗi phiên ARKit: \(error.localizedDescription)"
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.wasScanningBeforeInterruption = self.isScanning
            self.isScanning = false
            self.statusMessage = "Phiên quét AR bị tạm gián đoạn."
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            self.statusMessage = nil
            if self.wasScanningBeforeInterruption && !self.wasScanningBeforeQR {
                self.wasScanningBeforeInterruption = false
                self.startSession()
            }
        }
    }

    // MARK: - Trích xuất Màu Sắc Ảnh Thực tế từ Camera LiDAR (ARKit World Space)

    private func sampleCameraColors(for anchor: ARMeshAnchor, frame: ARFrame?, existingColors: [UInt8]?) -> [UInt8] {
        guard let frame = frame else { return existingColors ?? [] }
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return existingColors ?? []
        }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let vertices = anchor.geometry.vertices
        let transform = anchor.transform
        let oldColors = existingColors

        var colors = [UInt8]()
        colors.reserveCapacity(vertices.count * 3)

        let defR: UInt8 = 215
        let defG: UInt8 = 180
        let defB: UInt8 = 140

        let camPos = simd_float3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let normals = anchor.geometry.normals
        let hasNormals = (normals.count == vertices.count)
        let bufferSize = CGSize(width: width, height: height)

        for i in 0..<vertices.count {
            let v = vertices[i]
            let worldCoord = simd_mul(transform, simd_float4(v.x, v.y, v.z, 1.0))
            let worldPoint = simd_float3(worldCoord.x, worldCoord.y, worldCoord.z)

            var sampled = false
            var r: UInt8 = defR
            var g: UInt8 = defG
            var b: UInt8 = defB

            let dist = simd_distance(camPos, worldPoint)
            if dist > 0.15 && dist < 4.5 {
                let pt = camera.projectPoint(worldPoint, orientation: .landscapeRight, viewportSize: bufferSize)
                let px = Int(pt.x)
                let py = Int(pt.y)

                if px >= 0 && px < width && py >= 0 && py < height {
                    var isValidAngle = true
                    if hasNormals {
                        let n = normals[i]
                        let worldNorm4 = simd_mul(transform, simd_float4(n.x, n.y, n.z, 0.0))
                        let worldNormRaw = simd_float3(worldNorm4.x, worldNorm4.y, worldNorm4.z)
                        let toCamRaw = camPos - worldPoint
                        if simd_length_squared(worldNormRaw) > 1e-8 && simd_length_squared(toCamRaw) > 1e-8 {
                            let worldNorm = simd_normalize(worldNormRaw)
                            let dirToCam = simd_normalize(toCamRaw)
                            if simd_dot(worldNorm, dirToCam) <= 0.05 {
                                isValidAngle = false
                            }
                        }
                    }

                    if isValidAngle {
                        let yVal = Float(yBase[py * yStride + px])
                        let uvRow = (py / 2) * uvStride
                        let uvCol = (px / 2) * 2
                        let cbVal = Float(uvBase[uvRow + uvCol]) - 128.0
                        let crVal = Float(uvBase[uvRow + uvCol + 1]) - 128.0

                        r = UInt8(clamping: Int(yVal + 1.402 * crVal))
                        g = UInt8(clamping: Int(yVal - 0.344136 * cbVal - 0.714136 * crVal))
                        b = UInt8(clamping: Int(yVal + 1.772 * cbVal))
                        sampled = true
                    }
                }
            }

            if sampled {
                colors.append(r)
                colors.append(g)
                colors.append(b)
            } else if let old = oldColors, (i * 3 + 2) < old.count {
                // Bảo tồn màu ảnh thật đã lấy mẫu trước đó kể cả khi anchor tăng số đỉnh
                colors.append(old[i * 3])
                colors.append(old[i * 3 + 1])
                colors.append(old[i * 3 + 2])
            } else {
                colors.append(defR)
                colors.append(defG)
                colors.append(defB)
            }
        }
        return colors
    }

    // MARK: - ARSCNViewDelegate: Hiển thị Wireframe Mesh

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }

        let node = SCNNode()
        node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        meshQueue.async { [weak self] in
            self?.meshNodes[meshAnchor.identifier] = node
        }
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        let curCount = node.geometry?.sources.first?.vectorCount ?? 0
        if abs(curCount - meshAnchor.geometry.vertices.count) > 20 {
            node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            meshQueue.async { [weak self] in
                self?.meshNodes.removeValue(forKey: meshAnchor.identifier)
            }
        }
    }

    private func createVisualizationGeometry(meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let scnGeom = SCNGeometry(arMeshGeometry: meshAnchor.geometry)
        let material = SCNMaterial()
        material.fillMode = .lines
        material.isDoubleSided = true

        let vCount = meshAnchor.geometry.vertices.count
        if highlightMissing && vCount < 400 {
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.85)
        } else {
            material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        }

        scnGeom.materials = [material]
        return scnGeom
    }

    private func throttledUpdateMeshMetrics() {
        let now = Date().timeIntervalSince1970
        guard now - lastMetricsUpdate > 0.3 else { return }
        lastMetricsUpdate = now

        var totalVerts = 0
        var totalFaces = 0
        var sparseChunks = 0

        for anchor in allMeshAnchors.values {
            let v = anchor.geometry.vertices.count
            totalVerts += v
            totalFaces += anchor.geometry.faces.count
            if v < 400 {
                sparseChunks += 1
            }
        }

        let qualityLabel: String
        let accuracy: Double
        if totalVerts < 10000 {
            qualityLabel = "Thấp (Cần quét thêm)"
            accuracy = 3.2
        } else if totalVerts < 40000 {
            qualityLabel = "Trung bình"
            accuracy = 2.0
        } else {
            qualityLabel = "Chuẩn HBIM (LOD 300)"
            accuracy = 1.1
        }
        currentAccuracyMM = accuracy

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.vertexCount = totalVerts
            self.faceCount = totalFaces
            self.missingAreaCount = sparseChunks
            self.coverageQuality = qualityLabel
            self.accuracyErrorMM = accuracy
        }
    }

    // MARK: - Kiểm tra kết nối TCP tới Laptop (Mặc định cổng 18080)

    func testConnection(serverIP: String, port: UInt16 = 18080, completion: @escaping (Bool, String) -> Void) {
        TCPStreamClient.probeConnection(host: serverIP, port: port) { [weak self] success, msg in
            if let self = self, !self.isLiveStreaming {
                self.isConnectedToLaptop = success
                self.connectionStatusMsg = msg
            }
            completion(success, msg)
        }
    }

    // MARK: - Live Stream TCP (Gói nhị phân HUE1 thời gian thực)

    func toggleLiveStream(serverIP: String, port: UInt16 = 18080) {
        currentServerIP = serverIP
        currentServerPort = port
        if isLiveStreaming {
            stopLiveStream()
        } else {
            startLiveStream(serverIP: serverIP, port: port)
        }
    }

    func startLiveStream(serverIP: String, port: UInt16 = 18080) {
        currentServerIP = serverIP
        currentServerPort = port
        isLiveStreaming = true
        tcpClient.connect(host: serverIP, port: port)

        liveStreamTimer?.invalidate()
        liveStreamTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, self.isScanning, self.vertexCount > 0 else { return }
            self.streamLiveMeshBatch()
        }
    }

    /// Tự động bật phiên quét (nếu cần), kết nối TCP và truyền luồng ngay sau khi quét mã QR.
    func connectAndStartStream(serverIP: String, port: UInt16 = 18080) {
        currentServerIP = serverIP
        currentServerPort = port
        if !isScanning {
            startSession()
        }
        startLiveStream(serverIP: serverIP, port: port)
    }

    func setScaleMultiplier(_ value: Float) {
        let clamped = max(0.2, min(5.0, value))
        self.scaleMultiplier = clamped
        UserDefaults.standard.set(clamped, forKey: "scanner_scale_multiplier")
    }

    private func streamLiveMeshBatch() {
        meshQueue.async { [weak self] in
            guard let self = self else { return }
            let anchorsSnapshot = Array(self.allMeshAnchors.values)
            guard !anchorsSnapshot.isEmpty else { return }
            let colorsSnapshot = self.anchorColors

            guard let packet = TCPStreamClient.encodeHUE1Mesh(
                anchors: anchorsSnapshot,
                anchorColors: colorsSnapshot,
                scale: self.scaleMultiplier
            ) else {
                return
            }

            self.tcpClient.sendFrame(packet)
        }
    }

    func stopLiveStream() {
        isLiveStreaming = false
        liveStreamTimer?.invalidate()
        liveStreamTimer = nil
        tcpClient.disconnect()
    }

    // MARK: - Xuất file PLY (Hệ tọa độ Z-up nhất quán với lidar_mesh_studio)

    func exportToPLY() -> URL? {
        let (anchorsSnapshot, colorsSnapshot, accuracyMM) = meshQueue.sync {
            (
                allMeshAnchors.values.sorted { $0.identifier.uuidString < $1.identifier.uuidString },
                anchorColors,
                currentAccuracyMM
            )
        }
        guard !anchorsSnapshot.isEmpty else { return nil }

        var totalV = 0
        var validFaceTriplets: [UInt32] = []
        var vOffset = 0
        for anchor in anchorsSnapshot {
            let vCount = anchor.geometry.vertices.count
            let faces = anchor.geometry.faces
            totalV += vCount

            if faces.primitiveType == .triangle && faces.indexCountPerPrimitive == 3 && (faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4) && faces.count > 0 && vCount > 0 {
                for i in 0..<faces.count {
                    let i0 = Int(faces[i, 0])
                    let i1 = Int(faces[i, 1])
                    let i2 = Int(faces[i, 2])
                    if i0 >= 0 && i0 < vCount && i1 >= 0 && i1 < vCount && i2 >= 0 && i2 < vCount {
                        validFaceTriplets.append(UInt32(i0 + vOffset))
                        validFaceTriplets.append(UInt32(i1 + vOffset))
                        validFaceTriplets.append(UInt32(i2 + vOffset))
                    }
                }
            }
            vOffset += vCount
        }

        let totalF = validFaceTriplets.count / 3
        guard totalV > 0 else { return nil }

        let fileName = "HueHeritage_\(Int(Date().timeIntervalSince1970)).ply"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else { return nil }

        defer {
            try? fileHandle.close()
        }

        let header = """
        ply
        format ascii 1.0
        comment Hue Heritage Scanner - Digital Twin & HBIM (Z-up)
        comment Estimated Accuracy: ±\(String(format: "%.1f", accuracyMM)) mm
        element vertex \(totalV)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(totalF)
        property list uchar int vertex_indices
        end_header
        
        """

        if let headerData = header.data(using: .utf8) {
            fileHandle.write(headerData)
        }

        var vertexChunk = ""
        for anchor in anchorsSnapshot {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let clr = colorsSnapshot[anchor.identifier]

            for i in 0..<vertices.count {
                let v = vertices[i]
                let localCoord = simd_float4(v.x, v.y, v.z, 1.0)
                let worldCoord = simd_mul(transform, localCoord)

                // Chuyển ARKit Y-up (x, y, z) -> Z-up (x, -z, y) nhất quán với gói HUE1
                let scale = self.scaleMultiplier
                let zx = worldCoord.x * scale
                let zy = -worldCoord.z * scale
                let zz = worldCoord.y * scale

                var r: UInt8 = 215
                var g: UInt8 = 180
                var b: UInt8 = 140

                if let clr = clr, (i * 3 + 2) < clr.count {
                    r = clr[i * 3]
                    g = clr[i * 3 + 1]
                    b = clr[i * 3 + 2]
                }

                vertexChunk += String(format: "%.4f %.4f %.4f %d %d %d\n", zx, zy, zz, r, g, b)

                if vertexChunk.count > 16384 {
                    if let d = vertexChunk.data(using: .utf8) { fileHandle.write(d) }
                    vertexChunk = ""
                }
            }
        }
        if !vertexChunk.isEmpty, let d = vertexChunk.data(using: .utf8) {
            fileHandle.write(d)
        }

        var faceChunk = ""
        var faceIdx = 0
        while faceIdx + 2 < validFaceTriplets.count {
            let idx0 = validFaceTriplets[faceIdx]
            let idx1 = validFaceTriplets[faceIdx + 1]
            let idx2 = validFaceTriplets[faceIdx + 2]
            faceChunk += "3 \(idx0) \(idx1) \(idx2)\n"
            faceIdx += 3

            if faceChunk.count > 16384 {
                if let d = faceChunk.data(using: .utf8) { fileHandle.write(d) }
                faceChunk = ""
            }
        }
        if !faceChunk.isEmpty, let d = faceChunk.data(using: .utf8) {
            fileHandle.write(d)
        }

        return tempURL
    }

    // MARK: - Chia sẻ file PLY chuẩn iOS

    func sharePLYFile() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let url = self.exportToPLY() else { return }
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first,
                      let rootVC = keyWindow.rootViewController else {
                    return
                }

                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = rootVC.view
                    popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.maxY - 80, width: 0, height: 0)
                    popover.permittedArrowDirections = [.down]
                }

                var topController = rootVC
                while let presented = topController.presentedViewController {
                    topController = presented
                }
                topController.present(activityVC, animated: true)
            }
        }
    }

    // MARK: - Đồng bộ tức thời lên Laptop qua TCP cổng 18080 (gói HUE1)

    func uploadToServer(
        serverIP: String,
        port: UInt16 = 18080,
        isBackgroundStream: Bool = false,
        completion: @escaping (Bool, String) -> Void
    ) {
        if !isBackgroundStream {
            isUploading = true
        }

        meshQueue.async { [weak self] in
            guard let self = self else { return }
            let anchorsSnapshot = Array(self.allMeshAnchors.values)
            let colorsSnapshot = self.anchorColors

            guard !anchorsSnapshot.isEmpty,
                  let packet = TCPStreamClient.encodeHUE1Mesh(
                      anchors: anchorsSnapshot,
                      anchorColors: colorsSnapshot
                  ) else {
                DispatchQueue.main.async {
                    if !isBackgroundStream { self.isUploading = false }
                    completion(false, "Chưa có dữ liệu quét để đồng bộ")
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if self.tcpClient.isConnected(to: serverIP, port: port) {
                    self.tcpClient.sendFrame(packet) { [weak self] ok in
                        DispatchQueue.main.async {
                            if !isBackgroundStream { self?.isUploading = false }
                            if ok {
                                self?.isConnectedToLaptop = true
                                completion(true, "Đã đồng bộ mô hình 3D qua TCP \(serverIP):\(port)!")
                            } else {
                                self?.isConnectedToLaptop = false
                                completion(false, "Lỗi truyền gói TCP tới \(serverIP):\(port)")
                            }
                        }
                    }
                } else {
                    TCPStreamClient.sendOneShotPacket(packet, host: serverIP, port: port) { [weak self] ok, msg in
                        DispatchQueue.main.async {
                            if !isBackgroundStream { self?.isUploading = false }
                            self?.isConnectedToLaptop = ok
                            self?.connectionStatusMsg = msg
                            completion(ok, msg)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Extensions ARKit & SceneKit (Đọc an toàn 12-byte Float32 và 16/32-bit Index)

private extension ARGeometrySource {
    subscript(index: Int) -> simd_float3 {
        let pointer = buffer.contents().advanced(by: offset + (self.stride * index))
        let floats = pointer.assumingMemoryBound(to: Float.self)
        return simd_float3(floats[0], floats[1], floats[2])
    }
}

private extension ARGeometryElement {
    subscript(faceIndex: Int, vertexIndex: Int) -> UInt32 {
        let faceStride = self.bytesPerIndex * self.indexCountPerPrimitive
        let pointer = buffer.contents().advanced(by: (faceIndex * faceStride) + (vertexIndex * self.bytesPerIndex))
        if self.bytesPerIndex == 2 {
            return UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
        } else if self.bytesPerIndex == 4 {
            return pointer.assumingMemoryBound(to: UInt32.self).pointee
        } else {
            return UInt32.max
        }
    }
}

private extension SCNGeometry {
    convenience init(arMeshGeometry: ARMeshGeometry) {
        let vertices = arMeshGeometry.vertices
        let normals = arMeshGeometry.normals
        let faces = arMeshGeometry.faces

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        var sources: [SCNGeometrySource] = [vertexSource]

        if normals.count > 0 {
            let normalSource = SCNGeometrySource(
                buffer: normals.buffer,
                vertexFormat: normals.format,
                semantic: .normal,
                vertexCount: normals.count,
                dataOffset: normals.offset,
                dataStride: normals.stride
            )
            sources.append(normalSource)
        }

        let faceData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let faceElement = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        self.init(sources: sources, elements: [faceElement])
    }
}
