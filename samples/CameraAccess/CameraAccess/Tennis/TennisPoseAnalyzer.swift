import Foundation
import Vision
import UIKit

// MARK: - Pose Metrics (all confidence-tagged)

struct PoseMetrics {
  let movementIntensity: ConfidenceValue
  let kneeBendScore: ConfidenceValue
  let torsoRotationScore: ConfidenceValue
  let spacingScore: ConfidenceValue
  let balanceScore: ConfidenceValue
  let timestamp: Date
  
  static let unknown = PoseMetrics(
    movementIntensity: .unknown,
    kneeBendScore: .unknown,
    torsoRotationScore: .unknown,
    spacingScore: .unknown,
    balanceScore: .unknown,
    timestamp: Date()
  )
  
  var isReliable: Bool {
    let reliableCount = [movementIntensity, kneeBendScore, torsoRotationScore, spacingScore, balanceScore]
      .filter { $0.confidence >= 0.5 }
      .count
    return reliableCount >= 3
  }
}

struct ConfidenceValue: Equatable {
  let value: Double
  let confidence: Double
  
  static let unknown = ConfidenceValue(value: 0, confidence: 0)
  
  var isReliable: Bool { confidence >= 0.5 }
  var isHighConfidence: Bool { confidence >= 0.7 }
}

// MARK: - Opponent Info

struct OpponentInfo {
  let isVisible: Bool
  let depthPosition: DepthPosition
  let lateralBias: LateralBias
  let confidence: Double
  
  enum DepthPosition { case deep, mid, shallow, unknown }
  enum LateralBias { case forehand, center, backhand, unknown }
  
  static let notVisible = OpponentInfo(isVisible: false, depthPosition: .unknown, lateralBias: .unknown, confidence: 0)
}

// MARK: - Tennis Pose Analyzer

@MainActor
class TennisPoseAnalyzer: ObservableObject {
  @Published var lastMetrics: PoseMetrics = .unknown
  @Published var opponentInfo: OpponentInfo = .notVisible
  @Published var frameCount: Int = 0
  @Published var successfulPoseCount: Int = 0
  @Published var lastAnalysisTime: Date?
  
  private let poseRequest = VNDetectHumanBodyPoseRequest()
  private var previousPose: VNHumanBodyPoseObservation?
  private var previousFrameTime: Date?
  private let analysisQueue = DispatchQueue(label: "tennis.pose.analysis", qos: .userInteractive)
  
  // Rolling window for smoothing
  private var metricsWindow: [PoseMetrics] = []
  private let windowSize = 5
  
  // Confidence thresholds (conservative for glasses)
  private let minJointConfidence: Float = 0.3
  private let minOverallConfidence: Double = 0.4
  
  func analyzeFrame(_ image: UIImage) {
    frameCount += 1
    
    guard let cgImage = image.cgImage else {
      NSLog("[TennisPose] Frame %d: No CGImage", frameCount)
      return
    }
    
    analysisQueue.async { [weak self] in
      self?.performAnalysis(cgImage: cgImage)
    }
  }
  
  private func performAnalysis(cgImage: CGImage) {
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    
    do {
      try handler.perform([poseRequest])
      
      guard let observations = poseRequest.results, !observations.isEmpty else {
        Task { @MainActor in
          self.lastMetrics = .unknown
          self.opponentInfo = .notVisible
          NSLog("[TennisPose] Frame %d: No pose detected", self.frameCount)
        }
        return
      }
      
      // Primary person (player) is typically the largest/most confident
      let sortedByConfidence = observations.sorted { $0.confidence > $1.confidence }
      guard let playerPose = sortedByConfidence.first else { return }
      
      // Check if we have a second person (opponent)
      let opponentPose = sortedByConfidence.count > 1 ? sortedByConfidence[1] : nil
      
      let metrics = computeMetrics(from: playerPose)
      let opponent = opponentPose.map { computeOpponentInfo(from: $0) } ?? .notVisible
      
      Task { @MainActor in
        self.successfulPoseCount += 1
        self.lastMetrics = metrics
        self.opponentInfo = opponent
        self.lastAnalysisTime = Date()
        self.previousPose = playerPose
        self.previousFrameTime = Date()
        
        // Add to rolling window
        self.metricsWindow.append(metrics)
        if self.metricsWindow.count > self.windowSize {
          self.metricsWindow.removeFirst()
        }
        
        NSLog("[TennisPose] Frame %d: Pose OK (knee=%.2f@%.2f, rotation=%.2f@%.2f)",
              self.frameCount,
              metrics.kneeBendScore.value, metrics.kneeBendScore.confidence,
              metrics.torsoRotationScore.value, metrics.torsoRotationScore.confidence)
      }
      
    } catch {
      Task { @MainActor in
        self.lastMetrics = .unknown
        NSLog("[TennisPose] Frame %d: Analysis error: %@", self.frameCount, error.localizedDescription)
      }
    }
  }
  
