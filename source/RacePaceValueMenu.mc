import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Generic "pick a number from a range" menu: one row per integer from
// min to max, scrolled to the current value on open. Used for Hours/
// Minutes/Seconds in RacePaceTimeMenu and Units/Tenths in
// RacePaceCustomDistanceMenu.
//
// A CustomMenu rather than plain Menu2 + MenuItem: MenuItem labels only
// support LEFT/RIGHT alignment (no CENTER), and on a round screen a
// short left-aligned number sits hard against the bezel with a big dead
// gap on the other side. CustomMenuItem.draw() lets us truly center the
// text in the row instead.
class RacePaceValueMenu extends WatchUi.CustomMenu {
    public function initialize(title as String, min as Number, max as Number, current as Number, format as String) {
        // CustomMenu's :title wants a Drawable, unlike Menu2's (which
        // also accepts a plain String).
        var titleDrawable = new WatchUi.Text({
            :text => title,
            :color => Graphics.COLOR_WHITE,
            :font => Graphics.FONT_MEDIUM,
            :justification => Graphics.TEXT_JUSTIFY_CENTER,
            :locX => WatchUi.LAYOUT_HALIGN_CENTER,
            :locY => WatchUi.LAYOUT_VALIGN_CENTER
        });
        CustomMenu.initialize(60, Graphics.COLOR_BLACK, {:title => titleDrawable});
        for (var v = min; v <= max; v += 1) {
            addItem(new RacePaceValueMenuItem(v, v.format(format)));
        }
        // :focus can only target an item that already exists, so this has
        // to happen after addItem, not as an initialize option (which
        // runs before any items are added and crashes on a non-zero index
        // into what is, at that point, an empty menu).
        var focusIndex = current - min;
        if (focusIndex >= 0 && focusIndex < (max - min + 1)) {
            setFocus(focusIndex);
        }
    }
}

class RacePaceValueMenuItem extends WatchUi.CustomMenuItem {
    private var _label as String;

    public function initialize(value as Number, label as String) {
        CustomMenuItem.initialize(value, {});
        _label = label;
    }

    public function draw(dc as Dc) as Void {
        var font = isFocused() ? Graphics.FONT_NUMBER_MILD : Graphics.FONT_MEDIUM;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, font, _label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class RacePaceValueMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _onPicked as Method(value as Number) as Void;

    public function initialize(onPicked as Method(value as Number) as Void) {
        Menu2InputDelegate.initialize();
        _onPicked = onPicked;
    }

    public function onSelect(menuItem as WatchUi.MenuItem) as Void {
        var value = menuItem.getId() as Number;
        _onPicked.invoke(value);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
}
