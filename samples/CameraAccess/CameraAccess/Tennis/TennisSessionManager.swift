import Foundation
import Combine

// MARK: - Session State

enum TennisSessionState: String, CaseIterable {
  case idle = "Idle"
  case warmup = "Warm-up"
  case rally = "Rally"
  case serveBlock = "Serve Practice"
  case cooldown = "Cool-down"
  case reviewReady = "Review Ready"
}

enum TennisFocus: String, CaseIterable {
  case movement = "Movement"
  case forehand = "Forehand"
  case backhand = "Backhand"
  case serve = "Serve"
  case general = "General"
}

// MARK: - Session Issue

struct SessionIssue: Identifiable {
  let id = UUID()
  let type: IssueType
  let severity: Severity
  let occurrences: Int
  let averageConfidence: Double
  let timestamp: Date
  
  enum IssueType: String, CaseIterable {
    case insufficientKneeBend = "Knee Bend"
    case latePreparation = "Late Preparation"
    case poorBalance = "Balance"
    case tightSpacing = "Spacing"
    case slowRecovery = "Recovery"
    case limitedRotation = "Rotation"
  }
  
  enum Severity: Int, Comparable {
    case low = 1
    case medium = 2
    case high = 3
    
    static func < (lhs: Severity, rhs: Severity) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }
  
  var displayName: String { type.rawValue }
}

// MARK: - Tennis Session Manager

@MainActor
class TennisSessionManager: ObservableObject {
  @Published var isActive: Bool = false
  @Published var state: TennisSessionState = .idle
  @Published var focus: TennisFocus = .general
  @Published var isMuted: Bool = false
  @Published var sessionDuration: TimeInterval = 0
  @Published var lastCueTime: Date?
  @Published var cueCount: Int = 0
  
  // Issue tracking
  @Published var detectedIssues: [SessionIssue] = []
  @Published var opponentNotes: [String] = []
  
  // Rolling metric windows (sparse input design)
  private var metricsHistory: [PoseMetrics] = []
  private let maxHistorySize = 100
  private var sessionStartTime: Date?
  private var sessionTimer: Timer?
  private var issueCounters: [SessionIssue.IssueType: Int] = [:]
  private var issueConfidences: [SessionIssue.IssueType: [Double]] = [:]
  
  // Thresholds (conservative for glasses)
  private let minWindowsForIssue = 3
  private let issueThreshold = 0.4 // Below this = issue
  private let confidenceThreshold = 0.5
  
  // Cue timing
  private let minCueInterval: TimeInterval = 20.0 // Max 1 cue per 20 seconds
  
  private let poseAnalyzer: TennisPoseAnalyzer
  private let coachingPolicy: CoachingPolicy
  
  init(poseAnalyzer: TennisPoseAnalyzer) {
    self.poseAnalyzer = poseAnalyzer
    self.coachingPolicy = CoachingPolicy()
  }
  
  // MARK: - Session Control
  
