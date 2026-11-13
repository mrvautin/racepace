import Toybox.Lang;
import Toybox.Application.Storage;
import Toybox.Application.Properties;

// Property keys and race-math helpers for the RacePace data field.
// Canonical units are always meters and seconds; unit conversion only
// happens at display time.
module RacePaceCalc {

    const PROP_DISTANCE_M = "raceDistanceM";
    const PROP_FINISH_SEC = "finishTimeSec";
    const PROP_UNITS = "distanceUnits";
    const PROP_DISTANCE_DISPLAY = "raceDistanceDisplay";
    const PROP_FINISH_MIN = "finishTimeMin";
    const PROP_SHOW_PROGRESS_RING = "showProgressRing";
    const PROP_HIGHLIGHT_DELTA = "highlightDelta";
    const PROP_PACE_SMOOTHING_M = "paceSmoothingM";
    const PROP_BACKGROUND_MODE = "backgroundMode";
    const PROP_ALERTS_ENABLED = "alertsEnabled";
    const PROP_ALERT_THRESHOLD_SEC = "alertBehindThresholdSec";

    enum {
        UNITS_KM = 0,
        UNITS_MILES = 1
    }

    enum {
        BACKGROUND_BLACK = 0,
        BACKGROUND_WHITE = 1
    }

    // Every value the field can show. The numbering is also the on-screen
    // order (left to right within a row) and the order used to decide
    // which values to drop when a row has too many - see buildRows().
    enum {
        ITEM_CURRENT = 0,
        ITEM_AVERAGE = 1,
        ITEM_SPLIT = 2,
        ITEM_TARGET = 3,
        ITEM_DELTA = 4,
        ITEM_FINISH_DELTA = 5,
        ITEM_FINISH = 6,
        ITEM_DISTANCE = 7,
        ITEM_ELAPSED = 8,
        ITEM_HEART_RATE = 9,
        ITEM_AVG_HEART_RATE = 10
    }

    // Each item's placement is a phone-settings dropdown (hidden, top
    // row or bottom row) stored under property "p<item id>" - p0 is
    // Current Pace, p6 Projected Finish, and so on. Short, computed keys
    // rather than a table of descriptive names, because every byte counts
    // on the 32 KB watches (see source-lite/).
    const ITEM_COUNT = 11;

    enum {
        POS_HIDDEN = 0,
        POS_TOP = 1,
        POS_BOTTOM = 2
    }

    // More than this many values in one row squeezes each too small to
    // read at a glance. The "Max 3 values per row" warning in both views
    // and the "(max 3)" setting labels in strings.xml spell this out -
    // keep them in step if it changes.
    const MAX_PER_ROW = 3;

    // Bumped by the app whenever phone settings change, so views know to
    // rebuild their cached row layout (and re-check it for overflow).
    var settingsVersion as Number = 0;

    const METERS_PER_KM = 1000.0;
    const METERS_PER_MILE = 1609.344;

    function getRaceDistanceM() as Float {
        var v = Properties.getValue(PROP_DISTANCE_M);
        if (v == null || v <= 0) {
            return 5000.0;
        }
        return v.toFloat();
    }

    function getFinishTimeSec() as Number {
        var v = Properties.getValue(PROP_FINISH_SEC);
        if (v == null || v <= 0) {
            return 1800;
        }
        return v.toNumber();
    }

    function getUnits() as Number {
        var v = Properties.getValue(PROP_UNITS);
        return (v == null) ? UNITS_KM : v.toNumber();
    }

    // Splits the placed items into [top row, bottom row, overflowed],
    // each row a list of ITEM_* ids in on-screen order.
    //
    // Garmin Connect's settings screen has no way to cap how many
    // dropdowns pick the same row, so the cap is enforced here: once a
    // row holds MAX_PER_ROW items, any further item placed in it is
    // dropped (earlier items in ITEM_* order win) and `overflowed` is
    // true so the view can tell the runner why something is missing.
    //
    // The top row is never left empty: if only bottom items are chosen
    // they move up and take the whole field, and if nothing is chosen at
    // all Current Pace is shown rather than a blank screen.
    function buildRows() as Array {
        var top = [] as Array<Number>;
        var bottom = [] as Array<Number>;
        var overflowed = false;
        for (var i = 0; i < ITEM_COUNT; i += 1) {
            var pos = Properties.getValue("p" + i);
            var row = (pos == POS_TOP) ? top : ((pos == POS_BOTTOM) ? bottom : null);
            if (row == null) {
                continue;
            }
            if (row.size() < MAX_PER_ROW) {
                row.add(i);
            } else {
                overflowed = true;
            }
        }
        if (top.size() == 0) {
            top = bottom;
            bottom = [] as Array<Number>;
        }
        if (top.size() == 0) {
            top.add(ITEM_CURRENT);
        }
        return [top, bottom, overflowed];
    }

