using Toybox.Application;
using Toybox.WatchUi;
using Toybox.Lang;

class FreeskateApp extends Application.AppBase {

    private var mController as ActivityController;

    function initialize() {
        AppBase.initialize();
        mController = new ActivityController();
    }

    function onStart(state as Lang.Dictionary?) as Void {
    }

    function onStop(state as Lang.Dictionary?) as Void {
        // Don't silently lose a session if the app gets killed mid-recording.
        // A no-op when the pause menu's Save/Discard already ended the
        // Session before calling System.exit() -- state is STOPPED/READY by
        // then, not RECORDING/PAUSED, so this check correctly skips it.
        var currentState = mController.getState();
        if (currentState == ActivityController.STATE_RECORDING || currentState == ActivityController.STATE_PAUSED) {
            mController.stopAndSave();
        }
        mController.shutdownPositioning();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new FreeskateView(mController), new FreeskateDelegate(mController)];
    }
}
