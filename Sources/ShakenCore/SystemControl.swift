import Foundation

/// Things a "System" slot can do.
public enum SystemControl: String, CaseIterable, Codable, Sendable {
    case volumeUp = "volume-up", volumeDown = "volume-down", mute
    case brightnessUp = "brightness-up", brightnessDown = "brightness-down"
    case playPause = "play-pause", nextTrack = "next-track", previousTrack = "previous-track"
    case screenshot, missionControl = "mission-control", screenSaver = "screen-saver"
    case darkMode = "dark-mode", displaySleep = "display-sleep", lockScreen = "lock-screen", sleep

    public var title: String {
        switch self {
        case .volumeUp: return L("Volume up")
        case .volumeDown: return L("Volume down")
        case .mute: return L("Mute")
        case .brightnessUp: return L("Brightness up")
        case .brightnessDown: return L("Brightness down")
        case .playPause: return L("Play/Pause")
        case .nextTrack: return L("Next track")
        case .previousTrack: return L("Previous track")
        case .screenshot: return L("Screenshot")
        case .missionControl: return L("Mission Control")
        case .screenSaver: return L("Screen saver")
        case .darkMode: return L("Dark mode")
        case .displaySleep: return L("Turn display off")
        case .lockScreen: return L("Lock screen")
        case .sleep: return L("Sleep")
        }
    }

    public var icon: String {
        switch self {
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .screenshot: return "camera.viewfinder"
        case .missionControl: return "rectangle.3.group"
        case .screenSaver: return "sparkles.tv"
        case .darkMode: return "circle.lefthalf.filled"
        case .displaySleep: return "display"
        case .lockScreen: return "lock.fill"
        case .sleep: return "moon.zzz.fill"
        }
    }

    /// Sent as key presses, so they need Accessibility permission.
    public var needsAccessibility: Bool {
        [.brightnessUp, .brightnessDown, .playPause, .nextTrack, .previousTrack, .screenshot, .lockScreen].contains(self)
    }
}
