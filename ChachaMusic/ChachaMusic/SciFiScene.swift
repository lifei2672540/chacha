import SwiftUI
import SceneKit

struct SciFiView: UIViewRepresentable {
  var level: Double

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.scene = makeScene()
    view.backgroundColor = .black
    view.allowsCameraControl = false
    view.autoenablesDefaultLighting = false
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {
    guard let scene = view.scene else { return }
    if let orb = scene.rootNode.childNode(withName: "orb", recursively: true) {
      let s = Float(1.0 + level * 0.55)
      orb.scale = SCNVector3(s, s, s)
      orb.geometry?.firstMaterial?.emission.intensity = 0.6 + level * 2.2
    }
    if let glow = scene.rootNode.childNode(withName: "glow", recursively: true) {
      let gs = Float(1.0 + level * 0.9)
      glow.scale = SCNVector3(gs, gs, gs)
    }
  }

  private func makeScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1.0)

    let camNode = SCNNode()
    camNode.camera = SCNCamera()
    camNode.position = SCNVector3(0, 0, 9)
    scene.rootNode.addChildNode(camNode)

    let ambient = SCNNode()
    ambient.light = SCNLight()
    ambient.light?.type = .ambient
    ambient.light?.color = UIColor(white: 0.35, alpha: 1.0)
    scene.rootNode.addChildNode(ambient)

    let point = SCNNode()
    point.light = SCNLight()
    point.light?.type = .omni
    point.light?.color = UIColor.cyan
    point.position = SCNVector3(4, 4, 6)
    scene.rootNode.addChildNode(point)

    for _ in 0..<220 {
      let starGeo = SCNSphere(radius: CGFloat.random(in: 0.008...0.03))
      let m = SCNMaterial()
      let c = Bool.random() ? UIColor.cyan : UIColor.white
      m.diffuse.contents = c
      m.emission.contents = c
      m.emission.intensity = 0.9
      starGeo.firstMaterial = m
      let node = SCNNode(geometry: starGeo)
      let r = CGFloat.random(in: 6...14)
      let theta = CGFloat.random(in: 0...(2 * .pi))
      let phi = CGFloat.random(in: 0...(.pi))
      node.position = SCNVector3(
        Float(r * sin(phi) * cos(theta)),
        Float(r * cos(phi)),
        Float(r * sin(phi) * sin(theta) - 4)
      )
      scene.rootNode.addChildNode(node)
    }

    let glowGeo = SCNSphere(radius: 1.55)
    let glowMat = SCNMaterial()
    glowMat.diffuse.contents = UIColor.clear
    glowMat.emission.contents = UIColor.cyan
    glowMat.emission.intensity = 0.35
    glowMat.transparency = 0.35
    glowGeo.firstMaterial = glowMat
    let glow = SCNNode(geometry: glowGeo)
    glow.name = "glow"
    scene.rootNode.addChildNode(glow)

    let orbGeo = SCNSphere(radius: 1.0)
    orbGeo.segmentCount = 12
    let orbMat = SCNMaterial()
    orbMat.diffuse.contents = UIColor(red: 0.05, green: 0.15, blue: 0.25, alpha: 1.0)
    orbMat.emission.contents = UIColor.cyan
    orbMat.emission.intensity = 0.8
    orbMat.specular.contents = UIColor.white
    orbMat.shininess = 0.9
    orbGeo.firstMaterial = orbMat
    let orb = SCNNode(geometry: orbGeo)
    orb.name = "orb"
    scene.rootNode.addChildNode(orb)

    let rings: [(CGFloat, CGFloat)] = [(1.9, 0.6), (2.5, -0.4)]
    for (radius, tilt) in rings {
      let ringGeo = SCNTorus(ringRadius: radius, pipeRadius: 0.02)
      let rm = SCNMaterial()
      rm.diffuse.contents = UIColor.magenta
      rm.emission.contents = UIColor.magenta
      rm.emission.intensity = 1.2
      ringGeo.firstMaterial = rm
      let rn = SCNNode(geometry: ringGeo)
      rn.eulerAngles = SCNVector3(0, Float(tilt), 0.4)
      rn.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: 14)))
      scene.rootNode.addChildNode(rn)
    }
    return scene
  }
}
