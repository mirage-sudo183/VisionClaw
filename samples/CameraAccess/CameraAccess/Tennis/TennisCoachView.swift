import SwiftUI

// MARK: - Tennis Coach Overlay View

struct TennisCoachOverlayView: View {
  @ObservedObject var viewModel: TennisCoachViewModel
  
  var body: some View {
    VStack {
      Spacer()
      
      if viewModel.isEnabled {
        coachStatusBar
      }
    }
    .sheet(isPresented: $viewModel.showReview) {
      if let review = viewModel.currentReview {
        TennisSessionReviewView(review: review, viewModel: viewModel)
      }
    }
  }
  
  private var coachStatusBar: some View {
    VStack(spacing: 8) {
      // Session status
      HStack {
        Image(systemName: viewModel.isSessionActive ? "figure.tennis" : "figure.stand")
          .foregroundColor(viewModel.isSessionActive ? .green : .gray)
        
        Text(viewModel.isSessionActive ? viewModel.sessionState.rawValue : "Tennis Coach Ready")
          .font(.caption)
          .foregroundColor(.white)
        
        Spacer()
        
        if viewModel.isSessionActive {
          Text(formatDuration(viewModel.sessionDuration))
            .font(.caption.monospacedDigit())
            .foregroundColor(.white.opacity(0.8))
        }
        
        if viewModel.isMuted {
          Image(systemName: "speaker.slash.fill")
            .foregroundColor(.orange)
            .font(.caption)
        }
      }
      
      // Last cue
      if let cue = viewModel.lastCue, viewModel.isSessionActive {
        Text(cue)
          .font(.caption2)
          .foregroundColor(.white.opacity(0.7))
          .lineLimit(1)
      }
      
      // Stats (debug)
      if viewModel.isSessionActive {
        HStack {
          Text("Frames: \(viewModel.frameCount)")
          Text("Pose: \(Int(viewModel.poseSuccessRate * 100))%")
          Text("Cues: \(viewModel.cueCount)")
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundColor(.white.opacity(0.5))
      }
    }
    .padding(12)
    .background(Color.black.opacity(0.6))
    .cornerRadius(12)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }
  
  private func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}

// MARK: - Tennis Coach Control Panel

struct TennisCoachControlPanel: View {
  @ObservedObject var viewModel: TennisCoachViewModel
  @Environment(\.dismiss) var dismiss
  
