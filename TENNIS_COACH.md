# Tennis Coach Mode 🎾

A pose-first tennis coaching feature for VisionClaw that works with Ray-Ban Meta smart glasses.

## Overview

Tennis Coach Mode analyzes your body pose in real-time to provide actionable coaching cues. **It deliberately does NOT depend on seeing your racket** — the glasses camera often can't capture it clearly.

### What It Coaches (Body Pose)
- Footwork and spacing
- Balance and athletic stance (knee bend)
- Early preparation (torso rotation)
- Recovery movement
- Tactical positioning

### What It Does NOT Coach (Racket Mechanics)
- Grip
- Racket face angle
- Wrist action
- Contact point
- Swing path

## Quick Start

### 1. Enable Tennis Coach Mode
- Start streaming from your Ray-Ban glasses
- Tap the 🎾 button to open Tennis Coach settings
- Toggle "Tennis Coach Mode" ON

### 2. Start a Session
- Tap "Start Session" or say **"Start tennis session"**
- The coach will ask: "Movement, forehand, backhand, or serve focus today?"
- Answer verbally or tap a focus in settings

### 3. Play Tennis
- The coach watches your body pose at ~1 fps
- When an issue is detected consistently, you'll hear a brief cue
- Maximum 1 cue every 20 seconds
- If visibility is poor, the coach stays silent

### 4. End Session
- Say **"End session"** or tap "End Session"
- View your session review with:
  - Top 3 issues observed
  - Suggested drills
  - Tactical notes (if opponent was visible)

## Voice Commands

| Command | Action |
|---------|--------|
| "Start tennis session" | Begin coaching |
| "End session" | Stop and show review |
| "Be quiet" / "Mute" | Silence coaching cues |
| "Unmute" | Resume coaching cues |
| "What should I fix?" | Get immediate feedback |
| "Focus on movement" | Set focus to footwork |
| "Focus on forehand" | Set focus to forehand |
| "Focus on backhand" | Set focus to backhand |
| "Focus on serve" | Set focus to serve |

## Example Cues

The coach speaks in short, actionable sentences:

- "Give yourself more space from the ball."
- "Turn earlier before the bounce."
- "Recover faster after the shot."
- "Bend your knees—stay athletic."
- "Opponent is staying deep—use depth."

## Technical Details

### Pose Metrics
- **Movement Intensity**: Detected via frame-to-frame body position changes
- **Knee Bend Score**: Angle at knee joints (lower = more athletic)
- **Torso Rotation Score**: Shoulder line vs hip line angle
- **Spacing Score**: Arm distance from body center
- **Balance Score**: Upper body centered over feet

### Confidence Handling
- Each metric has a confidence value (0-1)
- Cues only fire when confidence ≥ 0.5
- Issues must be detected ≥ 3 times before cueing
- If all metrics are low confidence, the coach stays silent

### Opponent Analysis (Optional)
When a second person is detected in frame:
- Track their depth position (deep/mid/shallow)
- Track their lateral bias (forehand/center/backhand)
- Generate tactical notes (max 3 per session)

## Limitations

⚠️ **Important**: This feature is designed around the constraints of smart glasses cameras:

1. **Low FPS**: Video is processed at ~1 fps for pose analysis
2. **Wide angle**: The glasses camera has a wide FOV
3. **Compression**: JPEG frames are compressed to 50% quality
4. **No racket**: The racket is often outside frame or blurry
5. **Lighting**: Poor lighting reduces pose detection accuracy
6. **Distance**: Opponent analysis works best when they're clearly in frame

**Pose detection success rate varies** — the session review shows your actual detection rate.

## Files

```
Tennis/
├── TennisPoseAnalyzer.swift      # Vision framework pose detection
├── TennisSessionManager.swift    # Session state and issue tracking
├── CoachingPolicy.swift          # When and what to say
├── TennisCoachViewModel.swift    # Main coordinator
└── TennisCoachView.swift         # SwiftUI views
```

## Session Review Format

After ending a session, you get:

### Spoken Summary
> "Session complete. 12 minutes of forehand practice. Main focus area: knee bend. Also work on spacing. Tactical note: Opponent is staying deep—use depth."

### Written Review (copyable)
```
## Tennis Session Review
Duration: 12:34 | Focus: Forehand

### Issues Observed
1. **Knee Bend** — High priority (72% confidence)
2. **Spacing** — Medium priority (65% confidence)

### Suggested Drills
1. **Shadow swings with squat hold** — pause in ready position, check knee angle
2. **Extend and reach drill** — shadow swing reaching away from body

### Tactical Notes
- Opponent is staying deep—use depth.
```

## Requirements

- Ray-Ban Meta smart glasses (Tennis Coach only works in glasses mode)
- VisionClaw app with Gemini API key configured
- iOS 17.0+
- Good lighting for pose detection

## FAQ

**Q: Why doesn't it comment on my racket technique?**
A: The glasses camera often can't see your racket clearly. Guessing would be worse than staying silent.

**Q: Why is it so quiet?**
A: The coach only speaks when it's confident AND the issue has been detected multiple times. Silence means either (a) you're doing well or (b) the camera view isn't good enough.

**Q: Can I use this with iPhone camera mode?**
A: No — Tennis Coach is disabled in iPhone mode. It's designed for the unique constraints of glasses-mounted cameras.

**Q: How do I improve pose detection?**
A: Wear contrasting clothing, play in good lighting, and position yourself so you're facing the camera direction.
