import SwiftUI

/// Shared building blocks for the app's flat, monochrome design language:
/// small gray section headers, hairline-separated rows, gray content cards,
/// and full-width pill buttons with a single high-contrast primary action.

// MARK: - Buttons

struct PillButton: View {
  enum Kind {
    case primary  // high-contrast, one per screen
    case secondary
    case destructive
  }

  let title: String
  var systemImage: String?
  var kind: Kind = .primary
  var isLoading = false
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(foreground)
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
        }
        Text(title)
          .font(.body.weight(.semibold))
      }
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(Capsule().fill(background))
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.35)
  }

  private var foreground: Color {
    switch kind {
    case .primary: return Color(.systemBackground)
    case .secondary: return .primary
    case .destructive: return .white
    }
  }

  private var background: Color {
    switch kind {
    case .primary: return .primary
    case .secondary: return Color(.systemGray6)
    case .destructive: return .red
    }
  }
}

// MARK: - Containers

/// Gray rounded container used for quoted text and inline content.
struct Card<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color(.systemGray6)))
  }
}

/// Small gray header above a group of rows.
struct SectionLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
  }
}

/// Rows separated by inset hairlines, matching the agent list.
struct RowGroup<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      content
    }
  }
}

/// Hairline divider aligned with row text.
struct RowDivider: View {
  var leading: CGFloat = 0

  var body: some View {
    Divider().padding(.leading, leading)
  }
}

// MARK: - Rows

/// Navigation row: monochrome icon, title, optional trailing detail, chevron.
struct SettingsRow: View {
  let icon: String
  let title: String
  var detail: String?
  var detailColor: Color = .secondary

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      Text(title)
      Spacer()
      if let detail {
        Text(detail)
          .foregroundStyle(detailColor)
      }
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 13)
    .contentShape(.rect)
  }
}

/// Key/value row with arbitrary trailing content.
struct InfoRow<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack {
      Text(title)
      Spacer()
      trailing
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 13)
  }
}

/// Selectable row with a leading checkmark slot, plus optional trailing action.
struct SelectionRow<Trailing: View>: View {
  let title: String
  var subtitle: String?
  let isSelected: Bool
  let select: () -> Void
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 12) {
      Button(action: select) {
        HStack(spacing: 12) {
          Image(systemName: "checkmark")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.green)
            .opacity(isSelected ? 1 : 0)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .foregroundStyle(.primary)
            if let subtitle {
              Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)

      trailing
    }
    .padding(.vertical, 12)
  }
}

// MARK: - Status

/// Colored dot used to convey state at a glance.
struct StatusDot: View {
  let color: Color
  var size: CGFloat = 8

  var body: some View {
    Circle().fill(color).frame(width: size, height: size)
  }
}
