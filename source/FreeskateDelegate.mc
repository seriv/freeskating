using Toybox.WatchUi;
using Toybox.Lang;

// Button mapping:
//   Select        -> start / pause / resume
//   Back          -> lap while recording; stop + save while paused;
//                    exits the app (default platform behavior) when
//                    ready/stopped, since there's no unsaved recording to
//                    protect at that point
//   Next/Prev page -> reserved for screen scrolling; deliberately a no-op here
//                     (this app has only one screen, and these must NOT also
//                     trigger lap/stop -- confirmed on real hardware that they
//                     otherwise read as a confusing duplicate of the lap button)
//
// Mirrors native Garmin activity apps: Select toggles recording/paused, and
// stopping requires pausing first -- this two-step avoids ending a recording
// with one accidental press. FreeskateView shows on-screen hints for which
// button does what in each state so this isn't something the user has to
// remember.
//
// A previous version of this file made onBack() always return true (never
// falling through to the platform's default "exit app" handling), because
// that path reproducibly crashed in the desktop Connect IQ *simulator*. That
// was never confirmed on real hardware, and it had the side effect of
// removing the only way to exit the app at all -- on the real watch too,
// leaving no way back to the watch face short of a reboot. Returning false
// from READY/STOPPED (letting the platform exit) restores that path; if this
// turns out to crash on real hardware as well, this needs a different fix,
// but there's no unsaved recording at risk in those two states either way.
class FreeskateDelegate extends WatchUi.BehaviorDelegate {

    private var mController as ActivityController;

    function initialize(controller as ActivityController) {
        BehaviorDelegate.initialize();
        mController = controller;
    }

    function onSelect() as Lang.Boolean {
        var state = mController.getState();
        if (state == ActivityController.STATE_READY || state == ActivityController.STATE_STOPPED) {
            mController.start();
        } else if (state == ActivityController.STATE_RECORDING) {
            mController.pause();
        } else if (state == ActivityController.STATE_PAUSED) {
            mController.resume();
        }
        WatchUi.requestUpdate();
        return true;
    }

    function onBack() as Lang.Boolean {
        var state = mController.getState();
        if (state == ActivityController.STATE_RECORDING) {
            mController.addLap();
            WatchUi.requestUpdate();
            return true;
        }
        if (state == ActivityController.STATE_PAUSED) {
            mController.stopAndSave();
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    function onNextPage() as Lang.Boolean {
        return true;
    }

    function onPreviousPage() as Lang.Boolean {
        return true;
    }

    function onMenu() as Lang.Boolean {
        return true;
    }

    function onNextMode() as Lang.Boolean {
        return true;
    }

    function onPreviousMode() as Lang.Boolean {
        return true;
    }
}
