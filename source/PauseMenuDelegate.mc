using Toybox.WatchUi;
using Toybox.Lang;
using Toybox.System;

// Input delegate for the pause menu (auto-shown after a delay, or opened
// immediately by Back -- see FreeskateDelegate.showPauseMenu()). Resume pops
// back to the main view, which then reflects the controller's RECORDING
// state. Save and Discard end the activity and exit straight to the watch
// face (matching native activity apps, which don't leave you on a
// "ready to start another" screen) -- both fully close the Session
// (save()/discard()) before exiting, so unlike the removed "Resume Later"
// path there's no orphaned-session risk in exiting immediately after.
class PauseMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mController as ActivityController;

    function initialize(controller as ActivityController) {
        Menu2InputDelegate.initialize();
        mController = controller;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :resume) {
            mController.resume();
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            WatchUi.requestUpdate();
        } else if (id == :stance) {
            // ToggleMenuItem has already flipped its own isEnabled() to the
            // new state by the time onSelect() fires -- read it rather than
            // inverting the old value ourselves.
            var toggle = item as WatchUi.ToggleMenuItem;
            mController.setStance(toggle.isEnabled());
        } else if (id == :save) {
            mController.stopAndSave();
            System.exit();
        } else if (id == :discard) {
            mController.discard();
            System.exit();
        }
    }
}
