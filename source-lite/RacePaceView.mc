// LITE screen for watches that give data fields only 32 KB of memory
// (see monkey.jungle). The full screen in source-full/ doesn't fit
// there, so these watches keep this simpler layout: no progress ring,
// direction arrows or ahead/behind box. Shared logic (settings, pace
// maths, menus) lives in source/ and is used by both.
import Toybox.Activity;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.UserProfile;
import Toybox.WatchUi;

// Compact race data field: a top row and a bottom row of up to three
// values each, placed per value from Garmin Connect Mobile/Express (the
// pos* properties - see RacePaceCalc.buildRows()). Hidden values free
// their space for whatever's left, rather than leaving a blank gap.
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

    // Row layout (RacePaceCalc.ITEM_* ids), rebuilt whenever the phone
    // settings change. See the full view for details.
    private var _top as Array<Number> = [] as Array<Number>;
    private var _bottom as Array<Number> = [] as Array<Number>;
    private var _layoutVersion as Number = -1;
    private var _layoutWarnPending as Boolean = false;

    // Colours for the current frame, set at the top of onUpdate().
    private var _fgColor as Number = 0xFFFFFF;
    private var _aheadColor as Number = 0x00FF00;
    private var _behindColor as Number = 0xFF0000;
    private var _labelColor as Number = 0xAAAAAA;

    // Field size for the current frame, and whether it's the whole
    // round screen (so usable width follows the circle - chordWidth()).
    private var _w as Float = 0.0;
    private var _h as Float = 0.0;
    private var _isRound as Boolean = false;

    // Heart rate (bpm, null when there's no reading) and the user's HR
    // zone boundaries, loaded once on first use - zones only change in
    // the user profile, not mid-activity.
    private var _heartRate as Number?;
    private var _avgHeartRate as Number?;
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

        // Some values were dropped because a row had too many - say so
        // once, rather than a chosen value silently not appearing.
        if (_layoutWarnPending) {
            _layoutWarnPending = false;
            if (WatchUi.DataField has :showAlert) {
                try {
                    WatchUi.DataField.showAlert(new RacePaceAlertView("Max 3 values\nper row", Graphics.COLOR_YELLOW));
                } catch (e) {
                }
            }
        }
    }

    private function refreshLayout() as Void {
        if (_layoutVersion == RacePaceCalc.settingsVersion) {
            return;
        }
        _layoutVersion = RacePaceCalc.settingsVersion;
        var rows = RacePaceCalc.buildRows();
        _top = rows[0] as Array<Number>;
        _bottom = rows[1] as Array<Number>;
        if (rows[2] as Boolean) {
            _layoutWarnPending = true;
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

    // Memory note: this screen runs in 32 KB, with only a couple of KB
    // to spare. Values are worked out on demand while drawing (itemValue
    // etc.) rather than gathered into per-value arrays first, and the
    // layout is recomputed each frame rather than cached, since both of
    // those cost more memory than the full screen can afford to spend
    // here.
    public function onUpdate(dc as Dc) as Void {
        // Background is forced by the phone-configured Background
        // setting, not read from the watch's own field/theme background
        // (getBackgroundColor()) - that avoided a real bug where the
        // watch's actual background didn't match what this field could
        // reliably detect, leaving text unreadable on some devices.
        var onWhite = (RacePaceCalc.getBackgroundMode() == RacePaceCalc.BACKGROUND_WHITE);
        _fgColor = onWhite ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        // Plain LT_GRAY all but disappears on a white field background;
        // DK_GRAY is the equivalent low-emphasis label color there. Same
        // idea for the ahead/behind colors: full-saturation GREEN reads
        // poorly on white, so the dark variants stand in.
        _labelColor = onWhite ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY;
        _aheadColor = onWhite ? Graphics.COLOR_DK_GREEN : Graphics.COLOR_GREEN;
        _behindColor = onWhite ? Graphics.COLOR_DK_RED : Graphics.COLOR_RED;

        dc.setColor(_fgColor, onWhite ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        _w = w.toFloat();
        _h = h.toFloat();
        // All the lite watches are round, and a square field is the
        // whole screen (the 1-field layout). Checked this way because
        // System.getDeviceSettings() allocates more than this screen
        // has spare.
        _isRound = (w == h);

        refreshLayout();
        var top = _top;
        var bottom = _bottom;
        var n = (top.size() > bottom.size()) ? top.size() : bottom.size();
        var labelFont = (n <= 2) ? Graphics.FONT_TINY : Graphics.FONT_XTINY;
        if (bottom.size() == 0) {
            // One row: values just below the centre with labels above,
            // the pair centred on the screen.
            drawRow(dc, top, VALUE_FONTS[fitRow(dc, top, labelFont, 0)], labelFont, 0);
            return;
        }
        // Two rows, mirrored around a centre divider: values next to the
        // divider (where a round screen is widest), labels on the
        // outside. Rows with the same column count share a font.
        var tf = fitRow(dc, top, labelFont, -1);
        var bf = fitRow(dc, bottom, labelFont, 1);
        if (top.size() == bottom.size()) {
            // Largest-first ladder: larger index = smaller font.
            tf = (bf > tf) ? bf : tf;
            bf = tf;
        }
        dc.setColor(_fgColor, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(_w * 0.15, _h / 2, _w * 0.85, _h / 2);
        drawRow(dc, top, VALUE_FONTS[tf], labelFont, -1);
        drawRow(dc, bottom, VALUE_FONTS[bf], labelFont, 1);
    }

    // Vertical layout of a row, as signed distances from the centre
    // line towards the row's side: [value centre, label centre]. dir is
    // -1 for the top row, 1 for the bottom row, 0 for a single row.
    private function rowOffsets(rowH as Float, labelFont as Graphics.FontType, dir as Number) as Array<Float> {
        var gap = _h * 0.04;
        var labelH = Graphics.getFontAscent(labelFont) * 0.8;
        var valueOff = gap + rowH / 2.0;
        if (dir == 0) {
            valueOff = -(gap * 0.6 + labelH) / 2.0;
        }
        return [valueOff, valueOff + rowH / 2.0 + gap * 0.6 + labelH / 2.0] as Array<Float>;
    }

    // Index into VALUE_FONTS of the largest font a row fits in: values
    // within the circle's width at their outer corners, labels inside
    // the field vertically.
    private function fitRow(dc as Dc, items as Array<Number>, labelFont as Graphics.FontType, dir as Number) as Number {
        var last = VALUE_FONTS.size() - 1;
        var labelHalfH = Graphics.getFontAscent(labelFont) * 0.4;
        for (var f = 0; f < last; f += 1) {
            var font = VALUE_FONTS[f];
            var rowH = rowHeight(items, font);
            var off = rowOffsets(rowH, labelFont, dir);
            if (off[1] + labelHalfH <= _h * 0.495
                    && rowWidth(dc, items, font) <= rowUsable(items, font, off[0])) {
                return f;
            }
        }
        return last;
    }

    // Usable width for a row: the circle's width at the outer corners
    // of its first and last values, whichever is narrower.
    private function rowUsable(items as Array<Number>, font as Graphics.FontType, valueOff as Float) as Float {
        var y = valueOff.abs();
        var a = chordWidth(y + itemHeight(items[0], font) / 2.0);
        var b = chordWidth(y + itemHeight(items[items.size() - 1], font) / 2.0);
        return (a < b) ? a : b;
    }

    // Columns are sized to their contents; spare width is shared evenly
    // between the edges and the gaps.
    private function drawRow(dc as Dc, items as Array<Number>, font as Graphics.FontType, labelFont as Graphics.FontType, dir as Number) as Void {
        var n = items.size();
        var off = rowOffsets(rowHeight(items, font), labelFont, dir);
        var usable = rowUsable(items, font, off[0]);
        var spare = (usable - rowWidth(dc, items, font)) / (n + 1);
        if (spare < 0) {
            spare = 0;
        }
        var labelHalf = chordWidth(off[1] + Graphics.getFontAscent(labelFont) * 0.4) / 2.0;
        // A single row's labels go above it, like the top row's.
        var sign = (dir == 0) ? -1 : dir;
        var cx = _w / 2.0;
        var cy = _h / 2.0;
        var x = -usable / 2.0 + spare;
        for (var c = 0; c < n; c += 1) {
            var iw = itemWidth(dc, items[c], font);
            var vx = x + iw / 2.0;
            x += iw + _w * 0.035 + spare;
            // Label over/under its value, nudged inwards if it would
            // cross the screen edge.
            var half = dc.getTextWidthInPixels(itemLabel(items[c], n == 1), labelFont) / 2.0;
            var lx = vx;
            if (lx - half < -labelHalf) {
                lx = half - labelHalf;
            } else if (lx + half > labelHalf) {
                lx = labelHalf - half;
            }
            drawItem(dc, items[c], n == 1, cx + lx, cy + sign * off[1], cx + vx, cy + sign * off[0], labelFont, font);
        }
    }

    // Total width of a row's values plus the gaps between them.
    private function rowWidth(dc as Dc, items as Array<Number>, font as Graphics.FontType) as Float {
        var sum = 0.0;
        for (var c = 0; c < items.size(); c += 1) {
            sum += itemWidth(dc, items[c], font);
        }
        return sum + (items.size() - 1) * _w * 0.035;
    }

    private function rowHeight(items as Array<Number>, font as Graphics.FontType) as Float {
        var rowH = 0.0;
        for (var c = 0; c < items.size(); c += 1) {
            var ih = itemHeight(items[c], font);
            if (ih > rowH) {
                rowH = ih;
            }
        }
        return rowH;
    }

    // Width of a value at a font, fitted to a fixed widest-case
    // template (every digit as 8) so the font doesn't flip size as the
    // digits change - or its HR zone box, if wider.
    private function itemWidth(dc as Dc, item as Number, font as Graphics.FontType) as Float {
        var tpl = widestDigits(itemValue(item));
        if (item == RacePaceCalc.ITEM_DISTANCE && tpl.length() < 5) {
            // Keep the font steady as distance passes 10 km/mi.
            tpl = "88.88";
        }
        var w = dc.getTextWidthInPixels(tpl, font).toFloat();
        // Heart rate items (the last two ids) also need room for their
        // zone box.
        if (item >= RacePaceCalc.ITEM_HEART_RATE) {
            var boxW = hrBoxWidth(dc, font);
            if (boxW > w) {
                w = boxW;
            }
        }
        return w;
    }

    // Visible height: the digits (~80% of the ascent), plus padding for
    // heart rate's zone box.
    private function itemHeight(item as Number, font as Graphics.FontType) as Float {
        var a = Graphics.getFontAscent(font);
        return (item >= RacePaceCalc.ITEM_HEART_RATE) ? a * 1.16 + 4 : a * 0.8;
    }

    // HR zone box: three digits plus side padding.
    private function hrBoxWidth(dc as Dc, font as Graphics.FontType) as Float {
        return dc.getTextWidthInPixels("888", font) + Graphics.getFontAscent(font) * 0.4 + 6;
    }

    // Circle width at a distance from the centre line on a full round
    // screen (slightly inset), otherwise most of the field width.
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

    private function itemLabel(item as Number, alone as Boolean) as String {
        return (alone && item == RacePaceCalc.ITEM_FINISH) ? "PROJ. FINISH" : RacePaceCalc.itemLabel(item);
    }

    private function itemValue(item as Number) as String {
        if (item == RacePaceCalc.ITEM_CURRENT) {
            return RacePaceCalc.formatPace(_currentPaceSec);
        } else if (item == RacePaceCalc.ITEM_AVERAGE) {
            return RacePaceCalc.formatPace(_averagePaceSec);
        } else if (item == RacePaceCalc.ITEM_SPLIT) {
            return RacePaceCalc.formatPace(_splitPaceSec);
        } else if (item == RacePaceCalc.ITEM_TARGET) {
            return RacePaceCalc.formatPace(_targetPaceSec);
        } else if (item == RacePaceCalc.ITEM_DELTA) {
            return RacePaceCalc.formatPaceDelta(_deltaSec);
        } else if (item == RacePaceCalc.ITEM_FINISH_DELTA) {
            return RacePaceCalc.formatFinishDelta(_finishDeltaSec);
        } else if (item == RacePaceCalc.ITEM_FINISH) {
            return RacePaceCalc.formatDuration(_projectedFinishSec);
        } else if (item == RacePaceCalc.ITEM_DISTANCE) {
            return RacePaceCalc.formatDistanceValue(_distanceM);
        } else if (item == RacePaceCalc.ITEM_ELAPSED) {
            var t = _timerSec;
            return (t == null) ? "--:--" : ((t > 0) ? RacePaceCalc.formatDuration(t) : "0:00");
        }
        return formatHeartRate(itemHr(item));
    }

    private function itemHr(item as Number) as Number? {
        if (item == RacePaceCalc.ITEM_HEART_RATE) {
            return _heartRate;
        }
        return (item == RacePaceCalc.ITEM_AVG_HEART_RATE) ? _avgHeartRate : null;
    }

    // Draws an item's label at (lx, ly) and its value at (vx, vy): red/
    // green for ahead/behind, or on its HR zone-colour box.
    private function drawItem(dc as Dc, item as Number, alone as Boolean, lx as Numeric, ly as Numeric, vx as Numeric, vy as Numeric, labelFont as Graphics.FontType, font as Graphics.FontType) as Void {
        var center = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;
        dc.setColor(_labelColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(lx, ly, labelFont, itemLabel(item, alone), center);

        var color = _fgColor;
        var delta = 0;
        if (item == RacePaceCalc.ITEM_DELTA) {
            delta = _deltaSec;
        } else if (item == RacePaceCalc.ITEM_FINISH_DELTA) {
            delta = _finishDeltaSec;
        }
        if (delta != 0) {
            color = (delta > 0) ? _behindColor : _aheadColor;
        }
        var zone = RacePaceCalc.heartRateZone(itemHr(item), _hrZones);
        if (zone > 0) {
            // Zone-colour box behind the value, fixed size per font so
            // it doesn't resize as the number changes.
            var zoneColor = RacePaceCalc.heartRateZoneColor(zone);
            var boxW = hrBoxWidth(dc, font);
            var boxH = itemHeight(item, font);
            dc.setColor(zoneColor, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(vx - boxW / 2, vy - boxH / 2, boxW, boxH, boxH * 0.30);
            color = RacePaceCalc.contrastTextColor(zoneColor);
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(vx, vy, font, itemValue(item), center);
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
