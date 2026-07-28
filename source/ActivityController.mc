using Toybox.ActivityRecording as Recording;
using Toybox.Activity;
using Toybox.ActivityMonitor;
using Toybox.Position;
using Toybox.UserProfile;
using Toybox.FitContributor;
using Toybox.Timer;
using Toybox.Lang;
using Toybox.System;
using Toybox.Application.Properties;

// Owns the recording Session lifecycle, HR-zone time accounting, and the
// custom FitContributor field. View/Delegate only ever call these methods.
//
// A "Resume Later" option (leave the Session stop()'d but never save()'d/
// discard()'d, then System.exit(), hoping to reclaim it via createSession()
// on next launch per its "only one Session at a time" documented contract)
// was tried and confirmed on real Enduro 3 hardware to NOT work: the watch's
// own firmware auto-finalizes and uploads an orphaned session as a completed
// activity as soon as the owning app process exits, regardless of what this
// class does at the Monkey C level. There's no supported way to suspend a
// Session across a real app exit -- stopAndSave()/discard() are the only two
// ways a PAUSED recording ends.
class ActivityController {

    enum {
        STATE_READY,
        STATE_RECORDING,
        STATE_PAUSED,
        STATE_STOPPED
    }

    // Rolling window (seconds) of ambient step count used to tell skating
    // apart from walking/running -- see updateSkateClassification().
    private const WINDOW_SECONDS = 8;
    private const MOVING_SPEED_THRESHOLD_MPS = 0.5;
    private const STEP_RATE_THRESHOLD_PER_MIN = 60.0;

    var state as Lang.Number = STATE_READY;

    private var mSession as Recording.Session?;
    private var mTimer as Timer.Timer;
    private var mZoneBoundaries as Lang.Array<Lang.Number>?;
    private var mZoneSeconds as Lang.Array<Lang.Number> = [0, 0, 0, 0, 0];
    private var mZoneField as FitContributor.Field?;
    private var mCurrentZoneIndex as Lang.Number?;
    private var mLapCount as Lang.Number = 0;
    private var mGpsAccuracy as Lang.Number?;
    private var mLastLapDistanceMeters as Lang.Float = 0.0;

    private var mSkateSeconds as Lang.Number = 0;
    private var mOtherSeconds as Lang.Number = 0;
    private var mSkateField as FitContributor.Field?;
    private var mOtherField as FitContributor.Field?;
    private var mCurrentlySkating as Lang.Boolean = false;
    // Cumulative step counts, one sample/sec, oldest first -- diffed to get
    // a step rate over WINDOW_SECONDS.
    private var mStepHistory as Lang.Array<Lang.Number> = [];

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

    function getCurrentlySkating() as Lang.Boolean {
        return mCurrentlySkating;
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
            mLastLapDistanceMeters = 0.0;
            mSkateSeconds = 0;
            mOtherSeconds = 0;
            mCurrentlySkating = false;
            mStepHistory = [];

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
            mSkateField = mSession.createField(
                "skate_seconds",
                1,
                FitContributor.DATA_TYPE_UINT32,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mOtherField = mSession.createField(
                "other_seconds",
                2,
                FitContributor.DATA_TYPE_UINT32,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
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
            // The OS pedometer keeps counting through a pause, so a step
            // window spanning the pause gap wouldn't represent the
            // just-resumed activity -- force a brief, safe-default
            // re-warm-up instead (see updateSkateClassification()).
            mStepHistory = [];
            mSession.start();
            mTimer.start(method(:onTimerTick), 1000, true);
            state = STATE_RECORDING;
        }
    }

    function addLap() as Void {
        if (mSession != null && mSession.isRecording()) {
            mSession.addLap();
            mLapCount += 1;
            // Whether this lap was manual or automatic, the auto-lap distance
            // countdown restarts from here.
            var info = Activity.getActivityInfo();
            if (info != null && info.elapsedDistance != null) {
                mLastLapDistanceMeters = info.elapsedDistance as Lang.Float;
            }
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
            if (mSkateField != null) {
                mSkateField.setData(mSkateSeconds);
            }
            if (mOtherField != null) {
                mOtherField.setData(mOtherSeconds);
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
        if (info == null) {
            return;
        }

        if (info.currentHeartRate != null) {
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

        updateSkateClassification(info);
        checkAutoLap(info);
    }

    // Distinguishes actual skating from anything else (standing, sitting,
    // walking, running) using GPS speed plus the device's always-on ambient
    // pedometer -- deliberately not raw accelerometer/Toybox.Sensor, matching
    // this project's existing preference for simple, empirically-tunable
    // heuristics over signal processing that's hard to validate quickly.
    // Never touches lap or pause logic (see checkAutoLap()), so however
    // noisy this classification turns out to be in practice, it cannot
    // produce spurious laps or auto-pauses -- it only ever feeds the
    // skate_seconds/other_seconds FIT fields and the on-screen dot.
    private function updateSkateClassification(info as Activity.Info) as Void {
        var monitorInfo = ActivityMonitor.getInfo();
        var steps = (monitorInfo != null) ? monitorInfo.steps : null;

        if (steps != null) {
            mStepHistory.add(steps);
            while (mStepHistory.size() > WINDOW_SECONDS + 1) {
                mStepHistory.remove(mStepHistory[0]);
            }
        }

        var speed = (info.currentSpeed != null) ? (info.currentSpeed as Lang.Float) : 0.0;

        if (speed < MOVING_SPEED_THRESHOLD_MPS) {
            mCurrentlySkating = false;
        } else if (mStepHistory.size() < 2) {
            mCurrentlySkating = false;
        } else {
            var elapsedWindowSeconds = mStepHistory.size() - 1;
            var stepDelta = mStepHistory[mStepHistory.size() - 1] - mStepHistory[0];
            var stepRatePerMin = stepDelta * 60.0 / elapsedWindowSeconds;
            mCurrentlySkating = (stepRatePerMin < STEP_RATE_THRESHOLD_PER_MIN);
        }

        if (mCurrentlySkating) {
            mSkateSeconds += 1;
        } else {
            mOtherSeconds += 1;
        }
        if (mSkateField != null) {
            mSkateField.setData(mSkateSeconds);
        }
        if (mOtherField != null) {
            mOtherField.setData(mOtherSeconds);
        }
    }

    // Auto-lap at 1 unit (km or mi, matching the system distance setting) --
    // toggleable via the "Auto Lap" app setting in Garmin Connect Mobile.
    // There's no built-in distance-based auto-lap in the Connect IQ SDK
    // (ActivityRecording's :autoLap option only supports geofence entry/exit
    // lines), so this tracks it manually against elapsedDistance.
    private function checkAutoLap(info as Activity.Info) as Void {
        if (info.elapsedDistance == null) {
            return;
        }
        var autoLapEnabled = Properties.getValue("autoLapEnabled");
        if (autoLapEnabled != true) {
            return;
        }
        var elapsedDistance = info.elapsedDistance as Lang.Float;
        var thresholdMeters = (System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE) ? 1609.344 : 1000.0;
        if (elapsedDistance - mLastLapDistanceMeters >= thresholdMeters) {
            addLap();
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
