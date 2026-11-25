//
//  ARHeritageManager.swift
//  HueHeritageAR
//
//  Dự án: Bảo tồn Di tích Cố đô Huế — Phủ Công chúa Ngọc Sơn (1921)
//  Bộ điều khiển Thực tế Tăng cường (AR) Chuyên Sâu:
//    1. Hỗ trợ 2 chế độ tỷ lệ:
//       - Tỷ lệ nhỏ để bàn (.tabletop ~25cm, 1:10)
//       - Tỷ lệ kích thước thật (.lifeSize ~2.5m, 1:1)
//    2. Động học bóc tách mộng ngàm 4 pha (Kinematic Explode 0% -> 100%)
//    3. Nhận diện mặt phẳng sàn/bàn (ARKit Horizontal Plane Detection)
//    4. Vòng nhắm tiêu điểm thông minh (Smart Focus Reticle)
//    5. Tương tác cử chỉ: Chạm đặt (Tap-to-place), Xoay (Rotate), Thu phóng (Pinch)
//

import Foundation
import SwiftUI
import ARKit
import SceneKit

// MARK: - Chế độ Tỷ Lệ Không Gian
enum ARScaleMode: String, CaseIterable, Identifiable {
    case tabletop = "tabletop"
    case lifeSize = "1to1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabletop: return "Để Bàn (1:10)"
        case .lifeSize: return "Thực Tế (1:1)"
        }
    }

    var scaleFactor: Float {
        switch self {
        case .tabletop: return 0.12 // Thu nhỏ ~25cm - 30cm, hoàn hảo cho mặt bàn
        case .lifeSize: return 1.00 // Kích thước thật 100% (~2.5m), đứng dưới vì kèo
        }
    }

    var description: String {
        switch self {
        case .tabletop:
            return "Đặt trên bàn làm việc (~25cm). Tự do xoay 360°, phóng to để ngắm kỹ thuật ngàm chốt không đinh sắt."
        case .lifeSize:
            return "Kích thước thật 1:1 (~2.5m). Đặt trên mặt sàn, bước vào đứng ngay dưới vì kèo ngắm thớ gỗ lim và con bọ ở tầm mắt thật."
        }
    }

    var badgeText: String {
        switch self {
        case .tabletop: return "SA BÀN ĐỂ BÀN — TỶ LỆ 1:10"
        case .lifeSize: return "KHÔNG GIAN THỰC — TỶ LỆ 1:1"
        }
    }
}

// MARK: - Danh mục Mô hình Di sản
enum HeritageModelType: String, CaseIterable, Identifiable {
    case mortiseJoint = "mongngam"
    case nharuongHouse = "nharuong"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mortiseJoint: return "Chi Tiết Mộng Ngàm"
        case .nharuongHouse: return "Toàn Cảnh Nhà Rường"
        }
    }

    var subtitle: String {
        switch self {
        case .mortiseJoint: return "Cụm vì kèo chồng rường — Liên kết ngàm âm dương"
        case .nharuongHouse: return "Nhà ba gian hai chái Phủ Công chúa Ngọc Sơn (1921)"
        }
    }
}

// MARK: - Trình quản lý AR Chính
class ARHeritageManager: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {

    // Published UI States
    @Published var selectedScale: ARScaleMode = .tabletop {
        didSet { applyScaleTransition() }
    }
    @Published var selectedModel: HeritageModelType = .mortiseJoint {
        didSet { reloadActiveModel() }
    }
    @Published var explodeProgress: Float = 0.0 {
        didSet { updateExplodeKinematics() }
    }
    @Published var isPlaced: Bool = false
    @Published var isPlaneDetected: Bool = false
    @Published var trackingStatusText: String = "Đang quét tìm mặt phẳng..."
    @Published var isAutoExploding: Bool = false
    @Published var capturedSnapshot: UIImage? = nil
    @Published var showGuide: Bool = false

    // AR & SceneKit Nodes
    var sceneView: ARSCNView?
    private var rootAnchorNode: SCNNode?
    private var reticleNode: SCNNode?
    private var modelContainerNode: SCNNode?

