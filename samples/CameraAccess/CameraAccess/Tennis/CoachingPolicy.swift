import Foundation

// MARK: - Coaching Policy
// STRICT RULES:
// - Max 1 sentence
// - No more than once every 20 seconds
// - Speak ONLY if same issue detected ≥3 windows AND confidence ≥ threshold
// - If confidence < threshold: stay silent OR say "I'm not sure yet"

class CoachingPolicy {
  
  // Confidence threshold for speaking
  private let speakingConfidenceThreshold = 0.5
  
  // Minimum issue occurrences before cueing
  private let minOccurrencesForCue = 3
  
  // Track last cue type to avoid repetition
  private var lastCueType: CueType?
  private var cueTypeHistory: [CueType] = []
  private let maxHistorySize = 5
  
  // MARK: - Cue Types (priority order)
  
  enum CueType: Int, CaseIterable {
    case footworkSpacing = 1    // Priority 1
    case earlyPreparation = 2   // Priority 2
    case balanceRecovery = 3    // Priority 3
    case tacticalPosition = 4   // Priority 4
    case unsure = 99
    
    var priority: Int { rawValue }
  }
  
  // MARK: - Cue Generation
  
  func generateCue(
    metrics: PoseMetrics,
    focus: TennisFocus,
    issueCounters: [SessionIssue.IssueType: Int],
    minOccurrences: Int
  ) -> String? {
    
    // Build candidate cues with confidence
    var candidates: [(cue: String, type: CueType, confidence: Double)] = []
    
    // Priority 1: Footwork / Spacing
    if let cue = checkSpacingCue(metrics: metrics, issueCounters: issueCounters, minOccurrences: minOccurrences) {
      candidates.append(cue)
    }
    
    // Priority 2: Early Preparation
    if let cue = checkPreparationCue(metrics: metrics, issueCounters: issueCounters, minOccurrences: minOccurrences) {
      candidates.append(cue)
    }
    
    // Priority 3: Balance / Recovery
    if let cue = checkBalanceCue(metrics: metrics, issueCounters: issueCounters, minOccurrences: minOccurrences) {
      candidates.append(cue)
    }
    
    // Sort by priority
    candidates.sort { $0.type.priority < $1.type.priority }
    
    // Select best candidate
    for candidate in candidates {
      // Check confidence
      if candidate.confidence < speakingConfidenceThreshold {
        continue
      }
      
      // Avoid repeating the same cue type twice in a row
      if candidate.type == lastCueType && cueTypeHistory.count >= 2 {
        continue
      }
      
      // Record and return
      recordCue(type: candidate.type)
      return candidate.cue
    }
    
    // Low confidence fallback (only if we have SOME data)
    if !candidates.isEmpty && candidates.allSatisfy({ $0.confidence < speakingConfidenceThreshold }) {
      // Only occasionally say "not sure"
      if cueTypeHistory.last != .unsure {
        recordCue(type: .unsure)
        return nil // Stay silent rather than "not sure" (better UX)
      }
    }
    
    return nil
  }
  
  // MARK: - Specific Cue Checks
  
  private func checkSpacingCue(
    metrics: PoseMetrics,
    issueCounters: [SessionIssue.IssueType: Int],
    minOccurrences: Int
  ) -> (cue: String, type: CueType, confidence: Double)? {
    
    // Check spacing score
    guard metrics.spacingScore.isReliable else { return nil }
    
    let spacingIssues = issueCounters[.tightSpacing, default: 0]
    
    if metrics.spacingScore.value < 0.4 && spacingIssues >= minOccurrences {
      let cue = selectSpacingCue()
      return (cue, .footworkSpacing, metrics.spacingScore.confidence)
    }
    
    return nil
  }
  
