using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Timer;
using Toybox.Activity;
using Toybox.System;
using Toybox.Position;

class FreeskateView extends WatchUi.View {

    // Gap between stacked text lines, in addition to each line's own font
    // height -- see drawLine(). Deliberately small; the constraint here is
    // fitting everything within the round enduro3 screen's safe vertical
    // band at all, not adding breathing room.
    private const LINE_GAP_PX = 2;

    private var mController as ActivityController;
    private var mUpdateTimer as Timer.Timer;

    function initialize(controller as ActivityController) {
        View.initialize();
        mController = controller;
        mUpdateTimer = new Timer.Timer();
    }

    function onShow() as Void {
        mUpdateTimer.start(method(:onUpdateTick), 1000, true);
    }

    function onHide() as Void {
        mUpdateTimer.stop();
    }

    function onUpdateTick() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;

        var info = mController.getActivityInfo();
        var elapsedSeconds = 0;
        var distanceMeters = 0.0;
        var speedMps = 0.0;
        var hr = 0;

        if (info != null) {
            if (info.timerTime != null) {
                elapsedSeconds = (info.timerTime as Lang.Number) / 1000;
            }
            if (info.elapsedDistance != null) {
                distanceMeters = info.elapsedDistance as Lang.Float;
            }
            if (info.currentSpeed != null) {
                speedMps = info.currentSpeed as Lang.Float;
            }
            if (info.currentHeartRate != null) {
                hr = info.currentHeartRate as Lang.Number;
            }
        }

        var hours = elapsedSeconds / 3600;
        var minutes = (elapsedSeconds % 3600) / 60;
        var seconds = elapsedSeconds % 60;
        var timeStr = Lang.format("$1$:$2$:$3$", [hours.format("%01d"), minutes.format("%02d"), seconds.format("%02d")]);

        var useStatute = System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE;
        var distanceVal = useStatute ? distanceMeters / 1609.344 : distanceMeters / 1000.0;
        var speedVal = useStatute ? speedMps * 2.23694 : speedMps * 3.6;
        var distanceUnitStr = useStatute ? " mi" : " km";
        var speedUnitStr = useStatute ? " mph" : " km/h";

        var zoneIndex = mController.getCurrentZoneIndex();
        var zoneStr = (zoneIndex == null) ? "--" : (zoneIndex + 1).format("%d");

        var skateDistanceVal = useStatute
            ? mController.getSkateDistanceMeters() / 1609.344
            : mController.getSkateDistanceMeters() / 1000.0;
        var avgSkateSpeedMps = mController.getAverageSkateSpeedMps();
        var avgSkateSpeedStr = "--";
        if (avgSkateSpeedMps != null) {
            var avgSkateSpeedVal = useStatute
                ? (avgSkateSpeedMps as Lang.Float) * 2.23694
                : (avgSkateSpeedMps as Lang.Float) * 3.6;
            avgSkateSpeedStr = avgSkateSpeedVal.format("%.1f");
        }

        var state = mController.getState();

        dc.setColor(gpsColor(mController.getGpsAccuracy()), Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centerX - width * 0.12, height * 0.06, height * 0.02);
        dc.setColor(skateStanceColor(mController.getCurrentlySkating(), mController.getRegularStance()), Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centerX + width * 0.12, height * 0.06, height * 0.02);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

        // Stacked from a running cursor based on each font's actual
        // rendered height (dc.getFontHeight()), not guessed fractions of
        // screen height -- a fixed-fraction layout previously overlapped
        // rows, confirmed via a real-device screenshot, since drawText()
        // anchors at the top of the text and FONT_NUMBER_MEDIUM/FONT_MEDIUM
        // are taller than the gaps that layout assumed. The enduro3 screen
        // is also round (280x280, circle inscribed in the square canvas),
        // so full-width lines additionally need to stay off the very top/
        // bottom, where the visible chord is narrower than the square
        // canvas and clips the sides -- confirmed via the same screenshot,
        // where a line at 93% of screen height got its right edge clipped.
        var y = height * 0.09;
        y = drawLine(dc, centerX, y, Graphics.FONT_XTINY, stateLabel(state));
        y = drawLine(dc, centerX, y, Graphics.FONT_NUMBER_MILD, timeStr);
        y = drawLine(dc, centerX, y, Graphics.FONT_SMALL,
            distanceVal.format("%.2f") + distanceUnitStr + " (Skt " + skateDistanceVal.format("%.2f") + ")");
        y = drawLine(dc, centerX, y, Graphics.FONT_SMALL,
            speedVal.format("%.1f") + speedUnitStr + " (AvgSkt " + avgSkateSpeedStr + ")");
        y = drawLine(dc, centerX, y, Graphics.FONT_MEDIUM, hr.format("%d") + " bpm  Z" + zoneStr);
        y = drawLine(dc, centerX, y, Graphics.FONT_XTINY, "Laps: " + mController.getLapCount().format("%d"));
    }

    // Draws one centered line and returns the y to start the next one at,
    // stacking by the font's actual height instead of a guessed constant.
    private function drawLine(dc as Graphics.Dc, centerX as Lang.Number, y as Lang.Float, font as Graphics.FontType, text as Lang.String) as Lang.Float {
        dc.drawText(centerX, y, font, text, Graphics.TEXT_JUSTIFY_CENTER);
        return y + dc.getFontHeight(font) + LINE_GAP_PX;
    }

    // Red until a fix attempt reports in, yellow for a weak/last-known fix,
    // green once it's good enough to trust for distance/speed.
    private function gpsColor(accuracy as Lang.Number?) as Graphics.ColorType {
        if (accuracy == null || accuracy == Position.QUALITY_NOT_AVAILABLE) {
            return Graphics.COLOR_RED;
        }
        if (accuracy == Position.QUALITY_USABLE || accuracy == Position.QUALITY_GOOD) {
            return Graphics.COLOR_GREEN;
        }
        return Graphics.COLOR_YELLOW;
    }

    // Single dot combining the skate/walk tag (Down/Up button) and, while
    // skating, the stance tag (Up long-press / pause-menu toggle): dark gray
    // for walking -- deliberately not red/yellow, since those already mean
    // "bad/not-ready" for the GPS dot and "walking" isn't an error condition
    // -- else red for regular / green for goofy, a mnemonic on the R/G
    // initials that also matches the regular_speed/goofy_speed chart colors
    // in fitContributions.xml. Stance only applies while skating (see
    // ActivityController), so this dot never needs to show both tags at
    // once -- skating collapses to exactly one of the two colors already
    // used for stance.
    private function skateStanceColor(skating as Lang.Boolean, regular as Lang.Boolean) as Graphics.ColorType {
        if (!skating) {
            return Graphics.COLOR_DK_GRAY;
        }
        return regular ? Graphics.COLOR_RED : Graphics.COLOR_GREEN;
    }

    private function stateLabel(state as Lang.Number) as Lang.String {
        if (state == ActivityController.STATE_READY) {
            return "READY";
        }
        if (state == ActivityController.STATE_RECORDING) {
            return "RECORDING";
        }
        if (state == ActivityController.STATE_PAUSED) {
            return "PAUSED";
        }
        return "STOPPED";
    }
}
