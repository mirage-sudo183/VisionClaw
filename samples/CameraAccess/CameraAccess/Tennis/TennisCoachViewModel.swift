import Foundation
import SwiftUI
import Combine

// MARK: - Tennis Coach View Model

@MainActor
class TennisCoachViewModel: ObservableObject {
  // Published state
  @Published var isEnabled: Bool = false
  @Published var isSessionActive: Bool = false
  @Published var sessionState: TennisSessionState = .idle
  @Published var currentFocus: TennisFocus = .general
  @Published var isMuted: Bool = false
  @Published var sessionDuration: TimeInterval = 0
  @Published var lastCue: String?
  @Published var cueCount: Int = 0
  @Published var poseSuccessRate: Double = 0
  @Published var frameCount: Int = 0
  
  // Review
  @Published var showReview: Bool = false
  @Published var currentReview: TennisSessionReview?
  
  // Logging
  @Published var recentLogs: [String] = []
  private let maxLogs = 50
  
  // Components
  let poseAnalyzer: TennisPoseAnalyzer
  let sessionManager: TennisSessionManager
  
  // Gemini integration
  weak var geminiSession: GeminiSessionViewModel?
  
  // Frame processing
  private var lastFrameTime: Date = .distantPast
  private let frameInterval: TimeInterval = 1.0 // Process pose at 1 fps
  private var cancellables = Set<AnyCancellable>()
  
  // Cue queue (for Gemini to speak)
  private var pendingCue: String?
  
  init() {
    self.poseAnalyzer = TennisPoseAnalyzer()
    self.sessionManager = TennisSessionManager(poseAnalyzer: poseAnalyzer)
    
    // Observe session manager state
    sessionManager.$isActive
      .receive(on: DispatchQueue.main)
      .sink { [weak self] active in
        self?.isSessionActive = active
      }
      .store(in: &cancellables)
    
    sessionManager.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        self?.sessionState = state
      }
      .store(in: &cancellables)
    
    sessionManager.$sessionDuration
      .receive(on: DispatchQueue.main)
      .sink { [weak self] duration in
        self?.sessionDuration = duration
      }
      .store(in: &cancellables)
    
    sessionManager.$isMuted
      .receive(on: DispatchQueue.main)
      .sink { [weak self] muted in
        self?.isMuted = muted
      }
      .store(in: &cancellables)
    
    sessionManager.$cueCount
      .receive(on: DispatchQueue.main)
      .sink { [weak self] count in
        self?.cueCount = count
      }
      .store(in: &cancellables)
    