  func startSession(focus: TennisFocus = .general) {
    guard !isActive else { return }
    
    self.focus = focus
    self.isActive = true
    self.state = .warmup
    self.sessionStartTime = Date()
    self.sessionDuration = 0
    self.cueCount = 0
    self.lastCueTime = nil
    self.detectedIssues.removeAll()
    self.opponentNotes.removeAll()
    self.metricsHistory.removeAll()
    self.issueCounters.removeAll()
    self.issueConfidences.removeAll()
    
    poseAnalyzer.reset()
    
    // Start session timer
    sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let start = self.sessionStartTime else { return }
        self.sessionDuration = Date().timeIntervalSince(start)
        self.updateSessionState()
      }
    }
    
    NSLog("[TennisSession] Started with focus: %@", focus.rawValue)
  }
  
  func endSession() {
    guard isActive else { return }
    
    sessionTimer?.invalidate()
    sessionTimer = nil
    
    // Finalize issues
    finalizeIssues()
    
    state = .reviewReady
    isActive = false
    
    NSLog("[TennisSession] Ended. Duration: %.0fs, Cues: %d, Issues: %d",
          sessionDuration, cueCount, detectedIssues.count)
  }
  
  func mute() {
    isMuted = true
    NSLog("[TennisSession] Muted")
  }
  
  func unmute() {
    isMuted = false
    NSLog("[TennisSession] Unmuted")
  }
  
  func setFocus(_ newFocus: TennisFocus) {
    focus = newFocus
    NSLog("[TennisSession] Focus changed to: %@", newFocus.rawValue)
  }
  
  // MARK: - Metrics Processing
  
  func processMetrics(_ metrics: PoseMetrics) {
    guard isActive, state != .idle, state != .reviewReady else { return }
    
    // Add to history
    metricsHistory.append(metrics)
    if metricsHistory.count > maxHistorySize {
      metricsHistory.removeFirst()
    }
    
    // Skip unreliable metrics
    guard metrics.isReliable else { return }
    
    // Track issues
    trackIssues(from: metrics)
    
    // Auto-detect state transitions
    detectStateTransition(from: metrics)
  }
  
  func processOpponentInfo(_ info: OpponentInfo) {
    guard isActive, info.isVisible, info.confidence >= confidenceThreshold else { return }
    
    // Generate tactical notes (max 3)
    guard opponentNotes.count < 3 else { return }
    
    let note: String?
    switch (info.depthPosition, info.lateralBias) {
    case (.deep, _):
      note = "Opponent staying deep—use depth to push them back."
    case (.shallow, .forehand):
      note = "Opponent cheating to forehand—open court on backhand."
    case (.shallow, .backhand):
      note = "Opponent favoring backhand side—attack forehand."
    case (.shallow, .center):
      note = "Opponent at net—consider lobs or passing shots."
    default:
      note = nil
    }
    
    if let note, !opponentNotes.contains(note) {
      opponentNotes.append(note)
      NSLog("[TennisSession] Opponent note: %@", note)
    }
  }
  
  // MARK: - Issue Tracking
  
  private func trackIssues(from metrics: PoseMetrics) {
    // Check each metric against thresholds
    checkIssue(.insufficientKneeBend, value: metrics.kneeBendScore)
    checkIssue(.limitedRotation, value: metrics.torsoRotationScore)
    checkIssue(.tightSpacing, value: metrics.spacingScore)
    checkIssue(.poorBalance, value: metrics.balanceScore)
    
    // Late preparation = low spacing when movement detected
    if metrics.movementIntensity.isReliable && metrics.movementIntensity.value > 0.3 {
      if metrics.spacingScore.isReliable && metrics.spacingScore.value < issueThreshold {
        incrementIssue(.latePreparation, confidence: metrics.spacingScore.confidence)
      }
    }
    
    // Slow recovery = low movement after high movement
    if let prev = metricsHistory.dropLast().last,
       prev.movementIntensity.value > 0.5,
       metrics.movementIntensity.value < 0.2 {
      // Not necessarily bad—could be between points
    }
  }
  
  private func checkIssue(_ type: SessionIssue.IssueType, value: ConfidenceValue) {
    guard value.isReliable else { return }
    
    if value.value < issueThreshold {
      incrementIssue(type, confidence: value.confidence)
    }
  }
  
  private func incrementIssue(_ type: SessionIssue.IssueType, confidence: Double) {
    issueCounters[type, default: 0] += 1
    issueConfidences[type, default: []].append(confidence)
    
    // Keep confidence history bounded
    if issueConfidences[type]!.count > 20 {
      issueConfidences[type]!.removeFirst()
    }
  }
  
  private func finalizeIssues() {
    detectedIssues.removeAll()
    
    for (type, count) in issueCounters where count >= minWindowsForIssue {
      let confidences = issueConfidences[type] ?? []
      let avgConfidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
      
      let severity: SessionIssue.Severity
      if count >= 10 {
        severity = .high
      } else if count >= 5 {
        severity = .medium
      } else {
        severity = .low
      }
      
      let issue = SessionIssue(
        type: type,
        severity: severity,
        occurrences: count,
        averageConfidence: avgConfidence,
        timestamp: Date()
      )
      detectedIssues.append(issue)
    }
    
    // Sort by severity
    detectedIssues.sort { $0.severity > $1.severity }
    
    // Keep top 3
    if detectedIssues.count > 3 {
      detectedIssues = Array(detectedIssues.prefix(3))
    }
  }
  
  // MARK: - State Management
  
  private func updateSessionState() {
    // Auto-transition based on duration and activity
    guard state != .reviewReady else { return }
    
    if sessionDuration < 60 {
      state = .warmup
    } else if sessionDuration > 1800 { // 30 minutes
      state = .cooldown
    } else {
      // Detect serve practice vs rally based on movement patterns
      if focus == .serve {
        state = .serveBlock
      } else {
        state = .rally
      }
    }
  }
  
  private func detectStateTransition(from metrics: PoseMetrics) {
    // Could detect serve vs rally based on movement patterns
    // For now, rely on manual focus setting
  }
  
  // MARK: - Cue Generation
  
  func shouldGenerateCue() -> Bool {
    guard isActive, !isMuted else { return false }
    
    // Check timing
    if let lastCue = lastCueTime {
      guard Date().timeIntervalSince(lastCue) >= minCueInterval else { return false }
    }
    
    return true
  }
  
  func getNextCue() -> String? {
    guard shouldGenerateCue() else { return nil }
    
    // Get smoothed metrics
    guard let metrics = poseAnalyzer.getSmoothedMetrics() else { return nil }
    
    // Use coaching policy to determine cue
    let cue = coachingPolicy.generateCue(
      metrics: metrics,
      focus: focus,
      issueCounters: issueCounters,
      minOccurrences: minWindowsForIssue
    )
    
    if let cue = cue {
      lastCueTime = Date()
      cueCount += 1
      NSLog("[TennisSession] Cue #%d: %@", cueCount, cue)
    }
    
    return cue
  }
  
  func recordCueDelivered() {
    lastCueTime = Date()
    cueCount += 1
  }
  
  // MARK: - Review Generation
  
  func generateReview() -> TennisSessionReview {
    return TennisSessionReview(
      duration: sessionDuration,
      focus: focus,
      issues: detectedIssues,
      opponentNotes: opponentNotes,
      cueCount: cueCount,
      poseSuccessRate: poseAnalyzer.poseSuccessRate,
      totalFrames: poseAnalyzer.frameCount
    )
  }
}

