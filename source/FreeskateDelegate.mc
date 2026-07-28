using Toybox.WatchUi;
using Toybox.Lang;
using Toybox.Timer;

// Button mapping:
//   Select        -> start / pause / resume
//   Back          -> lap while recording; opens the pause menu while paused
//                     (also auto-opened after PAUSE_MENU_DELAY_MS of no
//                     input -- see startPauseMenuCountdown()); exits the app
//                     (default platform behavior) when ready/stopped, since
//                     there's no unsaved recording to protect at that point
//   Next/Prev page -> reserved for screen scrolling; deliberately a no-op here
//                     (this app has only one screen, and these must NOT also
//                     trigger lap/stop -- confirmed on real hardware that they
//                     otherwise read as a confusing duplicate of the lap button)
//
// Mirrors native Garmin activity apps: Select toggles recording/paused, and
// stopping goes through a pause menu (Resume/Save/Discard) -- like native
// apps, this is a two-step gate against ending a recording with one
// accidental press. FreeskateView shows on-screen hints for which button
// does what in each state so this isn't something the user has to remember.
// (A fourth "Resume Later" option was tried and removed -- see the comment
// on ActivityController for why it can't work on real hardware.)
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

    private const PAUSE_MENU_DELAY_MS = 5000;

    private var mController as ActivityController;
    // Single-shot, separate from ActivityController's own 1Hz recording
    // timer (which is stopped for the whole PAUSED duration) -- this one is
    // pure UI flow, owned by the delegate that decides when the menu shows.
    private var mPauseMenuTimer as Timer.Timer;
    private var mPauseMenuPending as Lang.Boolean = false;

    function initialize(controller as ActivityController) {
        BehaviorDelegate.initialize();
        mController = controller;
        mPauseMenuTimer = new Timer.Timer();
    }

    function onSelect() as Lang.Boolean {
        var state = mController.getState();
        if (state == ActivityController.STATE_READY || state == ActivityController.STATE_STOPPED) {
            mController.start();
        } else if (state == ActivityController.STATE_RECORDING) {
            mController.pause();
            startPauseMenuCountdown();
        } else if (state == ActivityController.STATE_PAUSED) {
            cancelPauseMenuCountdown();
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
            cancelPauseMenuCountdown();
            showPauseMenu();
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    private function startPauseMenuCountdown() as Void {
        mPauseMenuPending = true;
        mPauseMenuTimer.start(method(:onPauseMenuTimeout), PAUSE_MENU_DELAY_MS, false);
    }

    private function cancelPauseMenuCountdown() as Void {
        if (mPauseMenuPending) {
            mPauseMenuTimer.stop();
            mPauseMenuPending = false;
        }
    }

    function onPauseMenuTimeout() as Void {
        mPauseMenuPending = false;
        showPauseMenu();
    }

    // Once pushed, the Menu2/PauseMenuDelegate owns all button input until
    // popped -- there's no path for this delegate's onSelect()/onBack() to
    // also fire on a press meant for the menu.
    private function showPauseMenu() as Void {
        var menu = new WatchUi.Menu2({ :title => "Paused" });
        menu.addItem(new WatchUi.MenuItem("Resume", null, :resume, {}));
        menu.addItem(new WatchUi.MenuItem("Save", null, :save, {}));
        menu.addItem(new WatchUi.MenuItem("Discard", null, :discard, {}));
        WatchUi.pushView(menu, new PauseMenuDelegate(mController), WatchUi.SLIDE_IMMEDIATE);
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
