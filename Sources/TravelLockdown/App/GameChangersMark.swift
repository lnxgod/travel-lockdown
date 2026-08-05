import AppKit
import SwiftUI

enum GameChangersMarkState: Equatable, Sendable {
    case off
    case active
    case attention
}

/// The official square logo at menu-bar size, with a small independent status dot.
/// Keeping the full-color source artwork avoids the joystick silhouette collapsing
/// into an ambiguous plus sign when macOS renders it at status-item scale.
struct GameChangersMenuBarLogo: View {
    let size: CGFloat
    var state: GameChangersMarkState = .off

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = GameChangersAssets.menuBarLogo {
                    Image(nsImage: image)
                        .interpolation(.high)
                        .renderingMode(.original)
                } else {
                    Image(systemName: "arcade.stick.console.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .padding(2)
                }
            }
            .scaledToFit()
            .frame(width: size, height: size)

            if state != .off {
                Circle()
                    .fill(stateColor)
                    .overlay {
                        Circle().stroke(.black.opacity(0.85), lineWidth: 1)
                    }
                    .frame(width: 6, height: 6)
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GameChangers AI")
    }

    private var stateColor: Color {
        switch state {
        case .active:
            Color(red: 0, green: 1, blue: 0.533)
        case .attention:
            .orange
        case .off:
            .clear
        }
    }
}

/// The official GameChangers AI lockup used inside the menu panel.
struct GameChangersBrandLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = GameChangersAssets.logo {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                GameChangersMark(size: size)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GameChangers AI")
    }
}

/// A status-item adaptation of the joystick/controller in the official logo.
/// The full lockup is unreadable at 18 points, so this keeps its recognizable
/// silhouette and neon green/cyan brand accents at native menu-bar size.
struct GameChangersMark: View {
    let size: CGFloat
    var state: GameChangersMarkState = .off

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16)
                .fill(Color(red: 0.06, green: 0.07, blue: 0.09))
                .frame(width: size * 0.90, height: size * 0.48)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.16)
                        .stroke(brandCyan, lineWidth: max(0.8, size * 0.055))
                }
                .offset(y: size * 0.17)

            Capsule()
                .fill(Color.white)
                .frame(width: size * 0.12, height: size * 0.45)
                .overlay {
                    Capsule()
                        .stroke(brandCyan, lineWidth: max(0.6, size * 0.035))
                }
                .offset(y: -size * 0.05)

            Circle()
                .fill(Color(red: 0.06, green: 0.07, blue: 0.09))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay {
                    Circle()
                        .stroke(Color.white, lineWidth: max(0.8, size * 0.05))
                }
                .overlay {
                    Circle()
                        .stroke(brandCyan.opacity(0.9), lineWidth: max(0.5, size * 0.025))
                        .padding(size * 0.055)
                }
                .offset(y: -size * 0.29)

            Image(systemName: "plus")
                .font(.system(size: size * 0.17, weight: .black))
                .foregroundStyle(brandGreen)
                .offset(x: -size * 0.28, y: size * 0.17)

            Circle()
                .fill(brandGreen)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.25, y: size * 0.12)
            Circle()
                .fill(brandCyan)
                .frame(width: size * 0.08, height: size * 0.08)
                .offset(x: size * 0.34, y: size * 0.21)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(stateColor, lineWidth: state == .off ? 0 : max(1.25, size * 0.055))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GameChangers AI")
    }

    private let brandGreen = Color(red: 0, green: 1, blue: 0.533)
    private let brandCyan = Color(red: 0.4, green: 0.851, blue: 1)

    private var stateColor: Color {
        switch state {
        case .off:
            .clear
        case .active:
            brandGreen
        case .attention:
            .orange
        }
    }
}

@MainActor
private enum GameChangersAssets {
    static let logo: NSImage? = {
        guard let mainURL = Bundle.main.url(
            forResource: "gamechangers-ai",
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: mainURL)
    }()

    static let menuBarLogo: NSImage? = {
        guard let image = logo?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        return image
    }()
}
