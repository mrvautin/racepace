import Toybox.Lang;
import Toybox.WatchUi;

// Distance units picker: a simple list (Kilometers / Miles), matching the
// style of the Race Distance menu instead of an in-place toggle switch.
class RacePaceUnitsMenu extends WatchUi.Menu2 {
    public function initialize() {
        Menu2.initialize({:title => "Units"});
        addItem(new WatchUi.MenuItem("Kilometers", null, :unitsKm, {}));
        addItem(new WatchUi.MenuItem("Miles", null, :unitsMiles, {}));
    }
}

class RacePaceUnitsMenuDelegate extends WatchUi.Menu2InputDelegate {
    public function initialize() {
        Menu2InputDelegate.initialize();
    }

    public function onSelect(menuItem as WatchUi.MenuItem) as Void {
        var id = menuItem.getId();
        if (id == :unitsKm) {
            RacePaceCalc.setUnits(RacePaceCalc.UNITS_KM);
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :unitsMiles) {
            RacePaceCalc.setUnits(RacePaceCalc.UNITS_MILES);
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        }
    }
}