    // Joint Component Nodes for Kinematic Explode
    private var cotCaiNode: SCNNode?       // Cột cái chính
    private var trenNgangNode: SCNNode?     // Trến ngang (Xà giằng)
    private var xaHaNode: SCNNode?          // Xà hạ
    private var conBoNode: SCNNode?         // Con bọ đỡ kèo
    private var keoSuotNode: SCNNode?       // Kèo suốt / Kèo chồng
    private var chotAmDuongNode: SCNNode?   // Chốt âm dương gỗ

    // Kinematic Initial Positions
    private var initialOffsets: [String: SCNVector3] = [:]

    // Auto-explode timer
    private var autoTimer: Timer?
    private var autoDirection: Float = 1.0

    override init() {
        super.init()
    }

    // MARK: - Cài đặt ARSCNView
    func setupSceneView(_ view: ARSCNView) {
        self.sceneView = view
        view.delegate = self
        view.session.delegate = self
        view.autoenablesDefaultLighting = false
        view.automaticallyUpdatesLighting = true

        // Thiết lập ánh sáng môi trường ấm áp kiểu di sản hoàng cung
        setupImperialLighting(in: view.scene)

        // Tạo vòng nhắm tiêu điểm Reticle
        setupFocusReticle()

        // Khởi động AR World Tracking
        startARSession()
    }

    func startARSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            trackingStatusText = "Thiết bị không hỗ trợ ARKit World Tracking"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true

