import PeardCore
import SwiftUI

/// The connections you are in, as faces, always on screen.
///
/// Replaces a `Menu` in the header. A menu is the wrong control for something a
/// user does often and needs to see the state of: it hid how many connections
/// existed, took two taps to switch, and showed the current one's name but nothing
/// about who was in it. A rail of avatars answers "who am I sharing with" without
/// being opened, and switching is one tap.
///
/// Scrolls horizontally because 20 connections is the documented ceiling, and it
/// scrolls to keep the selected one visible after a switch made from elsewhere —
/// a notification tap, or another device.
struct ConnectionRail: View {
    let connections: [Connection]
    let selectedID: String
    let serverURL: URL
    let onSelect: (String) -> Void
    let onAdd: () -> Void

    private let avatarSize: CGFloat = 46

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(connections) { connection in
                        item(for: connection)
                            .id(connection.id)
                    }
                    addButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            // Not animated: the rail is drawn while the whole home screen is
            // changing connection, and a scroll animation on top of that reads as
            // the list lurching.
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        // Negative inset against the header's own padding: the tiles need to be
        // able to run to the screen edge, or the last one looks clipped rather
        // than scrollable.
        .padding(.horizontal, -20)
    }

    private func item(for connection: Connection) -> some View {
        let isSelected = connection.id == selectedID
        return Button {
            onSelect(connection.id)
        } label: {
            VStack(spacing: 5) {
                AvatarView(
                    avatar: connection.avatar,
                    serverURL: serverURL,
                    size: avatarSize,
                    ringColor: isSelected ? PearColor.accent : nil
                )
                .overlay(alignment: .bottomTrailing) {
                    if connection.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PearColor.textSecondary)
                            .padding(3)
                            .background(PearColor.background, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
                // Dimmed rather than hidden: an unselected connection is still
                // one you are in, and greying the label out entirely made the rail
                // read as disabled.
                Text(PartnerLabel.short(connection.title()))
                    .font(.caption2.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? PearColor.textPrimary : PearColor.textSecondary)
                    .lineLimit(1)
                    .frame(width: avatarSize + 14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: connection, isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func accessibilityLabel(for connection: Connection, isSelected: Bool) -> String {
        var parts = [connection.title()]
        parts.append(connection.subtitle)
        if connection.isMuted { parts.append("muted") }
        if isSelected { parts.append("showing") }
        return parts.joined(separator: ", ")
    }

    private var addButton: some View {
        Button(action: onAdd) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PearColor.accent)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(PearColor.surface, in: Circle())
                    .overlay {
                        Circle().strokeBorder(
                            PearColor.divider,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4])
                        )
                    }
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(PearColor.textSecondary)
                    .frame(width: avatarSize + 14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New connection")
        .accessibilityHint("Pear up with somebody else, or start a group")
    }
}
