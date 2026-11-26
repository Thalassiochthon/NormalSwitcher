using System.Drawing;
using RuSwitcher.Win.Core;
using RuSwitcher.Win.Tray;
using Xunit;

namespace RuSwitcher.Win.Tests;

public class CaretBadgePlacementTests
{
    private static readonly Size Badge = new(48, 20);
    private static readonly Rectangle Area = new(-500, 100, 500, 400);

    [Fact]
    public void PositionsByTheAccessibleCaretOnANegativeCoordinateMonitor()
    {
        var caret = new AccessibleText.BadgeAnchor(new Rectangle(-160, 220, 1, 18), IsCaret: true);
        Assert.Equal(new Point(-160, 195), CaretBadge.AccessibleOrigin(caret, Badge, persistent: true, Area));
        Assert.Equal(new Point(-155, 241), CaretBadge.AccessibleOrigin(caret, Badge, persistent: false, Area));
    }

    [Fact]
    public void PlacesEmptyEditorBadgeOutsideItsTextAreaAndInsideTheWindow()
    {
        var editor = new AccessibleText.BadgeAnchor(new Rectangle(-45, 105, 40, 32), IsCaret: false);
        Assert.Equal(new Point(-48, 140), CaretBadge.AccessibleOrigin(editor, Badge, persistent: true, Area));
    }

    [Fact]
    public void RejectsAnAnchorOutsideTheWindowOrWithoutSpace()
    {
        var offscreen = new AccessibleText.BadgeAnchor(new Rectangle(10, 200, 1, 18), IsCaret: true);
        var tallEditor = new AccessibleText.BadgeAnchor(Area, IsCaret: false);
        Assert.Null(CaretBadge.AccessibleOrigin(offscreen, Badge, persistent: true, Area));
        Assert.Null(CaretBadge.AccessibleOrigin(tallEditor, Badge, persistent: true, Area));
    }
}
