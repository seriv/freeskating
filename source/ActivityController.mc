using Toybox.ActivityRecording as Recording;
using Toybox.Activity;
using Toybox.Position;
using Toybox.UserProfile;
using Toybox.FitContributor;
using Toybox.Timer;
using Toybox.Lang;

// Owns the recording Session lifecycle, HR-zone time accounting, and the
// custom FitContributor field. View/Delegate only ever call these methods.
class ActivityController {

    enum {
        STATE_READY,
        STATE_RECORDING,
        STATE_PAUSED,
        STATE_STOPPED
    }

    var state as Lang.Number = STATE_READY;

    private var mSession as Recording.Session?;
    private var mTimer as Timer.Timer;
    private var mZoneBoundaries as Lang.Array<Lang.Number>?;
    private var mZoneSeconds as Lang.Array<Lang.Number> = [0, 0, 0, 0, 0];
    private var mZoneField as FitContributor.Field?;
    private var mCurrentZoneIndex as Lang.Number?;
    private var mLapCount as Lang.Number = 0;
    private var mGpsAccuracy as Lang.Number?;

    function initialize() {
        // Garmin-configured zones, not hardcoded thresholds -- boundaries are
        // [min1, max1, max2, max3, max4, max5] in bpm.
        mZoneBoundaries = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_GENERIC);
        mTimer = new Timer.Timer();

        // Acquire GPS from launch, not just once recording starts, so the
        // status indicator has something to show and a fix is ready (or
        // close to it) by the time the user actually presses start.
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
    }

    function getState() as Lang.Number {
        return state;
    }

    function getLapCount() as Lang.Number {
        return mLapCount;
    }

    function getCurrentZoneIndex() as Lang.Number? {
        return mCurrentZoneIndex;
    }

    // A Position.Quality value (QUALITY_NOT_AVAILABLE..QUALITY_GOOD), or null
    // before the first fix attempt reports in.
    function getGpsAccuracy() as Lang.Number? {
        return mGpsAccuracy;
    }

    // Live stats (elapsedTime, elapsedDistance, currentHeartRate, currentSpeed)
    // are populated by the platform once the session is recording -- callers
    // read them straight from here rather than the controller tracking its own copy.
    function getActivityInfo() as Activity.Info? {
        if (mSession == null) {
            return null;
        }
        return Activity.getActivityInfo();
    }

    function start() as Void {
        if (state == STATE_READY || state == STATE_STOPPED) {
            mLapCount = 0;
            mZoneSeconds = [0, 0, 0, 0, 0];
            mCurrentZoneIndex = null;

            mSession = Recording.createSession({
                :name => "Freeskate",
                :sport => Recording.SPORT_GENERIC,
                :subSport => Recording.SUB_SPORT_GENERIC
            });

            mZoneField = mSession.createField(
                "hr_zone_seconds",
                0,
                FitContributor.DATA_TYPE_UINT32,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s", :count => 5 }
            );
        }

        if (mSession != null) {
            mSession.start();
            mTimer.start(method(:onTimerTick), 1000, true);
            state = STATE_RECORDING;
        }
    }

    function pause() as Void {
        if (state == STATE_RECORDING && mSession != null) {
            mSession.stop();
            mTimer.stop();
            state = STATE_PAUSED;
        }
    }

    function resume() as Void {
        if (state == STATE_PAUSED && mSession != null) {
            mSession.start();
            mTimer.start(method(:onTimerTick), 1000, true);
            state = STATE_RECORDING;
        }
    }

    function addLap() as Void {
        if (mSession != null && mSession.isRecording()) {
            mSession.addLap();
            mLapCount += 1;
        }
    }

    function stopAndSave() as Void {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mTimer.stop();
            if (mZoneField != null) {
                mZoneField.setData(mZoneSeconds);
            }
            mSession.save();
            mSession = null;
        }
        state = STATE_STOPPED;
    }

    function discard() as Void {
        if (mSession != null) {
            if (mSession.isRecording()) {
                mSession.stop();
            }
            mTimer.stop();
            mSession.discard();
            mSession = null;
        }
        state = STATE_READY;
    }

    // Called from FreeskateApp.onStop() when the app is actually exiting (not
    // just backgrounding -- see AppBase.onStop() docs), to release GPS.
    function shutdownPositioning() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    function onPosition(posInfo as Position.Info) as Void {
        mGpsAccuracy = posInfo.accuracy;
    }

    function onTimerTick() as Void {
        var info = Activity.getActivityInfo();
        if (info == null || info.currentHeartRate == null) {
            return;
        }

        var hr = info.currentHeartRate as Lang.Number;
        var zoneIndex = zoneIndexForHr(hr);
        mCurrentZoneIndex = zoneIndex;
        if (zoneIndex != null) {
            mZoneSeconds[zoneIndex] = mZoneSeconds[zoneIndex] + 1;
            if (mZoneField != null) {
                mZoneField.setData(mZoneSeconds);
            }
        }
    }

    private function zoneIndexForHr(hr as Lang.Number) as Lang.Number? {
        if (mZoneBoundaries == null || mZoneBoundaries.size() < 6) {
            return null;
        }
        for (var i = 0; i < 5; i += 1) {
            var upper = mZoneBoundaries[i + 1] as Lang.Number;
            if (hr <= upper) {
                return i;
            }
        }
        return 4;
    }
}
