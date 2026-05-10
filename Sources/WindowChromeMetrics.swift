import CoreGraphics

enum WindowChromeMetrics {
    static var sharedChromeBarHeight: CGFloat { ChromeBarHeightSettings.effectivePoints() }
    static var appTitlebarHeight: CGFloat { sharedChromeBarHeight }
    static var bonsplitTabBarHeight: CGFloat { sharedChromeBarHeight }
    static var secondaryTitlebarHeight: CGFloat { sharedChromeBarHeight }
    static var minimumTitlebarHeight: CGFloat { ChromeBarHeightSettings.minPoints }
    static let maximumTitlebarHeight: CGFloat = 72
    static var defaultTitlebarHeight: CGFloat { sharedChromeBarHeight }

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static var titlebarHeight: CGFloat { WindowChromeMetrics.appTitlebarHeight }
}

enum RightSidebarChromeMetrics {
    static var titlebarHeight: CGFloat { WindowChromeMetrics.appTitlebarHeight }
    static var secondaryBarHeight: CGFloat { WindowChromeMetrics.secondaryTitlebarHeight }
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 3
    static var controlHeight: CGFloat { secondaryBarHeight - (barVerticalPadding * 2) }
    static let controlHorizontalPadding: CGFloat = 8
    static let controlCornerRadius: CGFloat = 5
}

enum SidebarWorkspaceListMetrics {
    // Anchored to the pre-config default chrome bar height (28pt) so the
    // sidebar list position doesn't track ChromeBarHeightSettings. Users
    // resizing the chrome bar reported the sidebar drift as unwanted.
    private static let titlebarOffsetAnchor: CGFloat = 28
    static let firstRowTopOffset: CGFloat = titlebarOffsetAnchor + 2
    static let rowVerticalPadding: CGFloat = 8
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = topScrimHeight

    static var scrollTopInset: CGFloat {
        max(0, firstRowTopOffset - rowVerticalPadding)
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static var workspaceList: SidebarWorkspaceScrollInsets {
        SidebarWorkspaceScrollInsets(
            top: SidebarWorkspaceListMetrics.scrollTopInset,
            bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
        )
    }

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        max(0, viewportHeight - insets.total)
    }
}
