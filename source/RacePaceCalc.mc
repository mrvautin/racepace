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
    const PROP_SHOW_CURRENT = "showCurrentPace";
    const PROP_SHOW_TARGET = "showTargetPace";
    const PROP_SHOW_DELTA = "showDelta";
    const PROP_SHOW_FINISH = "showProjectedFinish";
    const PROP_SHOW_AVERAGE = "showAveragePace";
    const PROP_SHOW_SPLIT = "showSplitPace";
    const PROP_SHOW_FINISH_DELTA = "showFinishDelta";
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

    function getShowCurrentPace() as Boolean {
        var v = Properties.getValue(PROP_SHOW_CURRENT);
        return (v == null) ? true : v;
    }

    function getShowTargetPace() as Boolean {
        var v = Properties.getValue(PROP_SHOW_TARGET);
        return (v == null) ? false : v;
    }

    function getShowDelta() as Boolean {
        var v = Properties.getValue(PROP_SHOW_DELTA);
        return (v == null) ? true : v;
    }

    function getShowProjectedFinish() as Boolean {
        var v = Properties.getValue(PROP_SHOW_FINISH);
        return (v == null) ? true : v;
    }

    function getShowAveragePace() as Boolean {
        var v = Properties.getValue(PROP_SHOW_AVERAGE);
        return (v == null) ? true : v;
    }

    function getShowSplitPace() as Boolean {
        var v = Properties.getValue(PROP_SHOW_SPLIT);
        return (v == null) ? false : v;
    }

    function getShowFinishDelta() as Boolean {
        var v = Properties.getValue(PROP_SHOW_FINISH_DELTA);
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

    // On-device pace alerts: off by default (opt-in). Phone-configured
    // only - see RacePaceFieldView for the alert state machine itself.
    function getAlertsEnabled() as Boolean {
        var v = Properties.getValue(PROP_ALERTS_ENABLED);
        return (v == null) ? false : v;
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