    // Observe pose analyzer
    poseAnalyzer.$frameCount
      .receive(on: DispatchQueue.main)
      .sink { [weak self] count in
        self?.frameCount = count
        self?.poseSuccessRate = self?.poseAnalyzer.poseSuccessRate ?? 0
      }
      .store(in: &cancellables)
  }
  
  // MARK: - Session Control
  
  func startSession(focus: TennisFocus = .general) {
    guard isEnabled else {
      log("Cannot start: Tennis Coach not enabled")
      return
    }
    
    currentFocus = focus
    sessionManager.startSession(focus: focus)
    log("Session started with focus: \(focus.rawValue)")
    
    // Ask Gemini to announce focus question
    queueCue("What would you like to focus on today: movement, forehand, backhand, or serve?")
  }
  
  func endSession() {
    sessionManager.endSession()
    
    // Generate review
    currentReview = sessionManager.generateReview()
    showReview = true
    
    log("Session ended. Generating review...")
    
    // Queue spoken summary
    if let review = currentReview {
      queueCue(review.spokenSummary)
    }
  }
  
  func setFocus(_ focus: TennisFocus) {
    currentFocus = focus
    sessionManager.setFocus(focus)
    queueCue("Focusing on \(focus.rawValue.lowercased()). Let's go.")
  }
  
  func mute() {
    sessionManager.mute()
    log("Coaching muted")
  }
  
  func unmute() {
    sessionManager.unmute()
    log("Coaching unmuted")
  }
  
  // MARK: - Frame Processing
  
  func processVideoFrame(_ image: UIImage) {
    guard isEnabled, isSessionActive else { return }
    
    // Throttle to 1 fps
    let now = Date()
    guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
    lastFrameTime = now
    
    // Analyze pose
    poseAnalyzer.analyzeFrame(image)
    
    // Process metrics
    if poseAnalyzer.lastMetrics.isReliable {
      sessionManager.processMetrics(poseAnalyzer.lastMetrics)
    }
    
    // Process opponent
    if poseAnalyzer.opponentInfo.isVisible {
      sessionManager.processOpponentInfo(poseAnalyzer.opponentInfo)
    }
    
    // Check for cue generation
    if let cue = sessionManager.getNextCue() {
      lastCue = cue
      queueCue(cue)
    }
  }
  
  // MARK: - Voice Command Handling
  
  func handleVoiceCommand(_ transcript: String) {
    let lower = transcript.lowercased()
    
    if lower.contains("start tennis") || lower.contains("tennis session") {
      if !isSessionActive {
        startSession()
      }
      return
    }
    
    if lower.contains("end session") || lower.contains("stop tennis") {
      if isSessionActive {
        endSession()
      }
      return
    }
    
    if lower.contains("be quiet") || lower.contains("mute") {
      mute()
      return
    }
    
    if lower.contains("unmute") || lower.contains("speak again") {
      unmute()
      return
    }
    
    if lower.contains("what should i fix") || lower.contains("what to work on") {
      if isSessionActive, let cue = sessionManager.getNextCue() {
        queueCue(cue)
      } else {
        queueCue("Keep playing—I need more data to give specific feedback.")
      }
      return
    }
    
    // Focus commands
    if lower.contains("focus on movement") || lower.contains("footwork") {
      setFocus(.movement)
    } else if lower.contains("focus on forehand") {
      setFocus(.forehand)
    } else if lower.contains("focus on backhand") {
      setFocus(.backhand)
    } else if lower.contains("focus on serve") {
      setFocus(.serve)
    }
  }
  
  // MARK: - Cue Queue
  
  private func queueCue(_ cue: String) {
    pendingCue = cue
    log("Cue queued: \(cue)")
    // Note: Actual delivery happens via Gemini's voice
  }
  
  func consumePendingCue() -> String? {
    let cue = pendingCue
    pendingCue = nil
    return cue
  }
  
  // MARK: - Logging
  
  private func log(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let entry = "[\(timestamp)] \(message)"
    recentLogs.append(entry)
    if recentLogs.count > maxLogs {
      recentLogs.removeFirst()
    }
    NSLog("[TennisCoach] %@", message)
  }
  
  // MARK: - Review
  
  func dismissReview() {
    showReview = false
    currentReview = nil
  }
  
  func copyReviewToClipboard() {
    guard let review = currentReview else { return }
    UIPasteboard.general.string = review.summaryText
    log("Review copied to clipboard")
  }
}

// MARK: - Tennis Coach System Prompt

extension TennisCoachViewModel {
  
  static let tennisCoachSystemPrompt = """
    You are a high-performance tennis coach. You see through smart glasses with LIMITED visual fidelity.
    
    CRITICAL CONSTRAINTS:
    - The camera often does NOT see the racket clearly. You MUST NOT comment on racket mechanics.
    - Design your feedback around BODY POSE, TIMING, MOVEMENT, and TACTICS only.
    - Vision quality is low-FPS, wide-angle, and compressed.
    - If confidence is low, stay SILENT or say "I'm not sure yet."
    
    COACHING RULES:
    - Speak ONE thing at a time. Max 1 sentence.
    - Never speak more than once every 20 seconds.
    - Prefer silence over guessing.
    - Focus on: footwork, spacing, balance, preparation timing, recovery, tactical positioning.
    
    NEVER comment on:
    - Racket face angle
    - Grip
    - Wrist action
    - Contact point specifics
    - Swing path details
    
    ALLOWED cues (examples):
    - "Give yourself more space from the ball."
    - "Turn earlier before the bounce."
    - "Recover faster after the shot."
    - "Bend your knees—stay athletic."
    - "Opponent is staying deep—use depth."
    
    When a tennis session starts, ask ONCE: "Movement, forehand, backhand, or serve focus today?"
    
    When the session ends, give a brief spoken summary of 2-3 observations and suggest one drill.
    
    Remember: You are a supportive coach. Be calm, brief, and helpful.
    """
}
