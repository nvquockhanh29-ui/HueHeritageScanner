//
//  ARHeritageView.swift
//  HueHeritageAR
//
//  Dự án: Bảo tồn Di tích Cố đô Huế — Phủ Công chúa Ngọc Sơn (1921)
//  UIViewRepresentable đóng gói ARSCNView và bộ nhận diện cử chỉ cảm ứng:
//    - Tap: Đặt mô hình tại tâm ngắm
//    - Pan: Xoay mô hình quanh trục đứng Y
//    - Pinch: Thu phóng kích thước
//    - Rotation: Xoay hai ngón tay
//

import SwiftUI
import ARKit
import SceneKit

struct ARHeritageView: UIViewRepresentable {
    @EnvironmentObject var arManager: ARHeritageManager

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arManager.setupSceneView(arView)

        // Gắn Gestures
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        arView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        arView.addGestureRecognizer(pinchGesture)

        let rotateGesture = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
        arView.addGestureRecognizer(rotateGesture)

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // Cập nhật trạng thái hiển thị nếu cần
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(arManager: arManager)
    }

    class Coordinator: NSObject {
        var arManager: ARHeritageManager
        private var lastPanX: Float = 0.0

        init(arManager: ARHeritageManager) {
            self.arManager = arManager
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard !arManager.isPlaced else { return }
            arManager.placeModelAtReticle()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard arManager.isPlaced else { return }
            let translationX = Float(gesture.translation(in: gesture.view).x)

            switch gesture.state {
            case .began:
                lastPanX = translationX
            case .changed:
                let deltaX = translationX - lastPanX
                lastPanX = translationX
                // Xoay quanh trục Y (độ nhạy 0.008 rad/px)
                arManager.rotateModel(by: deltaX * 0.008)
            default:
                break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard arManager.isPlaced else { return }
            if gesture.state == .changed {
                let factor = Float(gesture.scale)
                arManager.scaleModel(by: factor)
                gesture.scale = 1.0 // Reset scale delta
            }
        }

        @objc func handleRotate(_ gesture: UIRotationGestureRecognizer) {
            guard arManager.isPlaced else { return }
            if gesture.state == .changed {
                arManager.rotateModel(by: Float(-gesture.rotation))
                gesture.rotation = 0.0
            }
        }
    }
}
