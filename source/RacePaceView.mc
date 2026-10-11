import Toybox.Activity;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Compact race data field: current pace, average pace, target pace, and
// pace delta (color-coded ahead/behind) on top, projected finish time
// below. No cycling/tap dependency, since data fields don't reliably
// receive tap input - everything worth seeing mid-run is on screen
// together.
//
// Average pace, split pace, target pace, the pace delta column, the
// finish-time delta column, and projected finish time can each be
// hidden via Garmin Connect Mobile/Express (showAveragePace,
// showSplitPace, showTargetPace, showDelta, showFinishDelta,
// showProjectedFinish) - hidden fields free their space for whatever's
// left, rather than leaving a blank gap. Current Pace always shows.
class RacePaceFieldView extends WatchUi.DataField {

    // Largest-to-smallest so the fit search below picks the first (i.e.
    // biggest) font whose rendered width still clears the column.
    private const VALUE_FONTS = [
        Graphics.FONT_NUMBER_MEDIUM,
        Graphics.FONT_NUMBER_MILD,
        Graphics.FONT_LARGE,
        Graphics.FONT_MEDIUM,
        Graphics.FONT_SMALL,
        Graphics.FONT_TINY,
        Graphics.FONT_XTINY
    ] as Array<Graphics.FontType>;

    private var _currentPaceSec as Float = 0.0;
    private var _averagePaceSec as Float = 0.0;
    private var _targetPaceSec as Float = 0.0;
    private var _deltaSec as Float = 0.0;
    private var _projectedFinishSec as Number = 0;
    private var _finishDeltaSec as Number = 0;
    private var _splitPaceSec as Float = 0.0;

    private var _checkpointDistanceM as Float = 0.0;
    private var _checkpointTimeSec as Float = 0.0;

    // Marks the start of the current, in-progress km/mile, so Split
    // Pace can be computed live from here to now every second - reset
    // the moment each whole unit completes, to start timing the next one.
    private var _unitCheckpointDistanceM as Float = 0.0;
    private var _unitCheckpointTimeSec as Float = 0.0;

    // Pace-alert state machine (see checkPaceAlert()). All in elapsed
    // activity seconds, reset whenever the runner comes back on pace.
    private var _behindSinceSec as Float?;
    private var _lastAlertSec as Float?;
    private var _alertFiredOnce as Boolean = false;
    private var _alertCutoff as Boolean = false;

    private const ALERT_REPEAT_SEC = 60;
    private const ALERT_CUTOFF_SEC = 300;

    public function initialize() {
        DataField.initialize();
    }

    public function compute(info as Activity.Info) as Void {
        _targetPaceSec = RacePaceCalc.targetPaceSecPerUnit();

        var elapsedDistanceM = info.elapsedDistance;
        var elapsedTimeSec = (info.timerTime != null) ? info.timerTime / 1000.0 : null;

        if (elapsedDistanceM != null && elapsedTimeSec != null) {
            var checkpointMeters = RacePaceCalc.getPaceSmoothingM();
            var distanceSinceCheckpoint = elapsedDistanceM - _checkpointDistanceM;

            if (distanceSinceCheckpoint >= checkpointMeters) {
                // Rolled past the next smoothing-window mark: compute
                // pace over that window, then advance the checkpoint.
                var timeSinceCheckpoint = elapsedTimeSec - _checkpointTimeSec;
                _currentPaceSec = RacePaceCalc.paceSecPerUnitFromWindow(distanceSinceCheckpoint, timeSinceCheckpoint);
                _checkpointDistanceM = elapsedDistanceM;
                _checkpointTimeSec = elapsedTimeSec;
            } else if (distanceSinceCheckpoint > 0) {
                // Still within the current window: show pace over the
                // partial window so it's never stuck for the whole gap.
                var partialTime = elapsedTimeSec - _checkpointTimeSec;
                _currentPaceSec = RacePaceCalc.paceSecPerUnitFromWindow(distanceSinceCheckpoint, partialTime);
            }

            // Average pace over the whole activity so far - same
            // distance/time-window math as current pace, just windowed
            // over everything instead of the last checkpoint gap.
            _averagePaceSec = RacePaceCalc.paceSecPerUnitFromWindow(elapsedDistanceM, elapsedTimeSec);

            // Split Pace: live pace for the current, in-progress km/mile
            // - recomputed every second from the start of this unit to
            // now, same as Average but scoped to just the current split
            // instead of the whole activity. Once elapsed distance
            // crosses a whole unit, that split is done: reset the
            // checkpoint to here so the next unit starts timing at 0.
            var unitMeters = RacePaceCalc.unitDistanceMeters();
            var distanceSinceUnitCheckpoint = elapsedDistanceM - _unitCheckpointDistanceM;
            if (distanceSinceUnitCheckpoint >= unitMeters) {
                _unitCheckpointDistanceM = elapsedDistanceM;
                _unitCheckpointTimeSec = elapsedTimeSec;
                distanceSinceUnitCheckpoint = 0.0;
            }
            var timeSinceUnitCheckpoint = elapsedTimeSec - _unitCheckpointTimeSec;
            _splitPaceSec = RacePaceCalc.paceSecPerUnitFromWindow(distanceSinceUnitCheckpoint, timeSinceUnitCheckpoint);
        }

        _deltaSec = RacePaceCalc.paceDeltaSec(_currentPaceSec, _targetPaceSec);
        _projectedFinishSec = RacePaceCalc.projectedFinishSec(elapsedDistanceM, elapsedTimeSec, _currentPaceSec);
        _finishDeltaSec = RacePaceCalc.finishDeltaSec(_projectedFinishSec);

        if (RacePaceCalc.getAlertsEnabled()) {
            checkPaceAlert(elapsedTimeSec);
        }
    }