    function getShowProgressRing() as Boolean {
        var v = Properties.getValue(PROP_SHOW_PROGRESS_RING);
        return (v == null) ? true : v;
    }

    function getHighlightDelta() as Boolean {
        var v = Properties.getValue(PROP_HIGHLIGHT_DELTA);
        return (v == null) ? false : v;
    }

    // Forces the field's background to black or white regardless of the
    // watch's own field/theme background - phone-configured only, since
    // it's a display preference rather than a race parameter. Defaults
    // to black: most Garmin watch UIs (and this field's own color
    // choices) are designed against a black background first.
    function getBackgroundMode() as Number {
        var v = Properties.getValue(PROP_BACKGROUND_MODE);
        return (v == null) ? BACKGROUND_BLACK : v.toNumber();
    }

    // On-device pace alerts: off by default (opt-in). Can be switched
    // on/off from the phone or the watch's RacePace settings menu - see
    // RacePaceFieldView for the alert state machine itself.
    function getAlertsEnabled() as Boolean {
        var v = Properties.getValue(PROP_ALERTS_ENABLED);
        return (v == null) ? false : v;
    }

    function setAlertsEnabled(enabled as Boolean) as Void {
        Properties.setValue(PROP_ALERTS_ENABLED, enabled);
    }

    // How many continuous seconds behind target pace before the first
    // alert fires.
    function getAlertThresholdSec() as Number {
        var v = Properties.getValue(PROP_ALERT_THRESHOLD_SEC);
        if (v == null || v <= 0) {
            return 15;
        }
        return v.toNumber();
    }

    // Distance between rolling current-pace checkpoints, in meters -
    // smaller reacts faster but shows more raw GPS jitter, larger is
    // smoother but laggier. Phone-configured only, since it's a
    // display-smoothing preference, not a race parameter.
    function getPaceSmoothingM() as Float {
        var v = Properties.getValue(PROP_PACE_SMOOTHING_M);
        if (v == null || v <= 0) {
            return 100.0;
        }
        return v.toFloat();
    }

    function setRaceDistanceM(meters as Float) as Void {
        Properties.setValue(PROP_DISTANCE_M, meters);
        Properties.setValue(PROP_DISTANCE_DISPLAY, meters / unitDistanceMeters());
    }

    function setFinishTimeSec(seconds as Number) as Void {
        Properties.setValue(PROP_FINISH_SEC, seconds);
        Properties.setValue(PROP_FINISH_MIN, seconds / 60);
    }

    function setUnits(units as Number) as Void {
        Properties.setValue(PROP_UNITS, units);
        // Re-derive the display distance in the newly selected unit so
        // the phone-side field stays consistent with the canonical meters.
        Properties.setValue(PROP_DISTANCE_DISPLAY, getRaceDistanceM() / unitDistanceMeters());
    }

    function unitDistanceMeters() as Float {
        return (getUnits() == UNITS_MILES) ? METERS_PER_MILE : METERS_PER_KM;
    }

    function unitLabel() as String {
        return (getUnits() == UNITS_MILES) ? "mi" : "km";
    }

    // Target pace in seconds per display-unit (per km or per mile).
    function targetPaceSecPerUnit() as Float {
        var distanceM = getRaceDistanceM();
        if (distanceM <= 0) {
            return 0.0;
        }
        var unitsCount = distanceM / unitDistanceMeters();
        if (unitsCount <= 0) {
            return 0.0;
        }
        return getFinishTimeSec() / unitsCount;
    }