// MARK: - Session Review

struct TennisSessionReview {
  let duration: TimeInterval
  let focus: TennisFocus
  let issues: [SessionIssue]
  let opponentNotes: [String]
  let cueCount: Int
  let poseSuccessRate: Double
  let totalFrames: Int
  
  var durationFormatted: String {
    let minutes = Int(duration) / 60
    let seconds = Int(duration) % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
  
  var summaryText: String {
    var lines: [String] = []
    lines.append("## Tennis Session Review")
    lines.append("Duration: \(durationFormatted) | Focus: \(focus.rawValue)")
    lines.append("")
    
    if issues.isEmpty {
      lines.append("### Observations")
      lines.append("Not enough reliable data to identify specific issues.")
      lines.append("(Pose detection rate: \(Int(poseSuccessRate * 100))%)")
    } else {
      lines.append("### Issues Observed")
      for (i, issue) in issues.enumerated() {
        let conf = Int(issue.averageConfidence * 100)
        lines.append("\(i + 1). **\(issue.displayName)** — \(issue.severity) priority (\(conf)% confidence)")
      }
    }
    
    lines.append("")
    lines.append("### Suggested Drills")
    lines.append(generateDrills())
    
    if !opponentNotes.isEmpty {
      lines.append("")
      lines.append("### Tactical Notes")
      for note in opponentNotes {
        lines.append("- \(note)")
      }
    }
    
    return lines.joined(separator: "\n")
  }
  
  var spokenSummary: String {
    var parts: [String] = []
    
    parts.append("Session complete. \(durationFormatted) of \(focus.rawValue.lowercased()) practice.")
    
    if issues.isEmpty {
      parts.append("I didn't get enough clear visuals to identify specific issues.")
    } else {
      let topIssue = issues.first!
      parts.append("Main focus area: \(topIssue.displayName.lowercased()).")
      
      if issues.count > 1 {
        parts.append("Also work on \(issues[1].displayName.lowercased()).")
      }
    }
    
    if let note = opponentNotes.first {
      parts.append("Tactical note: \(note)")
    }
    
    return parts.joined(separator: " ")
  }
  
  private func generateDrills() -> String {
    // Generate drills based on issues (no equipment assumptions)
    var drills: [String] = []
    
    for issue in issues.prefix(3) {
      switch issue.type {
      case .insufficientKneeBend:
        drills.append("1. **Shadow swings with squat hold** — pause in ready position, check knee angle")
      case .latePreparation:
        drills.append("2. **Split-step timing drill** — focus on racket back before ball bounces")
      case .poorBalance:
        drills.append("3. **Single-leg balance holds** — 30 seconds each side between points")
      case .tightSpacing:
        drills.append("4. **Extend and reach drill** — shadow swing reaching away from body")
      case .slowRecovery:
        drills.append("5. **Recovery footwork** — side shuffle back to center after each swing")
      case .limitedRotation:
        drills.append("6. **Rotation drill** — face sidewall, turn shoulders past hips")
      }
    }
    
    if drills.isEmpty {
      drills.append("1. **General footwork** — ladder drills or cone touches")
      drills.append("2. **Shadow swings** — full motion without ball, focus on form")
      drills.append("3. **Ready position holds** — practice athletic stance")
    }
    
    return drills.joined(separator: "\n")
  }
}
