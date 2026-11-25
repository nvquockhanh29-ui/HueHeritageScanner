import Foundation
import Network
import ARKit
import simd

enum TCPConnectionState: Equatable {
    case idle
    case connecting
    case ready(String, UInt16)
    case waiting(String)
    case failed(String)
    case disconnected
}

/// Client TCP thuần sử dụng Apple Network.framework để truyền gói nhị phân HUE1
/// và thông điệp điều khiển JSON (\n-delimited) tới lidar_mesh_studio trên cổng 18080.
final class TCPStreamClient {
    private let queue = DispatchQueue(label: "vn.hueheritage.tcpStreamClient", qos: .userInitiated)

    private var connection: NWConnection?
    private var host: String = ""
    private var port: UInt16 = 18080
    private var shouldStayConnected = false
    private var isSending = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var keepaliveTimer: DispatchSourceTimer?
    private var lastSendTime: TimeInterval = 0

    var onStateChange: ((TCPConnectionState) -> Void)?

    deinit {
        let work = reconnectWorkItem
        let timer = keepaliveTimer
        let conn = connection
        work?.cancel()
        timer?.cancel()
        conn?.stateUpdateHandler = nil
        conn?.cancel()
    }

    func connect(host: String, port: UInt16 = 18080) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port >= 1, NWEndpoint.Port(rawValue: port) != nil else {
            notifyState(.failed("Địa chỉ IP hoặc cổng TCP không hợp lệ"))
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.teardownConnection(notifyDisconnected: false)
            self.shouldStayConnected = true
            self.host = trimmedHost
            self.port = port
            self.reconnectAttempt = 0
            self.startNewConnection()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.teardownConnection(notifyDisconnected: true)
        }
    }

    func isConnected(to targetHost: String, port targetPort: UInt16) -> Bool {
        let trimmedTarget = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return queue.sync {
            guard let conn = self.connection, conn.state == .ready else { return false }
            return self.host == trimmedTarget && self.port == targetPort
        }
    }

    /// Gửi nguyên vẹn 1 gói HUE1 trong một lần gọi NWConnection.send để tránh phân mảnh header 16-byte.
    /// Áp dụng backpressure qua cờ `isSending` được bảo vệ hoàn toàn trên `queue`.
    func sendFrame(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self,
                  let conn = self.connection,
                  conn.state == .ready,
                  !self.isSending else {
                completion?(false)
                return
            }

            self.isSending = true
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self = self, self.connection === conn else {
                    completion?(false)
                    return
                }
                self.isSending = false
                if let err = error {
                    self.stopKeepaliveTimer()
                    self.connection = nil
                    conn.cancel()
                    self.notifyState(.failed(err.localizedDescription))
                    self.scheduleReconnectIfNeeded()
                    completion?(false)
                } else {
                    self.lastSendTime = Date().timeIntervalSince1970
                    completion?(true)
                }
            })
        }
    }

    /// Gửi thông điệp điều khiển JSON kết thúc bằng ký tự xuống dòng `\n` (ví dụ reset_session).
    func sendControlJSON(_ dict: [String: Any], completion: ((Bool) -> Void)? = nil) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else {
            completion?(false)
            return
        }
        var payload = jsonData
        payload.append(0x0A) // '\n'

        queue.async { [weak self] in
            guard let self = self,
                  let conn = self.connection,
                  conn.state == .ready else {
                completion?(false)
                return
            }

            conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self = self, self.connection === conn else {
                    completion?(false)
                    return
                }
                if error == nil {
                    self.lastSendTime = Date().timeIntervalSince1970
                    completion?(true)
                } else {
                    completion?(false)
                }
            })
        }
    }

    // MARK: - Internal Connection & Keepalive Lifecycle (chỉ chạy trên `queue`)

    private func startNewConnection() {
        guard shouldStayConnected, !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            return
        }

        let params = Self.makeTCPParameters(connectionTimeoutSeconds: 5)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, self.connection === conn else { return }
            switch state {
            case .setup, .preparing:
                self.notifyState(.connecting)
            case .ready:
                self.reconnectAttempt = 0
                self.lastSendTime = Date().timeIntervalSince1970
                self.startReceiveLoop(on: conn)
                self.startKeepaliveTimer()
                self.notifyState(.ready(self.host, self.port))
            case .waiting(let error):
                self.stopKeepaliveTimer()
                self.notifyState(.waiting(error.localizedDescription))
            case .failed(let error):
                self.stopKeepaliveTimer()
                self.isSending = false
                self.connection = nil
                conn.cancel()
                self.notifyState(.failed(error.localizedDescription))
                self.scheduleReconnectIfNeeded()
            case .cancelled:
                self.stopKeepaliveTimer()
                self.isSending = false
                self.connection = nil
                self.notifyState(.disconnected)
            @unknown default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self = self, self.connection === conn else { return }
            if let err = error {
                self.stopKeepaliveTimer()
                self.isSending = false
                self.connection = nil
                conn.cancel()
                self.notifyState(.failed(err.localizedDescription))
                self.scheduleReconnectIfNeeded()
                return
            }
            if isComplete {
                self.stopKeepaliveTimer()
                self.isSending = false
                self.connection = nil
                conn.cancel()
                self.notifyState(.disconnected)
                self.scheduleReconnectIfNeeded()
                return
            }
            self.startReceiveLoop(on: conn)
        }
    }

    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let conn = self.connection,
                  conn.state == .ready,
                  !self.isSending else {
                return
            }
            // Chỉ gửi heartbeat khi rảnh >= 1.5s để luồng quét 0.6s không bị chèn gói ping thừa.
            let elapsed = Date().timeIntervalSince1970 - self.lastSendTime
            guard elapsed >= 1.5 else { return }

            let pingData = Data("{\"type\":\"ping\"}\n".utf8)
            self.isSending = true
            conn.send(content: pingData, completion: .contentProcessed { [weak self] error in
                guard let self = self, self.connection === conn else { return }
                self.isSending = false
                if let err = error {
                    self.stopKeepaliveTimer()
                    self.connection = nil
                    conn.cancel()
                    self.notifyState(.failed(err.localizedDescription))
                    self.scheduleReconnectIfNeeded()
                } else {
                    self.lastSendTime = Date().timeIntervalSince1970
                }
            })
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldStayConnected, reconnectWorkItem == nil else { return }
        let delays: [TimeInterval] = [1.0, 2.0, 4.0, 5.0]
        let idx = min(reconnectAttempt, delays.count - 1)
        let delay = delays[idx]
        reconnectAttempt += 1

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            guard self.shouldStayConnected, self.connection == nil else { return }
            self.startNewConnection()
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardownConnection(notifyDisconnected: Bool) {
        shouldStayConnected = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopKeepaliveTimer()
        isSending = false
        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        if notifyDisconnected {
            notifyState(.disconnected)
        }
    }

    private func notifyState(_ state: TCPConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private static func makeTCPParameters(connectionTimeoutSeconds: Int) -> NWParameters {
        let params = NWParameters.tcp
        if let tcpOpts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOpts.noDelay = true
            tcpOpts.enableKeepalive = true
            tcpOpts.keepaliveIdle = 5
            tcpOpts.connectionTimeout = connectionTimeoutSeconds
        }
        return params
    }

    // MARK: - One-Shot Probe & One-Shot Upload

    static func probeConnection(
        host: String,
        port: UInt16 = 18080,
        timeout: TimeInterval = 3.0,
        completion: @escaping (Bool, String) -> Void
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port >= 1, let nwPort = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async {
                completion(false, "Địa chỉ IP hoặc cổng TCP không hợp lệ")
            }
            return
        }

        let probeQueue = DispatchQueue(label: "vn.hueheritage.tcpProbe")
        let params = makeTCPParameters(connectionTimeoutSeconds: max(1, Int(ceil(timeout))))
        let conn = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: params)
        var finished = false

        let timeoutWork = DispatchWorkItem {
            guard !finished else { return }
            finished = true
            conn.stateUpdateHandler = nil
            conn.cancel()
            DispatchQueue.main.async {
                completion(false, "Không tìm thấy Laptop tại \(trimmedHost):\(port). Hãy kiểm tra Mobile Hotspot / Wi-Fi và bật Live Stream trên PC.")
            }
        }
        probeQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        conn.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                finished = true
                timeoutWork.cancel()
                conn.stateUpdateHandler = nil
                conn.cancel()
                DispatchQueue.main.async {
                    completion(true, "Đã kết nối TCP thành công tới \(trimmedHost):\(port)!")
                }
            case .failed(let error):
                finished = true
                timeoutWork.cancel()
                conn.stateUpdateHandler = nil
                conn.cancel()
                DispatchQueue.main.async {
                    completion(false, "Lỗi kết nối TCP \(trimmedHost):\(port): \(error.localizedDescription)")
                }
            default:
                break
            }
        }

        conn.start(queue: probeQueue)
    }

    static func sendOneShotPacket(
        _ data: Data,
        host: String,
        port: UInt16 = 18080,
        timeout: TimeInterval = 10.0,
        completion: @escaping (Bool, String) -> Void
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port >= 1, let nwPort = NWEndpoint.Port(rawValue: port) else {
            DispatchQueue.main.async {
                completion(false, "Địa chỉ IP hoặc cổng TCP không hợp lệ")
            }
            return
        }

        let sendQueue = DispatchQueue(label: "vn.hueheritage.tcpOneShot")
        let params = makeTCPParameters(connectionTimeoutSeconds: 5)
        let conn = NWConnection(host: NWEndpoint.Host(trimmedHost), port: nwPort, using: params)
        var finished = false
        var didStartSend = false

        let timeoutWork = DispatchWorkItem {
            guard !finished else { return }
            finished = true
            conn.stateUpdateHandler = nil
            conn.cancel()
            DispatchQueue.main.async {
                completion(false, "Hết thời gian chờ gửi dữ liệu tới \(trimmedHost):\(port)")
            }
        }
        sendQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        conn.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                guard !didStartSend else { return }
                didStartSend = true
                conn.send(content: data, completion: .contentProcessed { error in
                    guard !finished else { return }
                    finished = true
                    timeoutWork.cancel()
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    DispatchQueue.main.async {
                        if let err = error {
                            completion(false, "Lỗi truyền gói TCP: \(err.localizedDescription)")
                        } else {
                            completion(true, "Đồng bộ thành công qua TCP \(trimmedHost):\(port)!")
                        }
                    }
                })
            case .failed(let error):
                finished = true
                timeoutWork.cancel()
                conn.stateUpdateHandler = nil
                conn.cancel()
                DispatchQueue.main.async {
                    completion(false, "Lỗi kết nối TCP \(trimmedHost):\(port): \(error.localizedDescription)")
                }
            default:
                break
            }
        }

        conn.start(queue: sendQueue)
    }

    // MARK: - HUE1 Binary Encoder (16-byte Little-Endian Header + Z-up Tightly Packed Body)

    /// Đóng gói danh sách `ARMeshAnchor` thành gói nhị phân `HUE1` tương thích trực tiếp
    /// với `lidar_mesh_studio/streaming/protocol.py`:
    /// - Header 16 byte (`<4sHHII`): `b"HUE1"`, `version=1`, `packetType` (`2` nếu có tam giác, `1` nếu chỉ có điểm), `nVerts`, `nFaces`.
    /// - Body (`15 * nVerts + 12 * nFaces` byte):
    ///   1. `positions`: `Float32` XYZ (12 byte/đỉnh) đã xoay từ ARKit Y-up `(x, y, z)` sang Z-up `(x, -z, y)` (`det = +1`, bảo toàn chiều quấn tam giác CCW).
    ///   2. `colors`: `UInt8` RGB (3 byte/đỉnh, luôn có mặt, mặc định `(215, 180, 140)`).
    ///   3. `faces`: `UInt32` chỉ số tam giác 0-based (12 byte/tam giác).
    static func encodeHUE1Mesh(
        anchors: [ARMeshAnchor],
        anchorColors: [UUID: [UInt8]],
        scale: Float = 1.0
    ) -> Data? {
        let sortedAnchors = anchors.sorted { $0.identifier.uuidString < $1.identifier.uuidString }

        var totalVerts = 0
        var estimatedFaces = 0
        for anchor in sortedAnchors {
            totalVerts += anchor.geometry.vertices.count
            estimatedFaces += anchor.geometry.faces.count
        }
        guard totalVerts > 0 else { return nil }

        var faceIndices: [UInt32] = []
        faceIndices.reserveCapacity(estimatedFaces * 3)

        var vOffset: UInt32 = 0
        for anchor in sortedAnchors {
            let vCount = anchor.geometry.vertices.count
            let faces = anchor.geometry.faces

            if faces.primitiveType == .triangle,
               faces.indexCountPerPrimitive == 3,
               (faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4),
               faces.count > 0,
               vCount > 0 {
                let faceStride = faces.bytesPerIndex * faces.indexCountPerPrimitive
                let rawBuf = faces.buffer.contents()

                for f in 0..<faces.count {
                    let rowPtr = rawBuf.advanced(by: f * faceStride)
                    let i0: Int
                    let i1: Int
                    let i2: Int
                    if faces.bytesPerIndex == 2 {
                        let p = rowPtr.assumingMemoryBound(to: UInt16.self)
                        i0 = Int(p[0])
                        i1 = Int(p[1])
                        i2 = Int(p[2])
                    } else if faces.bytesPerIndex == 4 {
                        let p = rowPtr.assumingMemoryBound(to: UInt32.self)
                        i0 = Int(p[0])
                        i1 = Int(p[1])
                        i2 = Int(p[2])
                    } else {
                        continue
                    }

                    if i0 >= 0 && i0 < vCount && i1 >= 0 && i1 < vCount && i2 >= 0 && i2 < vCount {
                        faceIndices.append(vOffset + UInt32(i0))
                        faceIndices.append(vOffset + UInt32(i1))
                        faceIndices.append(vOffset + UInt32(i2))
                    }
                }
            }

            vOffset += UInt32(vCount)
        }

        let nFaces = faceIndices.count / 3
        let packetType: UInt16 = (nFaces > 0) ? 2 : 1

        var data = Data(capacity: 16 + (totalVerts * 15) + (nFaces * 12))

        // 16-byte Little-Endian Header (<4sHHII)
        data.append(contentsOf: [0x48, 0x55, 0x45, 0x31]) // "HUE1"
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(packetType, to: &data)
        appendLittleEndian(UInt32(totalVerts), to: &data)
        appendLittleEndian(UInt32(nFaces), to: &data)

        // 1. Positions: Float32 (x, -z, y) — đúng 12 byte/đỉnh
        for anchor in sortedAnchors {
            let vertices = anchor.geometry.vertices
            let transform = anchor.transform
            let vBuf = vertices.buffer.contents()
            let vOffsetBytes = vertices.offset
            let vStride = vertices.stride

            for i in 0..<vertices.count {
                let ptr = vBuf.advanced(by: vOffsetBytes + (vStride * i)).assumingMemoryBound(to: Float.self)
                let localCoord = simd_float4(ptr[0], ptr[1], ptr[2], 1.0)
                let worldCoord = simd_mul(transform, localCoord)

                appendFloat32LE(Float32(worldCoord.x * scale), to: &data)
                appendFloat32LE(Float32(-worldCoord.z * scale), to: &data)
                appendFloat32LE(Float32(worldCoord.y * scale), to: &data)
            }
        }

        // 2. Colors: UInt8 RGB — luôn có đủ nVerts * 3 byte
        for anchor in sortedAnchors {
            let vCount = anchor.geometry.vertices.count
            let clr = anchorColors[anchor.identifier]
            for i in 0..<vCount {
                if let clr = clr, (i * 3 + 2) < clr.count {
                    data.append(clr[i * 3])
                    data.append(clr[i * 3 + 1])
                    data.append(clr[i * 3 + 2])
                } else {
                    data.append(215)
                    data.append(180)
                    data.append(140)
                }
            }
        }

        // 3. Faces: UInt32 triangle vertex indices — đúng 12 byte/tam giác
        for idx in faceIndices {
            appendLittleEndian(idx, to: &data)
        }

        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendFloat32LE(_ value: Float32, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