    // Pace in seconds per display-unit, from a distance/time window (e.g.
    // the last ~100m). Used instead of raw instantaneous speed to smooth
    // out GPS jitter while still updating every second.
    function paceSecPerUnitFromWindow(distanceM as Float, timeSec as Float) as Float {
        if (distanceM <= 0 || timeSec <= 0) {
            return 0.0;
        }
        var unitsCount = distanceM / unitDistanceMeters();
        if (unitsCount <= 0) {
            return 0.0;
        }
        return timeSec / unitsCount;
    }

    // Positive => running slower than target (behind); negative => ahead.
    function paceDeltaSec(currentPaceSec as Float, targetPaceSec as Float) as Float {
        if (currentPaceSec <= 0 || targetPaceSec <= 0) {
            return 0.0;
        }
        return currentPaceSec - targetPaceSec;
    }

    // Positive => projected to finish slower than goal (behind); negative
    // => projected to finish faster (ahead). Distinct from paceDeltaSec:
    // this is "will I actually hit my goal at this rate" rather than
    // "am I running the right pace right now" - it reflects the whole
    // race so far, not just the current instant.
    function finishDeltaSec(projectedFinishSec as Number) as Number {
        var targetFinishSec = getFinishTimeSec();
        if (projectedFinishSec <= 0 || targetFinishSec <= 0) {
            return 0;
        }
        return projectedFinishSec - targetFinishSec;
    }

    // Projected finish time (seconds) based on elapsed distance/time and
    // current pace, blended with target pace for the remaining distance.
    function projectedFinishSec(elapsedDistanceM as Float or Null, elapsedTimeSec as Float or Null, currentPaceSec as Float) as Number {
        var distanceM = getRaceDistanceM();
        if (elapsedDistanceM == null || elapsedTimeSec == null || elapsedDistanceM <= 0 || distanceM <= 0) {
            return getFinishTimeSec();
        }
        if (elapsedDistanceM >= distanceM) {
            return elapsedTimeSec.toNumber();
        }
        var remainingM = distanceM - elapsedDistanceM;
        var paceSecPerUnit = currentPaceSec;
        if (paceSecPerUnit <= 0) {
            paceSecPerUnit = targetPaceSecPerUnit();
        }
        var remainingUnits = remainingM / unitDistanceMeters();
        var remainingSec = remainingUnits * paceSecPerUnit;
        return (elapsedTimeSec + remainingSec).toNumber();
    }

    // Formats seconds-per-unit pace as M:SS.
    function formatPace(paceSec as Float) as String {
        if (paceSec <= 0 || paceSec.toNumber() > 5999) {
            return "--:--";
        }
        var totalSec = paceSec.toNumber();
        var mins = totalSec / 60;
        var secs = totalSec % 60;
        return mins.format("%d") + ":" + secs.format("%02d");
    }

    // Formats the magnitude of a pace delta as e.g. "0:07" - no sign,
    // since direction is shown separately (an arrow, colored red/green)
    // rather than a +/- character. A leading sign glyph isn't a proper
    // first-class character in the FONT_NUMBER_* fonts (see
    // RacePaceFieldView.VALUE_FONTS), which was throwing off
    // getTextDimensions()/TEXT_JUSTIFY_CENTER and forcing this column
    // onto a separate, smaller font ladder just to stay centered.
    // Dropping the sign lets it use the same big number fonts as
    // everything else.
    function formatPaceDelta(deltaSec as Float) as String {
        var absSec = (deltaSec > 0) ? deltaSec.toNumber() : (-deltaSec).toNumber();
        var mins = absSec / 60;
        var secs = absSec % 60;
        return mins.format("%d") + ":" + secs.format("%02d");
    }

    // Formats the magnitude of a finish-time delta as e.g. "12:30" or
    // "1:05:00" - see formatPaceDelta for why there's no sign. Unlike a
    // pace delta this can run well past 59 minutes, so it rolls over
    // into H:MM:SS once it reaches an hour.
    function formatFinishDelta(deltaSec as Number) as String {
        var absSec = (deltaSec > 0) ? deltaSec : -deltaSec;
        return formatDuration(absSec);
    }