    // Pace-alert state machine. Tracks how long the runner has been
    // continuously behind target pace (_deltaSec > 0, which requires
    // both current and target pace to be valid - see paceDeltaSec):
    //   - First alert fires once behind-duration crosses the
    //     configured threshold (15/30/60s).
    //   - Further alerts repeat every ALERT_REPEAT_SEC (60s) while
    //     still behind, so it nags periodically rather than once.
    //   - Once behind-duration exceeds ALERT_CUTOFF_SEC (5 min), alerts
    //     stop for the rest of this behind-pace episode - if someone's
    //     deliberately backed off (hill, walk break), repeated nagging
    //     stops being useful.
    //   - Coming back on pace (_deltaSec <= 0) after at least one
    //     behind-pace alert fired triggers a single recovery alert and
    //     resets the whole state machine for the next episode.
    private function checkPaceAlert(elapsedTimeSec as Float?) as Void {
        if (elapsedTimeSec == null) {
            return;
        }

        if (_deltaSec > 0.0) {
            if (_behindSinceSec == null) {
                _behindSinceSec = elapsedTimeSec;
            }
            var behindDuration = elapsedTimeSec - _behindSinceSec;

            if (_alertCutoff) {
                return;
            }

            if (behindDuration > ALERT_CUTOFF_SEC) {
                _alertCutoff = true;
                return;
            }

            var thresholdSec = RacePaceCalc.getAlertThresholdSec();
            if (!_alertFiredOnce) {
                if (behindDuration >= thresholdSec) {
                    fireAlert(false);
                    _alertFiredOnce = true;
                    _lastAlertSec = elapsedTimeSec;
                }
            } else if (_lastAlertSec != null && (elapsedTimeSec - _lastAlertSec) >= ALERT_REPEAT_SEC) {
                fireAlert(false);
                _lastAlertSec = elapsedTimeSec;
            }
        } else {
            if (_alertFiredOnce) {
                fireAlert(true);
            }
            _behindSinceSec = null;
            _lastAlertSec = null;
            _alertFiredOnce = false;
            _alertCutoff = false;
        }
    }

    // Pushes the alert view and, where the device has a vibration
    // motor, a distinct haptic pattern per flavor so the two are
    // distinguishable without looking at the watch (most of these
    // devices can't reliably play tones - see Toybox.Attention docs -
    // so vibration is the only consistently available non-visual cue).
    private function fireAlert(backOnPace as Boolean) as Void {
        if (!(WatchUi.DataField has :showAlert)) {
            return;
        }
        var message = backOnPace ? "Back on pace" : "Behind pace";
        var color = backOnPace ? Graphics.COLOR_GREEN : Graphics.COLOR_RED;
        WatchUi.DataField.showAlert(new RacePaceAlertView(message, color));

        if (Toybox has :Attention) {
            if (Attention has :vibrate) {
                var profiles = backOnPace
                    ? [new Attention.VibeProfile(50, 400)]
                    : [new Attention.VibeProfile(100, 200), new Attention.VibeProfile(0, 150), new Attention.VibeProfile(100, 200)];
                Attention.vibrate(profiles as Array<Attention.VibeProfile>);
            }
        }
    }