  private func checkPreparationCue(
    metrics: PoseMetrics,
    issueCounters: [SessionIssue.IssueType: Int],
    minOccurrences: Int
  ) -> (cue: String, type: CueType, confidence: Double)? {
    
    // Check rotation (proxy for preparation)
    guard metrics.torsoRotationScore.isReliable else { return nil }
    
    let rotationIssues = issueCounters[.limitedRotation, default: 0]
    let prepIssues = issueCounters[.latePreparation, default: 0]
    
    if (metrics.torsoRotationScore.value < 0.3 && rotationIssues >= minOccurrences) ||
       prepIssues >= minOccurrences {
      let cue = selectPreparationCue()
      return (cue, .earlyPreparation, metrics.torsoRotationScore.confidence)
    }
    
    return nil
  }
  
  private func checkBalanceCue(
    metrics: PoseMetrics,
    issueCounters: [SessionIssue.IssueType: Int],
    minOccurrences: Int
  ) -> (cue: String, type: CueType, confidence: Double)? {
    
    // Check balance and knee bend
    let balanceOK = metrics.balanceScore.isReliable
    let kneeOK = metrics.kneeBendScore.isReliable
    
    guard balanceOK || kneeOK else { return nil }
    
    let balanceIssues = issueCounters[.poorBalance, default: 0]
    let kneeIssues = issueCounters[.insufficientKneeBend, default: 0]
    
    // Knee bend issue
    if kneeOK && metrics.kneeBendScore.value < 0.3 && kneeIssues >= minOccurrences {
      let cue = selectKneeBendCue()
      return (cue, .balanceRecovery, metrics.kneeBendScore.confidence)
    }
    
    // Balance issue
    if balanceOK && metrics.balanceScore.value < 0.4 && balanceIssues >= minOccurrences {
      let cue = selectBalanceCue()
      return (cue, .balanceRecovery, metrics.balanceScore.confidence)
    }
    
    return nil
  }
  
  // MARK: - Cue Text Selection
  // All cues are max 1 sentence, actionable, no racket-specific mechanics
  
  private func selectSpacingCue() -> String {
    let cues = [
      "Give yourself more space from the ball.",
      "Step back to create room.",
      "You're a bit close—widen your stance.",
      "Make space before contact."
    ]
    return cues.randomElement()!
  }
  
  private func selectPreparationCue() -> String {
    let cues = [
      "Turn earlier before the bounce.",
      "Get your body sideways sooner.",
      "Start your turn as the ball leaves their racket.",
      "Earlier shoulder turn."
    ]
    return cues.randomElement()!
  }
  
  private func selectKneeBendCue() -> String {
    let cues = [
      "Bend your knees more—stay athletic.",
      "Lower your center of gravity.",
      "Sit into your legs.",
      "More knee flex."
    ]
    return cues.randomElement()!
  }
  
  private func selectBalanceCue() -> String {
    let cues = [
      "Recover faster after the shot.",
      "Get back to center.",
      "Reset your balance quicker.",
      "Stay centered between shots."
    ]
    return cues.randomElement()!
  }
  
  // MARK: - Tactical Cues (opponent-based)
  
  func generateTacticalCue(opponentInfo: OpponentInfo) -> String? {
    guard opponentInfo.isVisible, opponentInfo.confidence >= speakingConfidenceThreshold else {
      return nil
    }
    
    switch opponentInfo.depthPosition {
    case .deep:
      return "Opponent is staying deep—use depth."
    case .shallow:
      switch opponentInfo.lateralBias {
      case .forehand:
        return "They're cheating forehand—go backhand."
      case .backhand:
        return "Open court on the forehand side."
      case .center:
        return "They're at net—consider a lob."
      case .unknown:
        return nil
      }
    case .mid, .unknown:
      return nil
    }
  }
  
  // MARK: - History Management
  
  private func recordCue(type: CueType) {
    lastCueType = type
    cueTypeHistory.append(type)
    if cueTypeHistory.count > maxHistorySize {
      cueTypeHistory.removeFirst()
    }
  }
  
  func reset() {
    lastCueType = nil
    cueTypeHistory.removeAll()
  }
}

// MARK: - "Not Sure" Responses

extension CoachingPolicy {
  
  static let unsureResponses = [
    "I'm not sure yet—keep playing.",
    "Can't tell from this angle.",
    "Need a better view."
  ]
  
  static func unsureResponse() -> String {
    unsureResponses.randomElement()!
  }
}
