import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// On-device pace alert, shown via DataField.showAlert(). Two flavors:
// behind pace (red, triggered after being continuously behind target
// pace for the configured threshold, repeating every 60s up to a
// 5-minute cutoff) and back on pace (green, fires once on recovery).
// See RacePaceFieldView.compute() for the trigger state machine -
// this class only draws the resulting message.
class RacePaceAlertView extends WatchUi.DataFieldAlert {
    private var _message as String;
    private var _color as Number;

    public function initialize(message as String, color as Number) {
        DataFieldAlert.initialize();
        _message = message;
        _color = color;
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(_color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_MEDIUM, _message, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
