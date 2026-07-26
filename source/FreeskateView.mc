using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Timer;
using Toybox.Activity;
using Toybox.System;
using Toybox.Position;

class FreeskateView extends WatchUi.View {

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

        var state = mController.getState();

        dc.setColor(gpsColor(mController.getGpsAccuracy()), Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(centerX, height * 0.06, height * 0.02);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

        dc.drawText(centerX, height * 0.11, Graphics.FONT_XTINY, stateLabel(state), Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.22, Graphics.FONT_NUMBER_MEDIUM, timeStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.44, Graphics.FONT_MEDIUM, distanceVal.format("%.2f") + distanceUnitStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.57, Graphics.FONT_SMALL, speedVal.format("%.1f") + speedUnitStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.72, Graphics.FONT_MEDIUM, hr.format("%d") + " bpm  Z" + zoneStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.85, Graphics.FONT_XTINY, "Laps: " + mController.getLapCount().format("%d"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(centerX, height * 0.93, Graphics.FONT_XTINY, buttonHint(state), Graphics.TEXT_JUSTIFY_CENTER);
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

    private function buttonHint(state as Lang.Number) as Lang.String {
        if (state == ActivityController.STATE_READY) {
            return "Sel:start Bk:exit";
        }
        if (state == ActivityController.STATE_RECORDING) {
            return "Sel: pause  Bk: lap";
        }
        if (state == ActivityController.STATE_PAUSED) {
            return "Sel: resume  Bk: save";
        }
        return "Sel:new Bk:exit";
    }
}