        sceneView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        trackingStatusText = "Hướng camera vào mặt sàn hoặc bàn làm việc..."
        isPlaced = false
    }

    // MARK: - Thiết lập Ánh Sáng Hoàng Gia (Imperial Heritage Lighting)
    private func setupImperialLighting(in scene: SCNScene) {
        // Ánh sáng Ambient vàng hoàng cung nhẹ
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = UIColor(red: 0.95, green: 0.90, blue: 0.82, alpha: 1.0)
        ambientLight.intensity = 800

        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Ánh sáng Directional (mặt trời chiếu xiên tạo khối nổi cho các thớ gỗ)
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.color = UIColor(red: 1.0, green: 0.96, blue: 0.88, alpha: 1.0)
        directionalLight.intensity = 1200
        directionalLight.castsShadow = true
        directionalLight.shadowMode = .deferred
        directionalLight.shadowSampleCount = 8
        directionalLight.shadowRadius = 4.0
        directionalLight.shadowColor = UIColor(white: 0.0, alpha: 0.45)

        let dirNode = SCNNode()
        dirNode.light = directionalLight
        dirNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)
    }

    // MARK: - Vòng Nhắm Tiêu Điểm Reticle (Focus Square Ring)
    private func setupFocusReticle() {
        guard let scene = sceneView?.scene else { return }

        // Vòng tròn vàng đồng hoàng gia (#C89B3C)
        let ringGeo = SCNTorus(ringRadius: 0.12, pipeRadius: 0.003)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents = UIColor(red: 0.78, green: 0.61, blue: 0.24, alpha: 0.9)
        ringMat.emission.contents = UIColor(red: 0.78, green: 0.61, blue: 0.24, alpha: 0.3)
        ringGeo.materials = [ringMat]

        let reticle = SCNNode(geometry: ringGeo)
        reticle.name = "FocusReticle"
        reticle.isHidden = true
        scene.rootNode.addChildNode(reticle)
        self.reticleNode = reticle
    }

    // MARK: - Cập nhật Frame AR (Raycasting tìm vị trí đặt)
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let sceneView = sceneView else { return }

        DispatchQueue.main.async {
            // Khi chưa đặt mô hình, cập nhật vòng nhắm tâm màn hình
            if !self.isPlaced {
                let centerPoint = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
                if let query = sceneView.raycastQuery(from: centerPoint, allowing: .estimatedPlane, alignment: .horizontal) {
                    let results = sceneView.session.raycast(query)
                    if let firstHit = results.first {
                        self.reticleNode?.simdTransform = firstHit.worldTransform
                        self.reticleNode?.isHidden = false
                        self.isPlaneDetected = true
                        self.trackingStatusText = "Chạm vào màn hình để đặt \(self.selectedModel.title)"
                        return
                    }
                }
                self.reticleNode?.isHidden = true
                self.isPlaneDetected = false
                self.trackingStatusText = "Di chuyển camera nhẹ nhàng để nhận diện mặt phẳng..."
            } else {
                self.reticleNode?.isHidden = true
            }
        }
    }

    // MARK: - Hành động Chạm Đặt Mô Hình (Tap to Place)
    func placeModelAtReticle() {
        guard let reticle = reticleNode, !reticle.isHidden, let sceneView = sceneView else { return }

        // Ẩn reticle
        reticle.isHidden = true
        isPlaced = true

        // Xóa node cũ nếu có
        rootAnchorNode?.removeFromParentNode()

        // Tạo Root Anchor Node tại vị trí Reticle
        let anchor = SCNNode()
        anchor.simdTransform = reticle.simdTransform
        sceneView.scene.rootNode.addChildNode(anchor)
        self.rootAnchorNode = anchor

        // Shadow Plane nhận bóng đổ thực tế trên sàn/bàn
        let shadowPlane = SCNPlane(width: 5.0, height: 5.0)
        let shadowMat = SCNMaterial()
        shadowMat.colorBufferWriteMask = [] // Không vẽ màu (trong suốt)
        shadowMat.readsFromDepthBuffer = true
        shadowPlane.materials = [shadowMat]

        let shadowNode = SCNNode(geometry: shadowPlane)
        shadowNode.eulerAngles.x = -Float.pi / 2
        shadowNode.position = SCNVector3(0, -0.001, 0)
        anchor.addChildNode(shadowNode)

        // Tạo Container chứa mô hình
        let container = SCNNode()
        container.name = "ModelContainer"
        anchor.addChildNode(container)
        self.modelContainerNode = container

        // Tải nội dung mô hình theo loại đã chọn
        buildHeritageModel(in: container)

        // Áp dụng tỷ lệ ban đầu
        applyScaleTransition(animated: false)

        trackingStatusText = "Đã đặt mô hình thành công. Sử dụng cử chỉ xoay/thu phóng hoặc thanh trượt rã mộng."
    }

    // MARK: - Chuyển đổi Tỷ Lệ (Dual Scale Transition)
    func applyScaleTransition(animated: Bool = true) {
        guard let container = modelContainerNode else { return }

        let targetScale = selectedScale.scaleFactor
        let scaleVec = SCNVector3(targetScale, targetScale, targetScale)

        if animated {
            let scaleAction = SCNAction.scale(to: CGFloat(targetScale), duration: 0.45)
            scaleAction.timingMode = .easeInEaseOut
            container.runAction(scaleAction)
        } else {
            container.scale = scaleVec
        }
    }

    // MARK: - Tải lại Mô hình khi chuyển tab
    func reloadActiveModel() {
        guard let container = modelContainerNode else { return }
        container.enumerateChildNodes { (child, _) in
            child.removeFromParentNode()
        }
        buildHeritageModel(in: container)
        applyScaleTransition(animated: false)
        updateExplodeKinematics()
    }

    // MARK: - Xây dựng Mô hình Cấu Kiện Gỗ Di Sản
    private func buildHeritageModel(in parent: SCNNode) {
        initialOffsets.removeAll()

        switch selectedModel {
        case .mortiseJoint:
            buildMortiseTenonJoint(in: parent)
        case .nharuongHouse:
            buildNhaRuongOverview(in: parent)
        }
    }

    // MARK: - Dựng Cụm Mộng Ngàm Vì Kèo Chồng Rường Huế (Mortise & Tenon Assembly)
    private func buildMortiseTenonJoint(in parent: SCNNode) {
        // Vật liệu gỗ Lim / Kiền Kiền Cố Đô Huế màu nâu gụ hoàng tộc
        let woodMaterial = SCNMaterial()
        woodMaterial.diffuse.contents = UIColor(red: 0.36, green: 0.22, blue: 0.12, alpha: 1.0)
        woodMaterial.roughness.contents = 0.65
        woodMaterial.metalness.contents = 0.05

        // Vật liệu gỗ phụ (Trến và Con bọ) màu sáng hơn chút
        let secondaryWoodMaterial = SCNMaterial()
        secondaryWoodMaterial.diffuse.contents = UIColor(red: 0.44, green: 0.28, blue: 0.15, alpha: 1.0)
        woodMaterial.roughness.contents = 0.60

        // Vật liệu chốt gỗ âm dương (Đậm màu sơn dầu ta)
        let pegMaterial = SCNMaterial()
        pegMaterial.diffuse.contents = UIColor(red: 0.25, green: 0.14, blue: 0.08, alpha: 1.0)

        // 1. Cột Cái Chính (Master Column) - Trụ gỗ tròn đường kính 32cm, cao 2.2m
        let colGeo = SCNCylinder(radius: 0.16, height: 2.2)
        colGeo.materials = [woodMaterial]
        let colNode = SCNNode(geometry: colGeo)
        colNode.position = SCNVector3(0, 1.1, 0)
        colNode.name = "CotCai"
        parent.addChildNode(colNode)
        self.cotCaiNode = colNode

        // 2. Trến Ngang (Tie Beam) - Liên kết sập đè trến cột cái
        let trenGeo = SCNBox(width: 1.8, height: 0.26, length: 0.18, chamferRadius: 0.015)
        trenGeo.materials = [secondaryWoodMaterial]
        let trenNode = SCNNode(geometry: trenGeo)
        let trenInitPos = SCNVector3(0, 2.05, 0)
        trenNode.position = trenInitPos
        trenNode.name = "TrenNgang"
        parent.addChildNode(trenNode)
        self.trenNgangNode = trenNode
        initialOffsets["TrenNgang"] = trenInitPos

        // 3. Xà Hạ (Lower Purlin) - Chạy dọc nhà xuyên qua đầu cột
        let xaGeo = SCNBox(width: 0.18, height: 0.22, length: 1.6, chamferRadius: 0.015)
        xaGeo.materials = [woodMaterial]
        let xaNode = SCNNode(geometry: xaGeo)
        let xaInitPos = SCNVector3(0, 1.90, 0)
        xaNode.position = xaInitPos
        xaNode.name = "XaHa"
        parent.addChildNode(xaNode)
        self.xaHaNode = xaNode
        initialOffsets["XaHa"] = xaInitPos

        // 4. Con Bọ Đỡ Kèo (Carved Bracket) - Chạm hoa văn mây lửa đỡ dạ kèo
        let boGeo = SCNBox(width: 0.35, height: 0.16, length: 0.16, chamferRadius: 0.02)
        boGeo.materials = [secondaryWoodMaterial]
        let boNode = SCNNode(geometry: boGeo)
        let boInitPos = SCNVector3(0.25, 1.85, 0.12)
        boNode.position = boInitPos
        boNode.name = "ConBo"
        parent.addChildNode(boNode)
        self.conBoNode = boNode
        initialOffsets["ConBo"] = boInitPos

        // 5. Kèo Suốt / Kèo Chồng (Rafter Joint) - Mộng đuôi én xòe cánh quạt nghiêng 28°
        let keoGeo = SCNBox(width: 2.0, height: 0.22, length: 0.16, chamferRadius: 0.015)
        keoGeo.materials = [woodMaterial]
        let keoNode = SCNNode(geometry: keoGeo)
        keoNode.eulerAngles.z = Float(-28.0 * .pi / 180.0) // Độ dốc mái nhà rường Huế
        let keoInitPos = SCNVector3(0.65, 2.30, 0)
        keoNode.position = keoInitPos
        keoNode.name = "KeoSuot"
        parent.addChildNode(keoNode)
        self.keoSuotNode = keoNode
        initialOffsets["KeoSuot"] = keoInitPos

        // 6. Chốt Âm Dương Gỗ (Vertical Locking Dowel) - Khóa toàn bộ cụm ngàm
        let chotGeo = SCNCylinder(radius: 0.022, height: 0.55)
        chotGeo.materials = [pegMaterial]
        let chotNode = SCNNode(geometry: chotGeo)
        let chotInitPos = SCNVector3(0, 2.20, 0)
        chotNode.position = chotInitPos
        chotNode.name = "ChotAmDuong"
        parent.addChildNode(chotNode)
        self.chotAmDuongNode = chotNode
        initialOffsets["ChotAmDuong"] = chotInitPos
    }

    // MARK: - Dựng Mô hình Toàn Cảnh Nhà Rường (Overview Model)
    private func buildNhaRuongOverview(in parent: SCNNode) {
        let woodMat = SCNMaterial()
        woodMat.diffuse.contents = UIColor(red: 0.38, green: 0.24, blue: 0.14, alpha: 1.0)

        let roofMat = SCNMaterial()
        roofMat.diffuse.contents = UIColor(red: 0.62, green: 0.31, blue: 0.18, alpha: 1.0) // Ngói liệt đất nung Huế

        let stoneMat = SCNMaterial()
        stoneMat.diffuse.contents = UIColor(red: 0.72, green: 0.72, blue: 0.70, alpha: 1.0) // Đá thanh chân tảng

        // Nền đá thanh
        let baseGeo = SCNBox(width: 5.6, height: 0.25, length: 4.2, chamferRadius: 0.02)
        baseGeo.materials = [stoneMat]
        let baseNode = SCNNode(geometry: baseGeo)
        baseNode.position = SCNVector3(0, 0.125, 0)
        parent.addChildNode(baseNode)

        // Hệ cột cái (4 cột cái chính)
        let colCoords: [(Float, Float)] = [(-1.2, -0.9), (1.2, -0.9), (-1.2, 0.9), (1.2, 0.9)]
        for (x, z) in colCoords {
            let cGeo = SCNCylinder(radius: 0.12, height: 2.2)
            cGeo.materials = [woodMat]
            let cNode = SCNNode(geometry: cGeo)
            cNode.position = SCNVector3(x, 1.35, z)
            parent.addChildNode(cNode)
        }

        // Mái nhà rường 4 mái cong đầu đao
        let roofGeo = SCNPyramid(width: 6.4, height: 1.4, length: 5.0)
        roofGeo.materials = [roofMat]
        let roofNode = SCNNode(geometry: roofGeo)
        roofNode.position = SCNVector3(0, 2.50, 0)
        parent.addChildNode(roofNode)
    }

    // MARK: - Thuật Toán Động Học Rã Mộng 4 Pha (4-Phase Kinematic Explode)
    func updateExplodeKinematics() {
        guard selectedModel == .mortiseJoint else { return }

        let p = explodeProgress // 0.0 -> 1.0

        // PHA 1 (0.0 -> 0.25): Rút Chốt Âm Dương theo phương thẳng đứng (+Y)
        if let chot = chotAmDuongNode, let initPos = initialOffsets["ChotAmDuong"] {
            let p1 = min(max(p / 0.25, 0.0), 1.0)
            let liftDistance: Float = 0.50 // Rút lên 50cm
            chot.position = SCNVector3(initPos.x, initPos.y + (p1 * liftDistance), initPos.z)
        }

        // PHA 2 (0.25 -> 0.50): Con Bọ & Xà Hạ dịch chuyển ngang (+Z và +X)
        if let bo = conBoNode, let initPos = initialOffsets["ConBo"] {
            let p2 = min(max((p - 0.25) / 0.25, 0.0), 1.0)
            bo.position = SCNVector3(initPos.x + (p2 * 0.35), initPos.y, initPos.z + (p2 * 0.40))
        }
        if let xa = xaHaNode, let initPos = initialOffsets["XaHa"] {
            let p2 = min(max((p - 0.25) / 0.25, 0.0), 1.0)
            xa.position = SCNVector3(initPos.x, initPos.y, initPos.z + (p2 * 0.55))
        }

        // PHA 3 (0.50 -> 0.75): Trến Ngang nâng lên khỏi mộng sập cột cái (+Y và -X)
        if let tren = trenNgangNode, let initPos = initialOffsets["TrenNgang"] {
            let p3 = min(max((p - 0.50) / 0.25, 0.0), 1.0)
            tren.position = SCNVector3(initPos.x - (p3 * 0.35), initPos.y + (p3 * 0.45), initPos.z)
        }

        // PHA 4 (0.75 -> 1.00): Kèo Suốt trượt tách theo góc xiên mộng đuôi én (+X và +Y)
        if let keo = keoSuotNode, let initPos = initialOffsets["KeoSuot"] {
            let p4 = min(max((p - 0.75) / 0.25, 0.0), 1.0)
            keo.position = SCNVector3(initPos.x + (p4 * 0.65), initPos.y + (p4 * 0.45), initPos.z)
        }
    }

    // MARK: - Chế độ Tự Động Rã/Ghép Mộng (Auto Explode Animation)
    func toggleAutoExplode() {
        isAutoExploding.toggle()
        if isAutoExploding {
            autoTimer?.invalidate()
            autoTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                var next = self.explodeProgress + (0.008 * self.autoDirection)
                if next >= 1.0 {
                    next = 1.0
                    self.autoDirection = -1.0
                } else if next <= 0.0 {
                    next = 0.0
                    self.autoDirection = 1.0
                }
                self.explodeProgress = next
            }
        } else {
            autoTimer?.invalidate()
            autoTimer = nil
        }
    }

    // MARK: - Tương tác Cử chỉ: Xoay Mô Hình
    func rotateModel(by angleDelta: Float) {
        guard let container = modelContainerNode else { return }
        container.eulerAngles.y += angleDelta
    }

    // MARK: - Tương tác Cử chỉ: Thu Phóng Pinch
    func scaleModel(by factor: Float) {
        guard let container = modelContainerNode else { return }
        let currentScale = container.scale.x
        let baseScale = selectedScale.scaleFactor

        let minLimit = baseScale * 0.4
        let maxLimit = baseScale * 2.5
        let newScale = min(max(currentScale * factor, minLimit), maxLimit)

        container.scale = SCNVector3(newScale, newScale, newScale)
    }

    // MARK: - Reset Đặt Lại Mô Hình
    func resetPlacement() {
        rootAnchorNode?.removeFromParentNode()
        rootAnchorNode = nil
        modelContainerNode = nil
        isPlaced = false
        explodeProgress = 0.0
        if isAutoExploding {
            toggleAutoExplode()
        }
        trackingStatusText = "Hướng camera vào mặt sàn hoặc bàn làm việc..."
    }

    // MARK: - Chụp Ảnh AR Kỷ Niệm
    func takeSnapshot() {
        guard let sceneView = sceneView else { return }
        let rawImage = sceneView.snapshot()

        // Thêm Watermark thương hiệu Di sản Huế
        let renderer = UIGraphicsImageRenderer(size: rawImage.size)
        let brandedImage = renderer.image { _ in
            rawImage.draw(at: .zero)

            let text = "🏛️ Phủ Công chúa Ngọc Sơn (1921) — Huế Heritage AR (\(selectedScale.title))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor(red: 0.78, green: 0.61, blue: 0.24, alpha: 1.0)
            ]
            let string = NSAttributedString(string: text, attributes: attrs)
            string.draw(at: CGPoint(x: 36, y: rawImage.size.height - 64))
        }

        self.capturedSnapshot = brandedImage
        UIImageWriteToSavedPhotosAlbum(brandedImage, nil, nil, nil)
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didFailWithError error: Error) {
        trackingStatusText = "Lỗi ARKit: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingStatusText = "Phiên AR tạm gián đoạn..."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        trackingStatusText = "Đang khôi phục lại không gian AR..."
    }
}
