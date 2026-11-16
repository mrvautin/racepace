import Toybox.Activity;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Compact race data field: a top row and a bottom row of up to three
// values each. No cycling/tap dependency, since data fields don't
// reliably receive tap input - everything worth seeing mid-run is on
// screen together.
//
// Which values show, and in which row, is chosen per value in Garmin
// Connect Mobile/Express (the pos* properties - see
// RacePaceCalc.buildRows()). Hidden values free their space for
// whatever's left, rather than leaving a blank gap.
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
    private var _distanceM as Float?;
    private var _timerSec as Number?;

    // Row layout (lists of RacePaceCalc.ITEM_* ids), rebuilt from the
    // phone settings whenever they change (RacePaceCalc.settingsVersion).
    private var _top as Array<Number> = [] as Array<Number>;
    private var _bottom as Array<Number> = [] as Array<Number>;
    private var _layoutVersion as Number = -1;
    private var _finishDeltaShown as Boolean = false;
    // Set when the settings put more than MAX_PER_ROW values in a row;
    // the warning alert is shown from compute() and this is cleared.
    private var _layoutWarnPending as Boolean = false;

    // Heart rate (bpm, null when there's no reading) and the user's HR
    // zone boundaries, loaded once on first use - zones only change in
    // the user profile, not mid-activity.
    private var _heartRate as Number?;
    private var _avgHeartRate as Number?;

    // Progress ring: fraction of the race distance covered, and where
    // goal pace would have you by now (elapsed time / goal time). Both
    // clamped to 0..1.
    // Colours for the current frame, set at the top of onUpdate() and
    // shared by the drawing helpers.
    private var _onWhite as Boolean = false;
    private var _bgColor as Number = 0x000000;
    private var _fgColor as Number = 0xFFFFFF;
    private var _labelColor as Number = 0xAAAAAA;
    private var _aheadColor as Number = 0x00FF00;
    private var _behindColor as Number = 0xFF0000;

    // Layout box for the current frame (inside the progress ring when
    // it's drawn) and where the top band ends. Set in onUpdate().
    private var _ox as Float = 0.0;
    private var _oy as Float = 0.0;
    private var _w as Float = 0.0;
    private var _h as Float = 0.0;
    private var _topBandBottom as Float = 0.0;
    // Whether this field fills the whole round screen, so the usable
    // width at any height follows the circle (see chordWidth()).
    private var _isRound as Boolean = false;

    // Cached two-row fit (see drawTwoRows): what it was computed for,
    // each row's VALUE_FONTS index, and the gap either side of the divider.
    private var _twoRowKey as String = "";
    private var _twoRowFonts as Array<Number> = [0, 0] as Array<Number>;
    private var _twoRowGap as Float = 0.0;

    private var _progressFrac as Float = 0.0;
    private var _ghostFrac as Float = 0.0;
    private var _hrZones as Array<Number>?;
    private var _hrZonesLoaded as Boolean = false;

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
        _heartRate = info.currentHeartRate;
        // Garmin's own whole-activity average (excludes paused time).
        _avgHeartRate = info.averageHeartRate;
        if (!_hrZonesLoaded) {
            _hrZonesLoaded = true;
            _hrZones = loadHeartRateZones();
        }

        refreshLayout();

        var elapsedDistanceM = info.elapsedDistance;
        var elapsedTimeSec = (info.timerTime != null) ? info.timerTime / 1000.0 : null;
        _distanceM = elapsedDistanceM;
        _timerSec = (info.timerTime != null) ? info.timerTime / 1000 : null;

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

        _progressFrac = 0.0;
        _ghostFrac = 0.0;
        if (elapsedDistanceM != null && elapsedTimeSec != null) {
            _progressFrac = clampFrac(elapsedDistanceM / RacePaceCalc.getRaceDistanceM());
            _ghostFrac = clampFrac(elapsedTimeSec / RacePaceCalc.getFinishTimeSec());
        }

        _deltaSec = RacePaceCalc.paceDeltaSec(_currentPaceSec, _targetPaceSec);
        _projectedFinishSec = RacePaceCalc.projectedFinishSec(elapsedDistanceM, elapsedTimeSec, _currentPaceSec);
        _finishDeltaSec = RacePaceCalc.finishDeltaSec(_projectedFinishSec);

        if (RacePaceCalc.getAlertsEnabled()) {
            checkPaceAlert(elapsedTimeSec);
        } else {
            // Alerts can now be switched off mid-run from the watch, so
            // clear any half-finished episode - otherwise switching them
            // back on could fire straight away from a stale timer.
            _behindSinceSec = null;
            _lastAlertSec = null;
            _alertFiredOnce = false;
            _alertCutoff = false;
        }

        if (_layoutWarnPending) {
            _layoutWarnPending = false;
            showLayoutWarning();
        }
    }

    // Re-reads the row placement settings if they've changed since the
    // last build. Cheap to call every frame - it only does real work
    // after a settings change (and once on startup).
    private function refreshLayout() as Void {
        if (_layoutVersion == RacePaceCalc.settingsVersion) {
            return;
        }
        _layoutVersion = RacePaceCalc.settingsVersion;
        var rows = RacePaceCalc.buildRows();
        _top = rows[0] as Array<Number>;
        _bottom = rows[1] as Array<Number>;
        _finishDeltaShown = (_top.indexOf(RacePaceCalc.ITEM_FINISH_DELTA) >= 0) || (_bottom.indexOf(RacePaceCalc.ITEM_FINISH_DELTA) >= 0);
        if (rows[2] as Boolean) {
            _layoutWarnPending = true;
        }
    }

    // Tells the runner some values were dropped because a row had more
    // than MAX_PER_ROW - otherwise a value they picked in Garmin Connect
    // would just silently not appear. Shown once per settings change
    // (and once when the field starts, if the settings are still over).
    private function showLayoutWarning() as Void {
        if (!(WatchUi.DataField has :showAlert)) {
            return;
        }
        try {
            WatchUi.DataField.showAlert(new RacePaceAlertView("Max 3 values\nper row", Graphics.COLOR_YELLOW));
        } catch (e) {
            // Another alert is already up (e.g. a pace alert) - not worth
            // retrying; the layout itself has already been capped.
        }
    }

    private function loadHeartRateZones() as Array<Number>? {
        if (!(Toybox has :UserProfile) || !(UserProfile has :getHeartRateZones)) {
            return null;
        }
        var sport = UserProfile.HR_ZONE_SPORT_GENERIC;
        if (UserProfile has :getCurrentSport) {
            sport = UserProfile.getCurrentSport();
        }
        return UserProfile.getHeartRateZones(sport);
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
        _onWhite = (RacePaceCalc.getBackgroundMode() == RacePaceCalc.BACKGROUND_WHITE);
        _bgColor = _onWhite ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        _fgColor = _onWhite ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        // Plain LT_GRAY all but disappears on a white field background;
        // DK_GRAY is the equivalent low-emphasis label color there. Same
        // idea for the ahead/behind colors: full-saturation GREEN reads
        // poorly on white, so the dark variants stand in.
        _labelColor = _onWhite ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY;
        _aheadColor = _onWhite ? Graphics.COLOR_DK_GREEN : Graphics.COLOR_GREEN;
        _behindColor = _onWhite ? Graphics.COLOR_DK_RED : Graphics.COLOR_RED;

        dc.setColor(_fgColor, _bgColor);
        dc.clear();

        var fullW = dc.getWidth();
        var fullH = dc.getHeight();

        // Edge rings: race progress and the heart rate zone arc. Only
        // when this field fills the whole round screen (the 1-field
        // layout) - in a smaller slot the "edge" isn't the bezel and a
        // ring would look wrong. With both on, progress takes the top
        // half and heart rate the bottom; either alone keeps its own
        // shape. When drawn, everything else is laid out in a slightly
        // smaller square inside (_ox/_oy offset, _w/_h size), so no value
        // or label ever sits under a ring.
        var ringPen = 0;
        _isRound = fillsRoundScreen(fullW, fullH);
        var showProgress = RacePaceCalc.getShowProgressRing() && _isRound;
        var zones = _hrZones;
        var showHrArc = RacePaceCalc.getShowHeartRateArc() && _isRound && zones != null && zones.size() >= 6;
        if (showProgress || showHrArc) {
            ringPen = (fullW * 0.02).toNumber();
            if (ringPen < 4) {
                ringPen = 4;
            }
            if (showProgress) {
                drawProgressRing(dc, fullW, fullH, ringPen, showHrArc);
            }
            if (showHrArc) {
                drawHeartRateArc(dc, fullW, fullH, ringPen);
            }
        }
        // The layout keeps clear of the rings. The heart rate arc's
        // current zone is drawn extra thick (see drawHeartRateArc), so it
        // needs a wider margin.
        var inset = ringPen * (showHrArc ? 2.6 : 1.6);
        _ox = inset.toFloat();
        _oy = inset.toFloat();
        _w = (fullW - inset * 2).toFloat();
        _h = (fullH - inset * 2).toFloat();

        refreshLayout();

        // Drawing is split into separate functions because Monkey C
        // data fields get a small stack: one big function holding every
        // local overflowed as soon as it called a helper.
        if (_bottom.size() > 0) {
            drawTwoRows(dc);
        } else {
            // A single row gets the whole field to grow into.
            _topBandBottom = _oy + _h;
            drawTopRow(dc);
        }
    }

    // Two rows, mirrored around a centre divider: each row's values sit
    // right next to the divider, where a round screen is widest, and
    // their labels go on the outside (above the top row, below the
    // bottom row), where the screen narrows but labels are small.
    //
    // Columns are sized to their contents rather than split evenly
    // (a "24:13" needs far more room than a "162"), and checked against
    // the real width of the circle at the height they're drawn, so
    // nothing runs off the edge. With the same number of values in each
    // row, both rows use the same font. Once the font is settled, the
    // rows are spread apart as far as that font still fits, to use the
    // height rather than huddle around the divider.
    private function drawTwoRows(dc as Dc) as Void {
        var top = buildCells(_top);
        var bottom = buildCells(_bottom);
        var maxCols = (top.size() > bottom.size()) ? top.size() : bottom.size();
        var labelFont = (maxCols <= 2) ? Graphics.FONT_TINY : Graphics.FONT_XTINY;

        // Font and spacing only change when the shape of what's shown
        // does (templates, arrows), so they're cached between frames
        // instead of re-measuring everything every second.
        var key = cellsKey(top) + "|" + cellsKey(bottom) + "|" + _w;
        if (!key.equals(_twoRowKey)) {
            _twoRowKey = key;
            fitTwoRows(dc, top, bottom, labelFont);
        }

        var cy = _oy + _h / 2.0;
        var divH = (dc.getWidth() * 0.008).toNumber();
        if (divH < 2) {
            divH = 2;
        }
        // Divider doubles as an at-a-glance on-track signal: green if
        // you're projected to beat your goal, red if not (grey before
        // there's a projection).
        var divColor = _labelColor;
        if (_finishDeltaSec != 0) {
            divColor = (_finishDeltaSec > 0) ? _behindColor : _aheadColor;
        }
        dc.setColor(divColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(_ox + _w * 0.22, cy - divH / 2, _w * 0.56, divH, divH / 2);

        drawHalfRow(dc, top, VALUE_FONTS[_twoRowFonts[0]], labelFont, -1);
        drawHalfRow(dc, bottom, VALUE_FONTS[_twoRowFonts[1]], labelFont, 1);
    }

    // Picks each row's font (largest that fits; the smaller of the two
    // when both rows have the same column count) and then the widest
    // divider gap both rows still fit at. Results go in _twoRowFonts
    // and _twoRowGap.
    private function fitTwoRows(dc as Dc, top as Array<Array>, bottom as Array<Array>, labelFont as Graphics.FontType) as Void {
        var minGap = _h * 0.025;
        var topFont = fitHalfRowFont(dc, top, labelFont, minGap);
        var bottomFont = fitHalfRowFont(dc, bottom, labelFont, minGap);
        if (top.size() == bottom.size()) {
            // VALUE_FONTS is largest-first: the larger index is the
            // smaller font.
            if (bottomFont > topFont) {
                topFont = bottomFont;
            } else {
                bottomFont = topFont;
            }
        }
        _twoRowFonts = [topFont, bottomFont] as Array<Number>;

        var gap = minGap;
        var maxGap = _h * 0.10;
        var step = 2.0;
        while (gap + step <= maxGap
                && halfRowLayout(dc, top, VALUE_FONTS[topFont], labelFont, gap + step) != null
                && halfRowLayout(dc, bottom, VALUE_FONTS[bottomFont], labelFont, gap + step) != null) {
            gap += step;
        }
        _twoRowGap = gap;
    }

    // Index into VALUE_FONTS of the largest font a half-row fits at.
    private function fitHalfRowFont(dc as Dc, cells as Array<Array>, labelFont as Graphics.FontType, gap as Float) as Number {
        var last = VALUE_FONTS.size() - 1;
        for (var f = 0; f < last; f += 1) {
            if (halfRowLayout(dc, cells, VALUE_FONTS[f], labelFont, gap) != null) {
                return f;
            }
        }
        return last;
    }

    // Lays out one half-row at a value font and divider gap, or returns
    // null if it doesn't fit. Distances are from the screen centre:
    // [column x offsets, value centre y, label centre y, label half-width
    // available].
    private function halfRowLayout(dc as Dc, cells as Array<Array>, font as Graphics.FontType, labelFont as Graphics.FontType, gap as Float) as Array? {
        var n = cells.size();
        var widths = new [n] as Array<Float>;
        var rowH = 0.0;
        var sum = 0.0;
        for (var c = 0; c < n; c += 1) {
            widths[c] = cellWidth(dc, cells[c], font);
            sum += widths[c];
            var ch = cellHeight(cells[c], font);
            if (ch > rowH) {
                rowH = ch;
            }
        }
        var valueY = gap + rowH / 2.0;
        // The outer columns' far corners are what touch the bezel, so
        // the usable width is the circle's width at those corners.
        var usable = chordWidth(valueY + cellHeight(cells[0], font) / 2.0);
        var lastUsable = chordWidth(valueY + cellHeight(cells[n - 1], font) / 2.0);
        if (lastUsable < usable) {
            usable = lastUsable;
        }
        var colGap = _w * 0.035;
        var slack = usable - sum - (n - 1) * colGap;
        if (slack < 0) {
            return null;
        }

        var labelH = Graphics.getFontAscent(labelFont) * 0.8;
        var labelY = gap + rowH + gap * 0.6 + labelH / 2.0;
        var labelEdge = labelY + labelH / 2.0;
        if (labelEdge > _h / 2.0 * 0.99) {
            return null;
        }
        var labelHalf = chordWidth(labelEdge) / 2.0;

        // Spare width is shared evenly between the edges and the gaps.
        var spare = slack / (n + 1);
        var xs = new [n] as Array<Float>;
        var x = -usable / 2.0 + spare;
        var labelsW = 0.0;
        for (var c = 0; c < n; c += 1) {
            xs[c] = x + widths[c] / 2.0;
            x += widths[c] + colGap + spare;
            labelsW += labelWidth(dc, cells[c], labelFont) + 4;
        }
        if (labelsW > labelHalf * 2.0) {
            return null;
        }
        return [xs, valueY, labelY, labelHalf];
    }

    // Draws one half of a two-row layout: dir -1 = top (labels above
    // values), 1 = bottom (labels below values).
    private function drawHalfRow(dc as Dc, cells as Array<Array>, font as Graphics.FontType, labelFont as Graphics.FontType, dir as Number) as Void {
        var layout = halfRowLayout(dc, cells, font, labelFont, _twoRowGap);
        if (layout == null) {
            // Smallest font still didn't fit (very small field): fall
            // back to a minimal gap rather than drawing nothing.
            layout = halfRowLayout(dc, cells, font, labelFont, _h * 0.01);
            if (layout == null) {
                return;
            }
        }
        var xs = layout[0] as Array<Float>;
        var cx = _ox + _w / 2.0;
        var cy = _oy + _h / 2.0;
        var labelHalf = layout[3] as Float;
        var box = valueBoxSize(dc, font, "888");
        for (var c = 0; c < cells.size(); c += 1) {
            // Labels sit over/under their value, nudged inwards if
            // they'd otherwise cross the screen edge.
            var x = xs[c];
            var half = labelWidth(dc, cells[c], labelFont) / 2.0;
            var lx = x;
            if (lx - half < -labelHalf) {
                lx = -labelHalf + half;
            } else if (lx + half > labelHalf) {
                lx = labelHalf - half;
            }
            drawLabel(dc, cx + lx, cy + dir * (layout[2] as Float), labelFont, cells[c][0] as String, cells[c][3] as Number, cells[c][2] as Number);
            drawValue(dc, cells[c], cx + x, cy + dir * (layout[1] as Float), font, box);
        }
    }

    // Short string describing what a row's layout depends on, for the
    // two-row cache.
    private function cellsKey(cells as Array<Array>) as String {
        var k = "";
        for (var c = 0; c < cells.size(); c += 1) {
            k += (cells[c][0] as String) + (cells[c][5] as String) + (((cells[c][3] as Number) != 0) ? "^" : "") + ",";
        }
        return k;
    }

    // Width a value takes at a font: its template (which already has
    // room for a highlight box), or the heart rate zone box if wider.
    private function cellWidth(dc as Dc, cell as Array, font as Graphics.FontType) as Float {
        var w = dc.getTextDimensions(cell[5] as String, font)[0].toFloat();
        if (isHeartRate(cell)) {
            var boxW = valueBoxSize(dc, font, "888")[0].toFloat();
            if (boxW > w) {
                w = boxW;
            }
        }
        return w;
    }

    // Visible height of a value at a font: its box where it can have
    // one, otherwise just the digits.
    private function cellHeight(cell as Array, font as Graphics.FontType) as Float {
        if (isHeartRate(cell) || (cell[6] as Boolean)) {
            return boxHeight(font);
        }
        return digitHeight(font);
    }

    private function isHeartRate(cell as Array) as Boolean {
        var item = cell[7] as Number;
        return item == RacePaceCalc.ITEM_HEART_RATE || item == RacePaceCalc.ITEM_AVG_HEART_RATE;
    }

    // Garmin fonts' ascent includes empty space above the glyphs; the
    // digits themselves are about 80% of it.
    private function digitHeight(font as Graphics.FontType) as Float {
        return Graphics.getFontAscent(font) * 0.8;
    }

    // Usable width at a given distance from the centre line: the circle
    // chord on a full round screen (slightly inset from the edge),
    // otherwise most of the field's width.
    private function chordWidth(offset as Float) as Float {
        if (!_isRound) {
            return _w * 0.94;
        }
        var r = _w / 2.0 * 0.97;
        if (offset >= r) {
            return 0.0;
        }
        return 2.0 * Math.sqrt(r * r - offset * offset).toFloat();
    }

    // Width of a cell's label including its ahead/behind arrow.
    private function labelWidth(dc as Dc, cell as Array, font as Graphics.FontType) as Float {
        var tw = dc.getTextDimensions(cell[0] as String, font)[0].toFloat();
        if ((cell[3] as Number) != 0) {
            tw += Graphics.getFontAscent(font) * 0.6 * 1.45;
        }
        return tw;
    }

    // Everything needed to draw one value, as
    // [label, value, color, dir, hr, template, boxable, item]:
    //   dir      1 = ahead (up arrow), -1 = behind (down arrow), 0 = none
    //   hr       heart rate for the zone-colour box, or null
    //   template value with every digit as "8", for steady font fitting
    //   boxable  true when it gets the green/red Highlight box (drawn
    //            only while ahead/behind, i.e. dir != 0)
    // `alone` is true when it's the only value in its row (gets a longer
    // label where one exists).
    private function buildCell(item as Number, alone as Boolean) as Array {
        var label = RacePaceCalc.itemLabel(item);
        var value = "--";
        var color = _fgColor;
        var dir = 0;
        var hr = null;
        var boxed = false;

        if (item == RacePaceCalc.ITEM_CURRENT) {
            value = RacePaceCalc.formatPace(_currentPaceSec);
        } else if (item == RacePaceCalc.ITEM_AVERAGE) {
            value = RacePaceCalc.formatPace(_averagePaceSec);
        } else if (item == RacePaceCalc.ITEM_SPLIT) {
            value = RacePaceCalc.formatPace(_splitPaceSec);
        } else if (item == RacePaceCalc.ITEM_TARGET) {
            value = RacePaceCalc.formatPace(_targetPaceSec);
        } else if (item == RacePaceCalc.ITEM_DELTA) {
            value = RacePaceCalc.formatPaceDelta(_deltaSec);
            dir = directionOf(_deltaSec.toNumber());
            boxed = RacePaceCalc.getHighlightDelta();
        } else if (item == RacePaceCalc.ITEM_FINISH_DELTA) {
            value = RacePaceCalc.formatFinishDelta(_finishDeltaSec);
            dir = directionOf(_finishDeltaSec);
            boxed = RacePaceCalc.getHighlightDelta();
        } else if (item == RacePaceCalc.ITEM_FINISH) {
            value = RacePaceCalc.formatDuration(_projectedFinishSec);
            if (alone) {
                label = "PROJ. FINISH";
            }
            // With Finish +/- hidden, colour the projected finish (and
            // give it an arrow) so it still shows whether you're on track.
            if (!_finishDeltaShown) {
                dir = directionOf(_finishDeltaSec);
            }
        } else if (item == RacePaceCalc.ITEM_DISTANCE) {
            value = RacePaceCalc.formatDistanceValue(_distanceM);
            if (alone) {
                label = "DISTANCE";
            }
        } else if (item == RacePaceCalc.ITEM_ELAPSED) {
            var t = _timerSec;
            value = (t == null) ? "--:--" : ((t > 0) ? RacePaceCalc.formatDuration(t) : "0:00");
            if (alone) {
                label = "ELAPSED";
            }
        } else if (item == RacePaceCalc.ITEM_HEART_RATE) {
            hr = _heartRate;
            value = formatHeartRate(hr);
        } else {
            hr = _avgHeartRate;
            value = formatHeartRate(hr);
        }

        if (dir != 0) {
            color = (dir > 0) ? _aheadColor : _behindColor;
        }
        var template = widestDigits(value);
        if (item == RacePaceCalc.ITEM_DISTANCE && template.length() < 5) {
            // Keep the font steady as distance passes 10 km/mi.
            template = "88.88";
        } else if ((item == RacePaceCalc.ITEM_DELTA || item == RacePaceCalc.ITEM_FINISH_DELTA) && template.length() < 4) {
            // Under a minute a delta shows as bare seconds ("7"); size it
            // as "8:88" so the row's font doesn't jump at 10s and 60s.
            template = "8:88";
        }
        if (boxed) {
            // Box padding: one extra digit's width. Added whether or not
            // the box is currently drawn, so the font doesn't change the
            // moment you go from exactly on pace to ahead/behind.
            template += "8";
        }
        return [label, value, color, dir, hr, template, boxed, item];
    }

    private function buildCells(items as Array<Number>) as Array<Array> {
        var cells = [] as Array<Array>;
        for (var i = 0; i < items.size(); i += 1) {
            cells.add(buildCell(items[i], items.size() == 1));
        }
        return cells;
    }

    // True if any cell is a heart rate value - checked by item rather
    // than live reading, so the zone box's space is reserved even before
    // the first reading lands and the font doesn't shrink when it does.
    private function hasHeartRate(cells as Array<Array>) as Boolean {
        for (var i = 0; i < cells.size(); i += 1) {
            if (isHeartRate(cells[i])) {
                return true;
            }
        }
        return false;
    }

    // Largest value font where every cell's template (and, if the row
    // has heart rate, its zone-colour box) fits maxW x maxH. All cells
    // in a row share one font so the row reads as a set, and it's fitted
    // to fixed widest-case templates rather than the live values, so it
    // doesn't flip size as digits change.
    private function fitRowFont(dc as Dc, cells as Array<Array>, maxW as Float, maxH as Float) as Graphics.FontType {
        var withHr = hasHeartRate(cells);
        for (var f = 0; f < VALUE_FONTS.size(); f += 1) {
            var font = VALUE_FONTS[f];
            var fits = true;
            for (var c = 0; c < cells.size(); c += 1) {
                var dims = dc.getTextDimensions(cells[c][5] as String, font);
                if (dims[0] > maxW || dims[1] > maxH) {
                    fits = false;
                    break;
                }
            }
            if (fits && withHr) {
                var box = valueBoxSize(dc, font, "888");
                fits = (box[0] <= maxW * 0.92) && (box[1] <= maxH);
            }
            if (fits) {
                return font;
            }
        }
        return Graphics.FONT_XTINY;
    }

    // Draws one cell: label (with arrow), then the value.
    private function drawCell(dc as Dc, cell as Array, cx as Numeric, labelY as Numeric, valueY as Numeric, labelFont as Graphics.FontType, valueFont as Graphics.FontType, hrBox as Array<Numeric>) as Void {
        drawLabel(dc, cx, labelY, labelFont, cell[0] as String, cell[3] as Number, cell[2] as Number);
        drawValue(dc, cell, cx, valueY, valueFont, hrBox);
    }

    // Draws a value, on its highlight box or heart rate zone box where
    // it has one.
    private function drawValue(dc as Dc, cell as Array, cx as Numeric, valueY as Numeric, valueFont as Graphics.FontType, hrBox as Array<Numeric>) as Void {
        var value = cell[1] as String;
        var color = cell[2] as Number;
        var dir = cell[3] as Number;
        if ((cell[6] as Boolean) && dir != 0) {
            color = drawDeltaBox(dc, cx, valueY, valueFont, value, dir, color);
        } else {
            var hr = cell[4] as Number?;
            var zone = (hr != null) ? RacePaceCalc.heartRateZone(hr, _hrZones) : 0;
            if (zone > 0) {
                // Zone-colour background behind the value. Fixed size
                // per font, so HR and AVG HR boxes match and don't
                // resize as the number changes.
                var zoneColor = RacePaceCalc.heartRateZoneColor(zone);
                var boxW = hrBox[0];
                var boxH = hrBox[1];
                dc.setColor(zoneColor, Graphics.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(cx - boxW / 2, valueY - boxH / 2, boxW, boxH, boxH * 0.30);
                color = RacePaceCalc.contrastTextColor(zoneColor);
            }
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, valueY, valueFont, value, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Single row (nothing placed in the bottom row): up to three
    // columns filling the whole field.
    private function drawTopRow(dc as Dc) as Void {
        var ox = _ox;
        var oy = _oy;
        var w = _w;
        var h = _h;
        var cells = buildCells(_top);
        var colCount = cells.size();

        var topBandBottom = _topBandBottom;
        // The top margin exists so a row's outer labels (near col1/
        // col3, close to the round bezel) don't clip under the curve.
        // That's only avoidable with exactly 1 column, which sits dead
        // center - 2+ columns still have labels off-center near the
        // edge and need the full margin, same as 3+. Wrongly shrinking
        // it for colCount == 2 was clipping "CUR"/"+/-" under the bezel.
        var topMarginFrac = (colCount == 1) ? 0.03 : 0.10;
        var topBandTop = oy + h * topMarginFrac;
        var bandHeight = topBandBottom - topBandTop;

        // With only 1-2 columns shown, width stops being the binding
        // constraint on font size well before height does, so fewer
        // columns get a taller height budget to grow the font into.
        var colWidth = w / colCount;
        // 3-column centers are spaced 0.30*w apart (20/50/80), tighter
        // than the even 0.333*w split colWidth implies - measure the
        // real gap so the font fit doesn't pick a font wider than the
        // actual spacing allows.
        var colSpacing = (colCount == 3) ? (w * 0.30) : colWidth;
        var valueHeightFrac = (colCount == 1) ? 0.62 : ((colCount == 2) ? 0.54 : 0.44);
        var topValueFont = fitRowFont(dc, cells, colSpacing * 0.90, bandHeight * valueHeightFrac);
        var hrBox = valueBoxSize(dc, topValueFont, "888");

        var tinyLabelFont = (colCount <= 2) ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        // Label sits near the top of the band; the value is vertically
        // centered in whatever's left underneath it, sized from the
        // font that was actually picked - not a fixed fraction of the
        // band, which let a single big value run past topBandBottom.
        var labelFontHeight = dc.getTextDimensions("A", tinyLabelFont)[1];
        var labelTop = topBandTop + bandHeight * 0.06;
        var labelH = labelTop + labelFontHeight / 2.0;

        var valueTop = labelTop + labelFontHeight + bandHeight * 0.04;
        var valueH = valueTop + (topBandBottom - valueTop) / 2.0;

        for (var i = 0; i < colCount; i += 1) {
            // A round screen's usable width narrows near the top edge -
            // with exactly 3 columns, pull the outer two in from the true
            // edges instead of splitting the width evenly; the middle
            // column stays dead center.
            var colCenter = ox + colWidth * (i + 0.5);
            if (colCount == 3) {
                if (i == 0) {
                    colCenter = ox + w * 0.20;
                } else if (i == 2) {
                    colCenter = ox + w * 0.80;
                }
            }
            drawCell(dc, cells[i], colCenter, labelH, valueH, tinyLabelFont, topValueFont, hrBox);
        }
    }

    private function clampFrac(v as Float) as Float {
        if (v < 0.0) {
            return 0.0;
        }
        return (v > 1.0) ? 1.0 : v;
    }

    // Seconds behind (positive) / ahead (negative) -> arrow direction:
    // 1 = ahead, -1 = behind, 0 = exactly on target or no data.
    private function directionOf(deltaSec as Number) as Number {
        if (deltaSec < 0) {
            return 1;
        }
        return (deltaSec > 0) ? -1 : 0;
    }

    // True when this field's drawing area is the whole round screen,
    // i.e. the 1-field layout.
    private function fillsRoundScreen(w as Number, h as Number) as Boolean {
        var ds = System.getDeviceSettings();
        return ds.screenShape == System.SCREEN_SHAPE_ROUND && w == ds.screenWidth && h == ds.screenHeight;
    }

    // Race progress ring: a faint track, an arc filling clockwise for
    // the distance covered (green if you're on course to beat your goal
    // time, red if not), and a dot where goal pace would have you right
    // now. The gap between the arc's end and the dot is how far ahead or
    // behind you are.
    //
    // Full circle starting at 12 o'clock, or - when `half` (the heart
    // rate arc has the bottom) - the top half from 9 o'clock to 3.
    //
    // drawArc degrees: 0 = 3 o'clock, counter-clockwise positive.
    private function drawProgressRing(dc as Dc, w as Number, h as Number, pen as Number, half as Boolean) as Void {
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - pen / 2 - 1;
        // Where the ring starts and how many degrees it covers. The half
        // ring stops a few degrees short of 9 and 3 o'clock, leaving a
        // visible gap before the heart rate arc.
        var startDeg = half ? 177 : 90;
        var spanDeg = half ? 174 : 360;

        dc.setPenWidth(pen);
        dc.setColor(_onWhite ? 0xAAAAAA : 0x555555, Graphics.COLOR_TRANSPARENT);
        if (half) {
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, startDeg, startDeg - spanDeg);
        } else {
            dc.drawCircle(cx, cy, r);
        }

        if (_progressFrac > 0.0) {
            dc.setColor((_finishDeltaSec > 0) ? _behindColor : _aheadColor, Graphics.COLOR_TRANSPARENT);
            if (_progressFrac >= 0.999 && !half) {
                dc.drawCircle(cx, cy, r);
            } else {
                var endDeg = startDeg - (_progressFrac * spanDeg).toNumber();
                if (endDeg != startDeg) {
                    dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, startDeg, endDeg);
                }
            }
        }
        dc.setPenWidth(1);

        // Goal-pace marker: a dot ringed in the background colour so it
        // stands out against both the track and the progress arc.
        drawRingDot(dc, cx, cy, r, startDeg - _ghostFrac * spanDeg, pen * 0.95, pen * 0.65, _fgColor);
    }

    // Heart rate zone arc around the bottom half, from 9 o'clock round
    // to 3: five segments in the zone colours (zone 1 on the left) at
    // the same thickness as the progress ring, the zone you're in drawn
    // much thicker, and a bar across the arc at your current heart rate.
    // Each zone gets an equal share of the arc, and the bar moves
    // proportionally through its zone.
    private function drawHeartRateArc(dc as Dc, w as Number, h as Number, pen as Number) as Void {
        var zones = _hrZones as Array<Number>;
        var cx = w / 2;
        var cy = h / 2;
        var r = cx - pen / 2 - 1;
        var hr = _heartRate;
        var hasHr = (hr != null && hr > 0);
        var zone = hasHr ? RacePaceCalc.heartRateZone(hr, zones) : 0;
        // The current zone is drawn much thicker than the rest - it
        // fills the wider margin onUpdate() leaves when the arc is on.
        var bold = (pen * 2.4).toNumber();
        var boldR = cx - bold / 2 - 1;

        // 183..357 degrees counter-clockwise: a 3 degree gap at each end
        // to match the progress ring, and 2 degrees between zones.
        var seg = 174.0 / 5;
        for (var z = 1; z <= 5; z += 1) {
            var start = (183 + (z - 1) * seg + 1).toNumber();
            var end = (183 + z * seg - 1).toNumber();
            dc.setColor(RacePaceCalc.heartRateZoneColor(z), Graphics.COLOR_TRANSPARENT);
            if (z == zone) {
                dc.setPenWidth(bold);
                dc.drawArc(cx, cy, boldR, Graphics.ARC_COUNTER_CLOCKWISE, start, end);
            } else {
                dc.setPenWidth(pen);
                dc.drawArc(cx, cy, r, Graphics.ARC_COUNTER_CLOCKWISE, start, end);
            }
        }
        dc.setPenWidth(1);

        if (!hasHr) {
            return;
        }
        // Position along the arc, 0..1: whole zones passed, plus how far
        // through the current one.
        var frac = 0.0;
        if (hr > zones[5]) {
            frac = 1.0;
        } else if (hr > zones[0]) {
            for (var z = 1; z <= 5; z += 1) {
                if (hr <= zones[z]) {
                    var lo = zones[z - 1];
                    var span = zones[z] - lo;
                    var within = (span > 0) ? (hr - lo).toFloat() / span : 0.0;
                    frac = ((z - 1) + within) / 5.0;
                    break;
                }
            }
        }

        // "You are here": a bar across the arc at your heart rate, from
        // the bezel to just past the thick zone's inner edge, in the
        // foreground colour (white on black, black on white). Drawn over
        // a slightly wider bar in the background colour, so it stays
        // distinct where it crosses the zone colour.
        var a = Math.toRadians(183 + frac * 174);
        var cosA = Math.cos(a);
        var sinA = Math.sin(a);
        var outer = cx - 1;
        // Sticks out just past the thick zone (2.4 x pen) but stays
        // inside the layout margin (2.6 x pen), so it never reaches the
        // labels.
        var inner = cx - 1 - pen * 3.0;
        var x1 = cx + outer * cosA;
        var y1 = cy - outer * sinA;
        var x2 = cx + inner * cosA;
        var y2 = cy - inner * sinA;
        var barW = pen;
        if (barW < 3) {
            barW = 3;
        }
        dc.setColor(_bgColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(barW + 4);
        dc.drawLine(x1, y1, x2, y2);
        dc.setColor(_fgColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(barW);
        dc.drawLine(x1, y1, x2, y2);
        dc.setPenWidth(1);
    }

    // A dot on a ring at `deg` (drawArc degrees): an outer disc in the
    // background colour, then an inner one in `color`.
    private function drawRingDot(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric, deg as Numeric, outer as Numeric, inner as Numeric, color as Number) as Void {
        var a = Math.toRadians(deg);
        var mx = cx + r * Math.cos(a);
        var my = cy - r * Math.sin(a);
        dc.setColor(_bgColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(mx, my, outer);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(mx, my, inner);
    }

    // Draws a centred label, with a small up (ahead) or down (behind)
    // triangle after it when dir != 0, in the value's colour.
    private function drawLabel(dc as Dc, cx as Numeric, cy as Numeric, font as Graphics.FontType, text as String, dir as Number, arrowColor as Number) as Void {
        var labelColor = _labelColor;
        if (dir == 0) {
            dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, cy, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        var textW = dc.getTextDimensions(text, font)[0];
        var size = Graphics.getFontAscent(font) * 0.6;
        var gap = size * 0.45;
        var left = cx - (textW + gap + size) / 2;
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, cy, font, text, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        var ax = left + textW + gap + size / 2;
        var half = size / 2;
        var pts = (dir > 0)
            ? [[ax, cy - half], [ax + half, cy + half], [ax - half, cy + half]]
            : [[ax - half, cy - half], [ax + half, cy - half], [ax, cy + half]];
        dc.setColor(arrowColor, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon(pts as Array<Graphics.Point2D>);
    }

    // Filled green (ahead) / red (behind) box behind a value, same
    // shape as the HR boxes. Palette-safe colours so it looks right on
    // MIP screens. Returns the text colour to draw the value in.
    private function drawDeltaBox(dc as Dc, cx as Numeric, cy as Numeric, font as Graphics.FontType, value as String, dir as Number, textColor as Number) as Number {
        var boxColor = (dir > 0) ? 0x00AA00 : 0xFF0000;
        var box = valueBoxSize(dc, font, widestDigits(value));
        var boxW = box[0];
        var boxH = box[1];
        dc.setColor(boxColor, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - boxW / 2, cy - boxH / 2, boxW, boxH, boxH * 0.30);
        return RacePaceCalc.contrastTextColor(boxColor);
    }

    // Width and height of a coloured box (HR zone or highlight) around
    // `text` at a font: snug padding around the visible digits, scaling
    // with the font but never below a few pixels, so small fonts don't
    // end up with digits touching the edge.
    private function valueBoxSize(dc as Dc, font as Graphics.FontType, text as String) as Array<Numeric> {
        var padX = Graphics.getFontAscent(font) * 0.2;
        if (padX < 5) {
            padX = 5;
        }
        return [dc.getTextDimensions(text, font)[0] + padX * 2, boxHeight(font)];
    }

    private function boxHeight(font as Graphics.FontType) as Float {
        var padY = Graphics.getFontAscent(font) * 0.18;
        if (padY < 4) {
            padY = 4;
        }
        return digitHeight(font) + padY * 2;
    }

    private function formatHeartRate(hr as Number?) as String {
        return (hr != null && hr > 0) ? hr.format("%d") : "--";
    }

    // Replaces every digit with "8" (the widest digit in Garmin's number
    // fonts), so text keeps its shape (e.g. M:SS vs H:MM:SS) but its
    // measured width no longer changes as the digits tick over.
    private function widestDigits(text as String) as String {
        var chars = text.toCharArray();
        var out = "";
        for (var i = 0; i < chars.size(); i += 1) {
            var c = chars[i];
            out += (c >= '0' && c <= '9') ? "8" : c.toString();
        }
        return out;
    }
}