    // Formats seconds as H:MM:SS (or M:SS if under an hour).
    function formatDuration(totalSeconds as Number) as String {
        if (totalSeconds == null || totalSeconds <= 0) {
            return "--:--";
        }
        var hours = totalSeconds / 3600;
        var mins = (totalSeconds % 3600) / 60;
        var secs = totalSeconds % 60;
        if (hours > 0) {
            return hours.format("%d") + ":" + mins.format("%02d") + ":" + secs.format("%02d");
        }
        return mins.format("%d") + ":" + secs.format("%02d");
    }

    // Which HR zone (1-5) a heart rate falls in, or 0 if there's no
    // reading or no zones. Below zone 1 counts as zone 1, so an easy
    // warm-up still gets a colour rather than looking broken. `zones` is
    // UserProfile.getHeartRateZones() output:
    // [zone 1 min, zone 1 max, zone 2 max, zone 3 max, zone 4 max, zone 5 max].
    function heartRateZone(hr as Number?, zones as Array<Number>?) as Number {
        if (hr == null || hr <= 0 || zones == null || zones.size() < 6) {
            return 0;
        }
        for (var z = 1; z <= 4; z += 1) {
            if (hr <= zones[z]) {
                return z;
            }
        }
        return 5;
    }

    // Garmin-style zone colours: grey, blue, green, orange, red.
    function heartRateZoneColor(zone as Number) as Number {
        if (zone == 1) {
            return 0xAAAAAA;
        } else if (zone == 2) {
            return 0x00AAFF;
        } else if (zone == 3) {
            return 0x00AA00;
        } else if (zone == 4) {
            return 0xFF5500;
        }
        return 0xFF0000;
    }

    // White text on dark backgrounds, black on light ones, using
    // perceived brightness (ITU-R BT.601 weights, scaled by 1000). The
    // cut-off sits low enough that the mid-bright zone colours - blue
    // (zone 2, ~129) and orange (zone 4, ~126) - get black text, which
    // is far easier to read mid-run than white on those. Green (~100)
    // and red (~76) stay white.
    function contrastTextColor(bgColor as Number) as Number {
        var r = (bgColor >> 16) & 0xFF;
        var g = (bgColor >> 8) & 0xFF;
        var b = bgColor & 0xFF;
        var brightness = (r * 299 + g * 587 + b * 114) / 1000;
        return (brightness > 115) ? 0x000000 : 0xFFFFFF;
    }

    // Short on-screen label for each item, indexed by ITEM_* id. Split
    // Pace's label is the unit ("KM"/"MI"), so it's filled in by
    // itemLabel().
    const ITEM_LABELS = ["CUR", "AVG", "", "TGT", "+/-", "FIN+/-", "FINISH", "DIST", "TIME", "HR", "AVG HR"] as Array<String>;

    function itemLabel(item as Number) as String {
        return (item == ITEM_SPLIT) ? unitLabel().toUpper() : ITEM_LABELS[item];
    }

    // Distance covered as a bare number in the display unit, e.g. "5.23"
    // - no unit suffix, since the large number fonts have no letters.
    function formatDistanceValue(meters as Float?) as String {
        if (meters == null || meters < 0) {
            return "--";
        }
        return (meters / unitDistanceMeters()).format("%.2f");
    }

    // Formats a distance in meters using the configured display unit.
    function formatDistance(meters as Float) as String {
        var units = meters / unitDistanceMeters();
        return units.format("%.2f") + " " + unitLabel();
    }

    // Converts the phone-facing display properties (raceDistanceDisplay
    // in whichever unit distanceUnits currently selects, finishTimeMin in
    // minutes) into the canonical properties the rest of the app uses.
    // Called from AppBase.onSettingsChanged() after a Garmin Connect
    // Mobile / Garmin Express save.
    function applyDisplayProperties() as Void {
        var displayDistance = Properties.getValue(PROP_DISTANCE_DISPLAY);
        if (displayDistance != null && displayDistance > 0) {
            setRaceDistanceM(displayDistance.toFloat() * unitDistanceMeters());
        }

        var displayMinutes = Properties.getValue(PROP_FINISH_MIN);
        if (displayMinutes != null && displayMinutes > 0) {
            setFinishTimeSec(displayMinutes.toNumber() * 60);
        }
    }
}
