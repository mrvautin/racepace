import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Shown briefly if the settings view is ever pushed without a menu press
// (e.g. some devices show this before the activity menu opens).
class RacePaceSettingsView extends WatchUi.View {

    public function initialize() {
        View.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL, "RacePace\nPress MENU", Graphics.TEXT_JUSTIFY_CENTER);
    }
}

// Opens the main settings menu when the activity's Settings entry is used.
class RacePaceSettingsDelegate extends WatchUi.BehaviorDelegate {

    public function initialize() {
        BehaviorDelegate.initialize();
    }

    public function onMenu() as Boolean {
        openMainMenu();
        return true;
    }

    public function onSelect() as Boolean {
        openMainMenu();
        return true;
    }

    private function openMainMenu() as Void {
        WatchUi.pushView(new RacePaceMainMenu(), new RacePaceMainMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
    }
}