  // MARK: - Metric Computation
  
  private func computeMetrics(from pose: VNHumanBodyPoseObservation) -> PoseMetrics {
    let timestamp = Date()
    
    // Get key joint points with confidence
    let joints = extractJoints(from: pose)
    
    // 1. Knee Bend Score (athletic stance indicator)
    let kneeBend = computeKneeBend(joints: joints)
    
    // 2. Torso Rotation Score (unit turn proxy)
    let rotation = computeTorsoRotation(joints: joints)
    
    // 3. Spacing Score (arm distance from torso)
    let spacing = computeSpacing(joints: joints)
    
    // 4. Balance Score (center of mass stability)
    let balance = computeBalance(joints: joints)
    
    // 5. Movement Intensity (requires previous frame)
    let movement = computeMovementIntensity(joints: joints)
    
    return PoseMetrics(
      movementIntensity: movement,
      kneeBendScore: kneeBend,
      torsoRotationScore: rotation,
      spacingScore: spacing,
      balanceScore: balance,
      timestamp: timestamp
    )
  }
  
  private func extractJoints(from pose: VNHumanBodyPoseObservation) -> [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)] {
    var joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)] = [:]
    
    let relevantJoints: [VNHumanBodyPoseObservation.JointName] = [
      .nose, .neck,
      .leftShoulder, .rightShoulder,
      .leftElbow, .rightElbow,
      .leftWrist, .rightWrist,
      .leftHip, .rightHip,
      .leftKnee, .rightKnee,
      .leftAnkle, .rightAnkle,
      .root
    ]
    
    for jointName in relevantJoints {
      if let point = try? pose.recognizedPoint(jointName), point.confidence >= minJointConfidence {
        joints[jointName] = (CGPoint(x: point.x, y: point.y), point.confidence)
      }
    }
    
    return joints
  }
  
  private func computeKneeBend(joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)]) -> ConfidenceValue {
    // Knee bend = angle at knee joint. Lower angle = more bend = more athletic
    guard let leftHip = joints[.leftHip],
          let leftKnee = joints[.leftKnee],
          let leftAnkle = joints[.leftAnkle],
          let rightHip = joints[.rightHip],
          let rightKnee = joints[.rightKnee],
          let rightAnkle = joints[.rightAnkle] else {
      return .unknown
    }
    
    let leftAngle = angle(p1: leftHip.point, vertex: leftKnee.point, p2: leftAnkle.point)
    let rightAngle = angle(p1: rightHip.point, vertex: rightKnee.point, p2: rightAnkle.point)
    
    // Average knee bend (180 = straight, 90 = deep squat)
    let avgAngle = (leftAngle + rightAngle) / 2
    
    // Normalize: 180° = 0 (no bend), 90° = 1 (max useful bend)
    let normalizedBend = max(0, min(1, (180 - avgAngle) / 90))
    
    let confidence = Double(min(leftHip.confidence, leftKnee.confidence, leftAnkle.confidence,
                                 rightHip.confidence, rightKnee.confidence, rightAnkle.confidence))
    
    return ConfidenceValue(value: normalizedBend, confidence: confidence)
  }
  
  private func computeTorsoRotation(joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)]) -> ConfidenceValue {
    // Torso rotation = shoulder line vs hip line angle difference
    guard let leftShoulder = joints[.leftShoulder],
          let rightShoulder = joints[.rightShoulder],
          let leftHip = joints[.leftHip],
          let rightHip = joints[.rightHip] else {
      return .unknown
    }
    
    let shoulderAngle = atan2(rightShoulder.point.y - leftShoulder.point.y,
                              rightShoulder.point.x - leftShoulder.point.x)
    let hipAngle = atan2(rightHip.point.y - leftHip.point.y,
                         rightHip.point.x - leftHip.point.x)
    
    var rotationDiff = abs(shoulderAngle - hipAngle)
    if rotationDiff > .pi { rotationDiff = 2 * .pi - rotationDiff }
    
    // Normalize: 0 = no rotation, π/4 (45°) = good rotation
    let normalizedRotation = min(1, rotationDiff / (.pi / 4))
    
    let confidence = Double(min(leftShoulder.confidence, rightShoulder.confidence,
                                 leftHip.confidence, rightHip.confidence))
    
    return ConfidenceValue(value: normalizedRotation, confidence: confidence)
  }
  
  private func computeSpacing(joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)]) -> ConfidenceValue {
    // Spacing = how far hands are from body center (preparation indicator)
    guard let root = joints[.root],
          let leftWrist = joints[.leftWrist],
          let rightWrist = joints[.rightWrist] else {
      return .unknown
    }
    
    let leftDist = distance(root.point, leftWrist.point)
    let rightDist = distance(root.point, rightWrist.point)
    let avgDist = (leftDist + rightDist) / 2
    
    // Normalize by approximate body scale (shoulder width)
    let bodyScale: CGFloat
    if let ls = joints[.leftShoulder], let rs = joints[.rightShoulder] {
      bodyScale = distance(ls.point, rs.point)
    } else {
      bodyScale = 0.15 // fallback
    }
    
    let normalizedSpacing = min(1, avgDist / (bodyScale * 2))
    let confidence = Double(min(root.confidence, leftWrist.confidence, rightWrist.confidence))
    
    return ConfidenceValue(value: normalizedSpacing, confidence: confidence)
  }
  
  private func computeBalance(joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)]) -> ConfidenceValue {
    // Balance = how centered is the upper body over the feet
    guard let root = joints[.root],
          let leftAnkle = joints[.leftAnkle],
          let rightAnkle = joints[.rightAnkle] else {
      return .unknown
    }
    
    let feetCenter = CGPoint(
      x: (leftAnkle.point.x + rightAnkle.point.x) / 2,
      y: (leftAnkle.point.y + rightAnkle.point.y) / 2
    )
    
    let horizontalOffset = abs(root.point.x - feetCenter.x)
    let feetWidth = abs(leftAnkle.point.x - rightAnkle.point.x)
    
    // Good balance = root directly above feet center
    let balanceScore = max(0, 1 - (horizontalOffset / max(feetWidth, 0.05)))
    let confidence = Double(min(root.confidence, leftAnkle.confidence, rightAnkle.confidence))
    
    return ConfidenceValue(value: balanceScore, confidence: confidence)
  }
  
  private func computeMovementIntensity(joints: [VNHumanBodyPoseObservation.JointName: (point: CGPoint, confidence: Float)]) -> ConfidenceValue {
    guard let previousPose = previousPose,
          let previousTime = previousFrameTime else {
      return ConfidenceValue(value: 0, confidence: 0.3) // No previous frame
    }
    
    let timeDelta = Date().timeIntervalSince(previousTime)
    guard timeDelta > 0 && timeDelta < 2.0 else {
      return ConfidenceValue(value: 0, confidence: 0.3)
    }
    
    // Compare root position movement
    guard let currentRoot = joints[.root],
          let prevRoot = try? previousPose.recognizedPoint(.root),
          prevRoot.confidence >= minJointConfidence else {
      return ConfidenceValue(value: 0, confidence: 0.3)
    }
    
    let movement = distance(currentRoot.point, CGPoint(x: prevRoot.x, y: prevRoot.y))
    let velocity = movement / timeDelta
    
    // Normalize: 0 = stationary, 1 = high movement (0.5 units/sec)
    let normalizedIntensity = min(1, velocity / 0.5)
    
    return ConfidenceValue(value: normalizedIntensity, confidence: Double(min(currentRoot.confidence, prevRoot.confidence)))
  }
  
  // MARK: - Opponent Analysis
  
  private func computeOpponentInfo(from pose: VNHumanBodyPoseObservation) -> OpponentInfo {
    guard pose.confidence >= Float(minOverallConfidence) else {
      return .notVisible
    }
    
    guard let root = try? pose.recognizedPoint(.root),
          root.confidence >= minJointConfidence else {
      return .notVisible
    }
    
    // Depth: lower Y = further away (in normalized coords, 0 = bottom, 1 = top)
    let depthPosition: OpponentInfo.DepthPosition
    if root.y < 0.3 {
      depthPosition = .deep
    } else if root.y < 0.5 {
      depthPosition = .mid
    } else {
      depthPosition = .shallow
    }
    
    // Lateral: X position (0 = left, 1 = right)
    // Assuming player is at center, opponent position relative
    let lateralBias: OpponentInfo.LateralBias
    if root.x < 0.35 {
      lateralBias = .backhand // opponent on player's backhand side
    } else if root.x > 0.65 {
      lateralBias = .forehand
    } else {
      lateralBias = .center
    }
    
    return OpponentInfo(
      isVisible: true,
      depthPosition: depthPosition,
      lateralBias: lateralBias,
      confidence: Double(pose.confidence)
    )
  }
  
  // MARK: - Smoothed Metrics
  
  func getSmoothedMetrics() -> PoseMetrics? {
    guard metricsWindow.count >= 3 else { return nil }
    
    let reliableMetrics = metricsWindow.filter { $0.isReliable }
    guard reliableMetrics.count >= 2 else { return nil }
    
    // Average the reliable metrics
    let avgKnee = average(reliableMetrics.map { $0.kneeBendScore })
    let avgRotation = average(reliableMetrics.map { $0.torsoRotationScore })
    let avgSpacing = average(reliableMetrics.map { $0.spacingScore })
    let avgBalance = average(reliableMetrics.map { $0.balanceScore })
    let avgMovement = average(reliableMetrics.map { $0.movementIntensity })
    
    return PoseMetrics(
      movementIntensity: avgMovement,
      kneeBendScore: avgKnee,
      torsoRotationScore: avgRotation,
      spacingScore: avgSpacing,
      balanceScore: avgBalance,
      timestamp: Date()
    )
  }
  
  private func average(_ values: [ConfidenceValue]) -> ConfidenceValue {
    let reliable = values.filter { $0.confidence > 0.3 }
    guard !reliable.isEmpty else { return .unknown }
    
    let avgValue = reliable.map { $0.value }.reduce(0, +) / Double(reliable.count)
    let avgConf = reliable.map { $0.confidence }.reduce(0, +) / Double(reliable.count)
    
    return ConfidenceValue(value: avgValue, confidence: avgConf)
  }
  
  // MARK: - Geometry Helpers
  
  private func angle(p1: CGPoint, vertex: CGPoint, p2: CGPoint) -> Double {
    let v1 = CGPoint(x: p1.x - vertex.x, y: p1.y - vertex.y)
    let v2 = CGPoint(x: p2.x - vertex.x, y: p2.y - vertex.y)
    
    let dot = v1.x * v2.x + v1.y * v2.y
    let cross = v1.x * v2.y - v1.y * v2.x
    
    return abs(atan2(cross, dot)) * 180 / .pi
  }
  
  private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
    let dx = p1.x - p2.x
    let dy = p1.y - p2.y
    return sqrt(dx * dx + dy * dy)
  }
  
  // MARK: - Stats
  
  var poseSuccessRate: Double {
    guard frameCount > 0 else { return 0 }
    return Double(successfulPoseCount) / Double(frameCount)
  }
  
  func reset() {
    frameCount = 0
    successfulPoseCount = 0
    lastMetrics = .unknown
    opponentInfo = .notVisible
    metricsWindow.removeAll()
    previousPose = nil
    previousFrameTime = nil
  }
}
