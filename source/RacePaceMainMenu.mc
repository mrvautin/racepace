import Toybox.Lang;
import Toybox.WatchUi;

class RacePaceMainMenu extends WatchUi.Menu2 {
    public function initialize() {
        Menu2.initialize({:title => "RacePace Settings"});
        addItem(new WatchUi.MenuItem("Race Distance", RacePaceCalc.formatDistance(RacePaceCalc.getRaceDistanceM()), :distance, {}));
        addItem(new WatchUi.MenuItem("Finish Time", RacePaceCalc.formatDuration(RacePaceCalc.getFinishTimeSec()), :finishTime, {}));
        addItem(new WatchUi.MenuItem("Units", unitsLabel(), :units, {}));
    }

    private function unitsLabel() as String {
        return (RacePaceCalc.getUnits() == RacePaceCalc.UNITS_MILES) ? "Miles" : "Kilometers";
    }

    // Sub-labels are set once at construction; refresh them whenever this
    // menu becomes visible again (e.g. returning from the distance
    // submenu, finish time picker, or units menu) so they don't show
    // stale values.
    public function onShow() as Void {
        var distanceItem = getItem(0);
        if (distanceItem != null) {
            distanceItem.setSubLabel(RacePaceCalc.formatDistance(RacePaceCalc.getRaceDistanceM()));
        }
        var finishItem = getItem(1);
        if (finishItem != null) {
            finishItem.setSubLabel(RacePaceCalc.formatDuration(RacePaceCalc.getFinishTimeSec()));
        }
        var unitsItem = getItem(2);
        if (unitsItem != null) {
            unitsItem.setSubLabel(unitsLabel());
        }
    }
}

class RacePaceMainMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(menuItem as WatchUi.MenuItem) as Void {
        var id = menuItem.getId();
        if (id == :distance) {
            WatchUi.pushView(new RacePaceDistanceMenu(), new RacePaceDistanceMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :finishTime) {
            WatchUi.pushView(new RacePaceTimeMenu(), new RacePaceTimeMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :units) {
            WatchUi.pushView(new RacePaceUnitsMenu(), new RacePaceUnitsMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        }
    }
}
