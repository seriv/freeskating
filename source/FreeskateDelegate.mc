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
//   Next/Prev page -> physically the Up/Down buttons on the Enduro 3
//                     (Down -> onNextPage, Up -> onPreviousPage, confirmed
//                     empirically). Used here to manually tag skate/walk:
//                     Down = skating, Up = walking (see
//                     ActivityController.setSkating()). Confirmed on real
//                     hardware, while actively RECORDING (lap is only
//                     reachable from that state), to fire independently of
//                     Back: the lap count never moved while pressing
//                     either. An earlier version of this comment claimed
//                     they duplicated the lap button; that was most likely
//                     observed in the desktop simulator, not on real
//                     hardware, and doesn't hold up under this retest.
//
// Mirrors native Garmin activity apps: Select toggles recording/paused, and
// stopping goes through a pause menu (Resume/Save/Discard) -- like native
// apps, this is a two-step gate against ending a recording with one
// accidental press. No on-screen Select/Back button hints -- deliberately
// omitted (an earlier version had them) since anyone who's used a standard
// Garmin activity app already knows this convention, and the round
// enduro3 screen has no comfortable room to spare for them (see
// FreeskateView.onUpdate()). (A fourth "Resume Later" option was tried and
// removed -- see the comment on ActivityController for why it can't work
// on real hardware.)
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
        mController.setSkating(true);
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Lang.Boolean {
        mController.setSkating(false);
        WatchUi.requestUpdate();
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