  var body: some View {
    NavigationView {
      List {
        Section("Session") {
          Toggle("Tennis Coach Mode", isOn: $viewModel.isEnabled)
          
          if viewModel.isEnabled {
            if viewModel.isSessionActive {
              Button("End Session") {
                viewModel.endSession()
              }
              .foregroundColor(.red)
            } else {
              Button("Start Session") {
                viewModel.startSession()
              }
              .foregroundColor(.green)
            }
          }
        }
        
        if viewModel.isSessionActive {
          Section("Focus") {
            ForEach(TennisFocus.allCases, id: \.self) { focus in
              Button(action: { viewModel.setFocus(focus) }) {
                HStack {
                  Text(focus.rawValue)
                  Spacer()
                  if viewModel.currentFocus == focus {
                    Image(systemName: "checkmark")
                      .foregroundColor(.accentColor)
                  }
                }
              }
              .foregroundColor(.primary)
            }
          }
          
          Section("Voice") {
            Button(viewModel.isMuted ? "Unmute Coach" : "Mute Coach") {
              if viewModel.isMuted {
                viewModel.unmute()
              } else {
                viewModel.mute()
              }
            }
          }
          
          Section("Stats") {
            LabeledContent("Duration", value: formatDuration(viewModel.sessionDuration))
            LabeledContent("Frames Analyzed", value: "\(viewModel.frameCount)")
            LabeledContent("Pose Success Rate", value: "\(Int(viewModel.poseSuccessRate * 100))%")
            LabeledContent("Cues Given", value: "\(viewModel.cueCount)")
          }
        }
        
        Section("Voice Commands") {
          VStack(alignment: .leading, spacing: 4) {
            commandRow("Start tennis session")
            commandRow("End session")
            commandRow("Be quiet")
            commandRow("What should I fix?")
            commandRow("Focus on [movement/forehand/backhand/serve]")
          }
          .font(.caption)
          .foregroundColor(.secondary)
        }
        
        if !viewModel.recentLogs.isEmpty {
          Section("Recent Logs") {
            ForEach(viewModel.recentLogs.suffix(10), id: \.self) { log in
              Text(log)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }
          }
        }
      }
      .navigationTitle("Tennis Coach")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
  
  private func commandRow(_ text: String) -> some View {
    HStack {
      Image(systemName: "mic.fill")
        .font(.caption2)
      Text("\"\(text)\"")
    }
  }
  
  private func formatDuration(_ seconds: TimeInterval) -> String {
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
  }
}

// MARK: - Session Review View

struct TennisSessionReviewView: View {
  let review: TennisSessionReview
  @ObservedObject var viewModel: TennisCoachViewModel
  @Environment(\.dismiss) var dismiss
  
  var body: some View {
    NavigationView {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Header
          VStack(alignment: .leading, spacing: 4) {
            Text("Session Complete")
              .font(.largeTitle.bold())
            Text("\(review.durationFormatted) • \(review.focus.rawValue)")
              .foregroundColor(.secondary)
          }
          
          // Issues
          VStack(alignment: .leading, spacing: 12) {
            Text("Observations")
              .font(.headline)
            
            if review.issues.isEmpty {
              Text("Not enough reliable data to identify specific issues.")
                .foregroundColor(.secondary)
              Text("Pose detection rate: \(Int(review.poseSuccessRate * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
              ForEach(review.issues) { issue in
                IssueRow(issue: issue)
              }
            }
          }
          .padding()
          .background(Color(.secondarySystemBackground))
          .cornerRadius(12)
          
          // Drills
          VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Drills")
              .font(.headline)
            
            Text(review.summaryText.components(separatedBy: "### Suggested Drills\n").last?.components(separatedBy: "\n###").first ?? "Practice fundamentals")
              .font(.subheadline)
          }
          .padding()
          .background(Color(.secondarySystemBackground))
          .cornerRadius(12)
          
          // Tactical Notes
          if !review.opponentNotes.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("Tactical Notes")
                .font(.headline)
              
              ForEach(review.opponentNotes, id: \.self) { note in
                HStack(alignment: .top) {
                  Image(systemName: "target")
                    .foregroundColor(.orange)
                  Text(note)
                    .font(.subheadline)
                }
              }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
          }
          
          // Stats
          VStack(alignment: .leading, spacing: 8) {
            Text("Session Stats")
              .font(.headline)
            
            HStack {
              StatItem(title: "Frames", value: "\(review.totalFrames)")
              StatItem(title: "Pose Rate", value: "\(Int(review.poseSuccessRate * 100))%")
              StatItem(title: "Cues", value: "\(review.cueCount)")
            }
          }
          .padding()
          .background(Color(.secondarySystemBackground))
          .cornerRadius(12)
          
          // Limitations note
          Text("Note: Analysis based on body pose only. Racket mechanics not visible from glasses camera.")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 8)
        }
        .padding()
      }
      .navigationTitle("Review")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Copy") {
            viewModel.copyReviewToClipboard()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Done") {
            viewModel.dismissReview()
            dismiss()
          }
        }
      }
    }
  }
}

struct IssueRow: View {
  let issue: SessionIssue
  
  var body: some View {
    HStack {
      Circle()
        .fill(severityColor)
        .frame(width: 8, height: 8)
      
      VStack(alignment: .leading) {
        Text(issue.displayName)
          .font(.subheadline.bold())
        Text("\(issue.occurrences) occurrences • \(Int(issue.averageConfidence * 100))% confidence")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      
      Spacer()
      
      Text(severityText)
        .font(.caption)
        .foregroundColor(severityColor)
    }
  }
  
  private var severityColor: Color {
    switch issue.severity {
    case .high: return .red
    case .medium: return .orange
    case .low: return .yellow
    }
  }
  
  private var severityText: String {
    switch issue.severity {
    case .high: return "High"
    case .medium: return "Medium"
    case .low: return "Low"
    }
  }
}

struct StatItem: View {
  let title: String
  let value: String
  
  var body: some View {
    VStack {
      Text(value)
        .font(.title2.bold())
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Preview

#Preview {
  TennisCoachControlPanel(viewModel: TennisCoachViewModel())
}
