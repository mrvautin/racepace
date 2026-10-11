import Toybox.Lang;
import Toybox.WatchUi;

// Finish Time entry as three rows (Hours / Minutes / Seconds), each
// opening a value list - the same Menu2 pattern as RacePaceMainMenu and
// RacePaceDistanceMenu. Menu2 themes itself correctly on every device via
// the system's own MenuTheme, unlike WatchUi.Picker (see
// RacePaceValueMenu for why the Picker-based version was dropped).
class RacePaceTimeMenu extends WatchUi.Menu2 {
    public function initialize() {
        Menu2.initialize({:title => "Finish Time"});
        var totalSec = RacePaceCalc.getFinishTimeSec();
        addItem(new WatchUi.MenuItem("Hours", (totalSec / 3600).format("%d"), :hours, {}));
        addItem(new WatchUi.MenuItem("Minutes", ((totalSec % 3600) / 60).format("%02d"), :minutes, {}));
        addItem(new WatchUi.MenuItem("Seconds", (totalSec % 60).format("%02d"), :seconds, {}));
    }

    // Refresh sub-labels whenever this menu becomes visible again (e.g.
    // returning from a value list) so they don't show stale values.
    public function onShow() as Void {
        var totalSec = RacePaceCalc.getFinishTimeSec();
        var hoursItem = getItem(0);
        if (hoursItem != null) {
            hoursItem.setSubLabel((totalSec / 3600).format("%d"));
        }
        var minutesItem = getItem(1);
        if (minutesItem != null) {
            minutesItem.setSubLabel(((totalSec % 3600) / 60).format("%02d"));
        }
        var secondsItem = getItem(2);
        if (secondsItem != null) {
            secondsItem.setSubLabel((totalSec % 60).format("%02d"));
        }
    }
}

class RacePaceTimeMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(menuItem as WatchUi.MenuItem) as Void {
        var id = menuItem.getId();
        var totalSec = RacePaceCalc.getFinishTimeSec();
        if (id == :hours) {
            WatchUi.pushView(
                new RacePaceValueMenu("Hours", 0, 23, totalSec / 3600, "%d"),
                new RacePaceValueMenuDelegate(method(:onHoursPicked)),
                WatchUi.SLIDE_IMMEDIATE
            );
        } else if (id == :minutes) {
            WatchUi.pushView(
                new RacePaceValueMenu("Minutes", 0, 59, (totalSec % 3600) / 60, "%02d"),
                new RacePaceValueMenuDelegate(method(:onMinutesPicked)),
                WatchUi.SLIDE_IMMEDIATE
            );
        } else if (id == :seconds) {
            WatchUi.pushView(
                new RacePaceValueMenu("Seconds", 0, 59, totalSec % 60, "%02d"),
                new RacePaceValueMenuDelegate(method(:onSecondsPicked)),
                WatchUi.SLIDE_IMMEDIATE
            );
        }
    }

    // Public: method(:onXPicked) below is an indirect symbol lookup,
    // which - unlike a direct self.onXPicked reference - can't resolve a
    // private method at runtime even though it compiles clean. That
    // silently broken method reference is what was crashing the app the
    // moment a value got picked.
    public function onHoursPicked(value as Number) as Void {
        var totalSec = RacePaceCalc.getFinishTimeSec();
        setFinishTimeParts(value, (totalSec % 3600) / 60, totalSec % 60);
    }

    public function onMinutesPicked(value as Number) as Void {
        var totalSec = RacePaceCalc.getFinishTimeSec();
        setFinishTimeParts(totalSec / 3600, value, totalSec % 60);
    }

    public function onSecondsPicked(value as Number) as Void {
        var totalSec = RacePaceCalc.getFinishTimeSec();
        setFinishTimeParts(totalSec / 3600, (totalSec % 3600) / 60, value);
    }

    private function setFinishTimeParts(hours as Number, mins as Number, secs as Number) as Void {
        var totalSec = (hours * 3600) + (mins * 60) + secs;
        if (totalSec <= 0) {
            totalSec = 1;
        }
        RacePaceCalc.setFinishTimeSec(totalSec);
    }
}