    public function onUpdate(dc as Dc) as Void {
        // Background is forced by the phone-configured Background
        // setting, not read from the watch's own field/theme background
        // (getBackgroundColor()) - that avoided a real bug where the
        // watch's actual background didn't match what this field could
        // reliably detect, leaving text unreadable on some devices.
        var onWhite = (RacePaceCalc.getBackgroundMode() == RacePaceCalc.BACKGROUND_WHITE);
        var bgColor = onWhite ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        var fgColor = onWhite ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        // Plain LT_GRAY all but disappears on a white field background;
        // DK_GRAY is the equivalent low-emphasis label color there. Same
        // idea for the ahead/behind colors: full-saturation GREEN reads
        // poorly on white, so the dark variants stand in.
        var labelColor = onWhite ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY;
        var aheadColor = onWhite ? Graphics.COLOR_DK_GREEN : Graphics.COLOR_GREEN;
        var behindColor = onWhite ? Graphics.COLOR_DK_RED : Graphics.COLOR_RED;

        dc.setColor(fgColor, bgColor);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        var showCurrent = RacePaceCalc.getShowCurrentPace();
        var showAverage = RacePaceCalc.getShowAveragePace();
        var showSplit = RacePaceCalc.getShowSplitPace();
        var showTarget = RacePaceCalc.getShowTargetPace();
        var showDelta = RacePaceCalc.getShowDelta();
        var showFinishDelta = RacePaceCalc.getShowFinishDelta();
        var showFinish = RacePaceCalc.getShowProjectedFinish();

        // Never let every field end up hidden at once - a blank field
        // would be worse than a redundant Current Pace, so it's forced
        // back on if the user has switched off everything else too.
        if (!showCurrent && !showAverage && !showSplit && !showTarget && !showDelta && !showFinishDelta && !showFinish) {
            showCurrent = true;
        }

        // Garmin Connect Mobile's settings screen can't enforce a max
        // selection count - every toggle is independent. More than 3
        // top-row fields squeezes each one too small to read at a
        // glance (the field's whole purpose), so if more than 3 are on,
        // only the first 3 in this fixed priority order are shown; the
        // rest are silently dropped rather than cramming everything in.
        var allShow = [showCurrent, showDelta, showAverage, showTarget, showSplit, showFinishDelta] as Array<Boolean>;
        var shownCount = 0;
        for (var s = 0; s < allShow.size(); s += 1) {
            if (allShow[s]) {
                shownCount += 1;
                if (shownCount > 3) {
                    allShow[s] = false;
                }
            }
        }
        showCurrent = allShow[0];
        showDelta = allShow[1];
        showAverage = allShow[2];
        showTarget = allShow[3];
        showSplit = allShow[4];
        showFinishDelta = allShow[5];

        var topLabels = [] as Array<String>;
        var topValues = [] as Array<String>;
        var topColors = [] as Array<Number>;

        if (showCurrent) {
            topLabels.add("CUR");
            topValues.add(RacePaceCalc.formatPace(_currentPaceSec));
            topColors.add(fgColor);
        }

        if (showAverage) {
            topLabels.add("AVG");
            topValues.add(RacePaceCalc.formatPace(_averagePaceSec));
            topColors.add(fgColor);
        }

        if (showSplit) {
            topLabels.add(RacePaceCalc.unitLabel().toUpper());
            topValues.add(RacePaceCalc.formatPace(_splitPaceSec));
            topColors.add(fgColor);
        }

        if (showTarget) {
            topLabels.add("TGT");
            topValues.add(RacePaceCalc.formatPace(_targetPaceSec));
            topColors.add(fgColor);
        }

        if (showDelta) {
            var deltaColor = fgColor;
            if (_deltaSec != 0.0) {
                deltaColor = (_deltaSec > 0) ? behindColor : aheadColor;
            }
            topLabels.add("+/-");
            topValues.add(RacePaceCalc.formatPaceDelta(_deltaSec));
            topColors.add(deltaColor);
        }

        if (showFinishDelta) {
            var finishDeltaColor = fgColor;
            if (_finishDeltaSec != 0) {
                finishDeltaColor = (_finishDeltaSec > 0) ? behindColor : aheadColor;
            }
            topLabels.add("FIN+/-");
            topValues.add(RacePaceCalc.formatFinishDelta(_finishDeltaSec));
            topColors.add(finishDeltaColor);
        }

        var colCount = topLabels.size();

        // Reserve the bottom band only if Projected Finish is shown;
        // otherwise the top row gets the full height to grow into. A
        // plain 50/50 split, regardless of column count - varying this
        // by column count kept trading one bad case for another. The
        // divider line and the whole Projected Finish row are
        // positioned from this same value (never a separate hardcoded
        // fraction of h) so they always agree with where the top band
        // actually ends.
        var topBandBottom = showFinish ? (h * 0.50) : h;
        // The top margin exists so a row's outer labels (near col1/
        // col3, close to the round bezel) don't clip under the curve.
        // That's only avoidable with exactly 1 column, which sits dead
        // center - 2+ columns still have labels off-center near the
        // edge and need the full margin, same as 3+. Wrongly shrinking
        // it for colCount == 2 was clipping "CUR"/"+/-" under the bezel.
        var topMarginFrac = (colCount == 1) ? 0.03 : 0.10;
        var topBandTop = h * topMarginFrac;
        var bandHeight = topBandBottom - topBandTop;

        // With only 1-2 columns shown, width stops being the binding
        // constraint on font size well before height does (a single
        // "3:49" comfortably fits a half-screen-wide column at every
        // font size in the ladder), so fewer columns get a taller
        // height budget to grow the font into.
        var colWidth = w / colCount;
        // 3-column centers are spaced 0.30*w apart (20/50/80), tighter
        // than the even 0.333*w split colWidth implies - measure the
        // real gap so fitFont doesn't pick a font wider than the actual
        // spacing allows.
        var colSpacing = (colCount == 3) ? (w * 0.30) : colWidth;
        var valueMaxWidth = colSpacing * 0.90;
        var valueHeightFrac = (colCount == 1) ? 0.62 : ((colCount == 2) ? 0.54 : 0.44);
        var valueMaxHeight = bandHeight * valueHeightFrac;

        var tinyLabelFont = (colCount <= 2) ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        var topValueFont = fitFont(dc, topValues, valueMaxWidth, valueMaxHeight, VALUE_FONTS);

        // Label sits near the top of the band; the value is vertically
        // centered in whatever's left underneath it, sized from the
        // font that was actually picked - not a fixed fraction of the
        // band assumed before the font (and therefore its real glyph
        // height) was known. That fixed-fraction approach is what let a
        // single big value get positioned low enough to run past
        // topBandBottom and behind the divider/PROJ. FINISH row.
        var labelFontHeight = dc.getTextDimensions("A", tinyLabelFont)[1];
        var labelTop = topBandTop + bandHeight * 0.06;
        var labelH = labelTop + labelFontHeight / 2.0;

        var valueTop = labelTop + labelFontHeight + bandHeight * 0.04;
        var valueAreaHeight = topBandBottom - valueTop;
        var valueH = valueTop + valueAreaHeight / 2.0;

        for (var i = 0; i < colCount; i += 1) {
            // A round screen's usable width narrows near the top edge -
            // an even 1/6, 3/6, 5/6 split (colWidth * (i + 0.5)) puts
            // col1/col3 far enough into the curve at this height to
            // clip under the bezel. With exactly 3 columns, pull the
            // outer two in from the true edges instead of splitting the
            // width evenly; the middle column stays dead center.
            var colCenter = colWidth * (i + 0.5);
            if (colCount == 3) {
                if (i == 0) {
                    colCenter = w * 0.20;
                } else if (i == 2) {
                    colCenter = w * 0.80;
                }
            }
            dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCenter, labelH, tinyLabelFont, topLabels[i], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(topColors[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(colCenter, valueH, topValueFont, topValues[i], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        if (!showFinish) {
            return;
        }

        dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(w * 0.15, topBandBottom, w * 0.85, topBandBottom);

        // Bottom: projected finish time, full width (safe near the
        // bottom edge since it's centered and narrower than the row
        // above). Positioned as fractions of the space actually left
        // below topBandBottom (not of h), so this row stays correctly
        // placed under the divider wherever that divider ends up.
        var bottomBandHeight = h - topBandBottom;
        var finishLabelH = topBandBottom + bottomBandHeight * 0.24;
        var finishValueH = topBandBottom + bottomBandHeight * 0.64;
        var finishValue = RacePaceCalc.formatDuration(_projectedFinishSec);
        var finishFont = fitFont(dc, [finishValue], w * 0.85, bottomBandHeight * 0.56, VALUE_FONTS);

        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, finishLabelH, Graphics.FONT_XTINY, "PROJ. FINISH", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, finishValueH, finishFont, finishValue, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Picks the largest font in `fonts` under which every string in
    // `values` still fits within (maxWidth, maxHeight), so fewer visible
    // fields (or a wider field/bigger watch) render with bigger text
    // instead of the layout leaving space unused.
    private function fitFont(dc as Dc, values as Array<String>, maxWidth as Float, maxHeight as Float, fonts as Array<Graphics.FontType>) as Graphics.FontType {
        for (var i = 0; i < fonts.size(); i += 1) {
            var font = fonts[i];
            var fits = true;
            for (var j = 0; j < values.size(); j += 1) {
                var dims = dc.getTextDimensions(values[j], font);
                if (dims[0] > maxWidth || dims[1] > maxHeight) {
                    fits = false;
                    break;
                }
            }
            if (fits) {
                return font;
            }
        }
        return Graphics.FONT_XTINY;
    }
}
