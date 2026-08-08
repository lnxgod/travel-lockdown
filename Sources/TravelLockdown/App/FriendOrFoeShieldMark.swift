import AppKit
import SwiftUI

enum LockdownVisualState: Equatable, Sendable {
    case off
    case active
    case attention
}

struct FriendOrFoeTriangle: Equatable, Sendable {
    let topX: CGFloat
    let topY: CGFloat
    let leftX: CGFloat
    let baseY: CGFloat
    let rightX: CGFloat
}

enum FriendOrFoeMarkGeometry {
    static let viewport: CGFloat = 24

    // Canonical Friend or Foe mark from the Android and badge interfaces.
    static let triangles = [
        FriendOrFoeTriangle(topX: 12, topY: 2, leftX: 7, baseY: 10, rightX: 17),
        FriendOrFoeTriangle(topX: 6.5, topY: 11, leftX: 1.5, baseY: 19, rightX: 11.5),
        FriendOrFoeTriangle(topX: 17.5, topY: 11, leftX: 12.5, baseY: 19, rightX: 22.5)
    ]
}

/// The Friend or Foe shield lockup used inside the Travel Lockdown panel.
struct FriendOrFoeBrandLogo: View {
    let size: CGFloat
    var state: LockdownVisualState = .off

    var body: some View {
        Group {
            if let image = FriendOrFoeAssets.shieldLogo {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                FriendOrFoeShieldMark(size: size)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if state != .off {
                Circle()
                    .fill(stateColor)
                    .frame(width: size * 0.22, height: size * 0.22)
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.72), lineWidth: max(1, size * 0.035))
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Friend or Foe")
    }

    private var stateColor: Color {
        switch state {
        case .off:
            .clear
        case .active:
            .green
        case .attention:
            .orange
        }
    }
}

/// A source-rendered fallback that preserves the canonical three-triangle mark.
struct FriendOrFoeShieldMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(shieldFill)

            FriendOrFoeTriangleMarkShape()
                .fill(friendOrFoeGold)
                .frame(width: size * 0.58, height: size * 0.58)
                .offset(y: -size * 0.015)

            Image(systemName: "shield")
                .resizable()
                .scaledToFit()
                .foregroundStyle(friendOrFoeGold.opacity(0.72))
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Friend or Foe")
    }

    private let shieldFill = Color(red: 0.035, green: 0.055, blue: 0.10)
    private let friendOrFoeGold = Color(
        red: 1,
        green: 193.0 / 255.0,
        blue: 7.0 / 255.0
    )
}

struct FriendOrFoeTriangleMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / FriendOrFoeMarkGeometry.viewport
        let xOffset = rect.minX + (rect.width - FriendOrFoeMarkGeometry.viewport * scale) / 2
        let yOffset = rect.minY + (rect.height - FriendOrFoeMarkGeometry.viewport * scale) / 2

        func point(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: xOffset + x * scale, y: yOffset + y * scale)
        }

        var mark = Path()
        for triangle in FriendOrFoeMarkGeometry.triangles {
            mark.move(to: point(x: triangle.topX, y: triangle.topY))
            mark.addLine(to: point(x: triangle.leftX, y: triangle.baseY))
            mark.addLine(to: point(x: triangle.rightX, y: triangle.baseY))
            mark.closeSubpath()
        }
        return mark
    }
}

@MainActor
private enum FriendOrFoeAssets {
    static let shieldLogo: NSImage? = {
        guard let mainURL = Bundle.main.url(
            forResource: "friend-or-foe-shield",
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: mainURL)
    }()
}
