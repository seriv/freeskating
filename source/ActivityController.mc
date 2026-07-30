using Toybox.ActivityRecording as Recording;
using Toybox.Activity;
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

    // GPS speed threshold distinguishing skating from everything else -- see
    // updateSkateClassification(). Calibrated empirically from a real ride
    // with lap markers pressed at every skate/walk transition: the 4
    // lap-bounded skating segments averaged 2.04-3.09 m/s, the 6 walking
    // segments averaged 0.06-1.37 m/s, a clean gap with no overlap. An
    // ambient-step-count-based and the device's own native cadence-based
    // heuristic were both tried first and confirmed (on two separate real
    // rides) to NOT separate skating from walking at all -- freeskate
    // pumping/carving motion gets picked up as step/cadence-like signal on
    // this device, so cadence-based approaches misclassified the majority
    // of actual skating time as "not skating."
    //
    // A pure per-tick threshold on this value flickers constantly during
    // real skating, since the natural push-glide rhythm cycles speed above
    // and below it every second or two, and it also drops out of "skating"
    // entirely during slow, sustained uphill skating (real skating effort,
    // just below this speed). Both are fixed by latching the classification
    // (see mLatchedSkating/updateSkateClassification()) instead of
    // re-deciding from raw speed alone on every tick.
    private const SKATING_SPEED_THRESHOLD_MPS = 1.6;

    // Below this, GPS speed is treated as a genuine stop (mounting/
    // dismounting equipment, or just a pause) rather than slow movement --
    // confirmed against real data showing full stops read as ~0 m/s, well
    // below any real walking or skating pace.
    private const STOPPED_SPEED_MPS = 0.2;

    // How many seconds after motion resumes from a stop to watch for a
    // push-off burst above SKATING_SPEED_THRESHOLD_MPS before settling on
    // "not skating" -- confirmed against real data that a genuine
    // skate-mount push-off produces a burst within 1-2 seconds of first
    // moving, while resuming a walk does not.
    private const BURST_CHECK_WINDOW_SECONDS = 5;

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
    // Sticky classification -- see updateSkateClassification(). Only
    // changes at a genuine stop-then-resume transition, not on every tick.
    private var mLatchedSkating as Lang.Boolean = false;
    private var mAwaitingBurstCheck as Lang.Boolean = false;
    private var mBurstCheckTicksRemaining as Lang.Number = 0;

    // Distance covered while skating -- mSkateDistanceMeters is a running
    // session total (for the live watch display, which should keep growing
    // over the whole ride rather than resetting); mLapSkateDistanceMeters is
    // the same thing but reset at each lap boundary, feeding a MESG_TYPE_LAP
    // field so Garmin Connect/MonkeyGraph can show a per-lap breakdown.
    private var mSkateDistanceMeters as Lang.Float = 0.0;
    private var mLapSkateDistanceMeters as Lang.Float = 0.0;
    private var mPreviousDistanceMeters as Lang.Float = 0.0;
    private var mLapSkateDistanceField as FitContributor.Field?;
    // Speed split into two record-level fields (nonzero only in their own
    // state, zero otherwise) as an approximation of a single color-coded
    // speed graph, since Garmin Connect's built-in Speed chart has no
    // customization hook for third-party developer fields.
    private var mSkateSpeedField as FitContributor.Field?;
    private var mWalkSpeedField as FitContributor.Field?;

    // Grade (smoothed % slope, from altitude/distance history) and a
    // rider-tunable grade-adjusted speed, recorded per second so a ride's
    // grade/speed/HR can be correlated afterwards to calibrate the
    // "gradeAdjustCoefficient" setting against real data. Deliberately not
    // a fixed formula: running's published grade-adjusted-pace curves don't
    // transfer to caster-based pumping mechanics (see project discussion),
    // so this starts as a rough linear guess meant to be refined per-rider.
    private const GRADE_WINDOW_SECONDS = 15;
    private var mDistanceHistory as Lang.Array<Lang.Float?>?;
    private var mAltitudeHistory as Lang.Array<Lang.Float?>?;
    private var mHistoryIndex as Lang.Number = 0;
    private var mHistoryCount as Lang.Number = 0;
    private var mCurrentGradePercent as Lang.Float = 0.0;
    private var mGradeField as FitContributor.Field?;
    private var mGapSpeedField as FitContributor.Field?;

    function initialize() {
        // Garmin-configured zones, not hardcoded thresholds -- boundaries are
        // [min1, max1, max2, max3, max4, max5] in bpm.
        mZoneBoundaries = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_GENERIC);
        mTimer = new Timer.Timer();
        mDistanceHistory = new [GRADE_WINDOW_SECONDS];
        mAltitudeHistory = new [GRADE_WINDOW_SECONDS];

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

    function getSkateDistanceMeters() as Lang.Float {
        return mSkateDistanceMeters;
    }

    // Average speed while actually skating, ignoring walking/idle time --
    // null until at least one skating second has been recorded.
    function getAverageSkateSpeedMps() as Lang.Float? {
        if (mSkateSeconds <= 0) {
            return null;
        }
        return mSkateDistanceMeters / mSkateSeconds.toFloat();
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
            mLatchedSkating = false;
            mAwaitingBurstCheck = false;
            mBurstCheckTicksRemaining = 0;
            mSkateDistanceMeters = 0.0;
            mLapSkateDistanceMeters = 0.0;
            mPreviousDistanceMeters = 0.0;
            mHistoryIndex = 0;
            mHistoryCount = 0;
            mCurrentGradePercent = 0.0;

            mSession = Recording.createSession({
                :name => "Freeskate",
                :sport => Recording.SPORT_GENERIC,
                :subSport => Recording.SUB_SPORT_GENERIC
            });

            // DATA_TYPE_FLOAT, not UINT32 -- confirmed via Garmin forum reports
            // that MonkeyGraph/Connect show session-level integer
            // FitContributor fields as "#VALUE?" but render float fields
            // correctly; cause undocumented, but this matches the working
            // fix reported there (paired with precision="0" in
            // fitContributions.xml, which rounds the displayed value back
            // to a whole number).
            mZoneField = mSession.createField(
                "hr_zone_seconds",
                0,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s", :count => 5 }
            );
            mSkateField = mSession.createField(
                "skate_seconds",
                1,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mOtherField = mSession.createField(
                "other_seconds",
                2,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mLapSkateDistanceField = mSession.createField(
                "lap_skate_distance",
                3,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m" }
            );
            mSkateSpeedField = mSession.createField(
                "skate_speed",
                4,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mWalkSpeedField = mSession.createField(
                "walk_speed",
                5,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mGradeField = mSession.createField(
                "grade_percent",
                6,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" }
            );
            mGapSpeedField = mSession.createField(
                "grade_adjusted_speed",
                7,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
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
            // session.addLap() captures each field's current value into the
            // just-completed Lap message -- reset the accumulator right
            // after, so it starts fresh for the new lap.
            mSession.addLap();
            mLapCount += 1;
            // Whether this lap was manual or automatic, the auto-lap distance
            // countdown restarts from here.
            var info = Activity.getActivityInfo();
            if (info != null && info.elapsedDistance != null) {
                mLastLapDistanceMeters = info.elapsedDistance as Lang.Float;
            }
            mLapSkateDistanceMeters = 0.0;
            if (mLapSkateDistanceField != null) {
                mLapSkateDistanceField.setData(mLapSkateDistanceMeters);
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
        updateGradeAndGap(info);
        checkAutoLap(info);
    }

    // Distinguishes actual skating from anything else (standing, sitting,
    // walking, running) using GPS speed alone -- see
    // SKATING_SPEED_THRESHOLD_MPS for the calibration data behind this.
    // Never touches lap or pause logic (see checkAutoLap()), so however
    // noisy this classification turns out to be in practice, it cannot
    // produce spurious laps or auto-pauses -- it only ever feeds the
    // skate_seconds/other_seconds FIT fields and the on-screen dot. Known
    // limitation, accepted for v1: running at a jogging pace or faster
    // would also read as "skating" here, since speed alone can't tell
    // gait-based movement from skating apart above that threshold.
    //
    // Classification is latched (mLatchedSkating), not re-decided from raw
    // speed on every tick:
    //  - speed >= threshold always latches skating (high-confidence signal).
    //  - a genuine stop (speed <= STOPPED_SPEED_MPS) arms a re-evaluation:
    //    once moving again, a push-off burst above threshold within
    //    BURST_CHECK_WINDOW_SECONDS re-latches skating; no burst in that
    //    window settles on not-skating instead.
    //  - moving below threshold with no stop/re-evaluation pending keeps
    //    whatever was last latched -- this is what lets a slow, sustained
    //    uphill skating stretch stay classified correctly instead of
    //    dropping out every time speed dips below the threshold.
    private function updateSkateClassification(info as Activity.Info) as Void {
        var speed = (info.currentSpeed != null) ? (info.currentSpeed as Lang.Float) : 0.0;

        if (speed <= STOPPED_SPEED_MPS) {
            mAwaitingBurstCheck = true;
            mBurstCheckTicksRemaining = BURST_CHECK_WINDOW_SECONDS;
        } else if (speed >= SKATING_SPEED_THRESHOLD_MPS) {
            mLatchedSkating = true;
            mAwaitingBurstCheck = false;
        } else if (mAwaitingBurstCheck) {
            mBurstCheckTicksRemaining -= 1;
            if (mBurstCheckTicksRemaining <= 0) {
                mLatchedSkating = false;
                mAwaitingBurstCheck = false;
            }
        }
        // else: moving, below threshold, not awaiting a burst check --
        // keep the current mLatchedSkating value unchanged.

        mCurrentlySkating = mLatchedSkating;

        if (info.elapsedDistance != null) {
            var currentDistance = info.elapsedDistance as Lang.Float;
            var delta = currentDistance - mPreviousDistanceMeters;
            if (mCurrentlySkating && delta > 0) {
                mSkateDistanceMeters += delta;
                mLapSkateDistanceMeters += delta;
            }
            mPreviousDistanceMeters = currentDistance;
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
        if (mLapSkateDistanceField != null) {
            mLapSkateDistanceField.setData(mLapSkateDistanceMeters);
        }
        if (mSkateSpeedField != null) {
            mSkateSpeedField.setData(mCurrentlySkating ? speed : 0.0);
        }
        if (mWalkSpeedField != null) {
            mWalkSpeedField.setData(mCurrentlySkating ? 0.0 : speed);
        }
    }

    // Smooths grade over GRADE_WINDOW_SECONDS of elapsed distance/altitude
    // history rather than differencing consecutive ticks -- a raw per-second
    // grade is dominated by barometer/GPS noise at typical freeskating
    // speeds (only a couple meters of horizontal movement per tick).
    // Grade-adjusted speed then applies Properties["gradeAdjustCoefficient"]
    // (Settings -> "Grade Adjust Coefficient"), a rider-tunable multiplier
    // with no fixed correct value yet -- it's meant to be dialed in against
    // real ride data (grade/speed/HR are all recorded per-second, so
    // post-ride analysis can fit it), not derived from wheel/truck geometry.
    private function updateGradeAndGap(info as Activity.Info) as Void {
        if (info.elapsedDistance == null || info.altitude == null) {
            return;
        }
        var distance = info.elapsedDistance as Lang.Float;
        var altitude = info.altitude as Lang.Float;
        var distanceHistory = mDistanceHistory as Lang.Array<Lang.Float?>;
        var altitudeHistory = mAltitudeHistory as Lang.Array<Lang.Float?>;

        if (mHistoryCount >= GRADE_WINDOW_SECONDS) {
            var oldestDistance = distanceHistory[mHistoryIndex] as Lang.Float;
            var oldestAltitude = altitudeHistory[mHistoryIndex] as Lang.Float;
            var distanceDelta = distance - oldestDistance;
            // Require at least 1m of horizontal movement over the window --
            // otherwise (near-stopped) the denominator is noise-dominated
            // and would blow the grade estimate up arbitrarily. Keep the
            // last computed value instead of resetting to 0 in that case.
            if (distanceDelta > 1.0) {
                mCurrentGradePercent = ((altitude - oldestAltitude) / distanceDelta) * 100.0;
            }
        }

        distanceHistory[mHistoryIndex] = distance;
        altitudeHistory[mHistoryIndex] = altitude;
        mHistoryIndex = (mHistoryIndex + 1) % GRADE_WINDOW_SECONDS;
        if (mHistoryCount < GRADE_WINDOW_SECONDS) {
            mHistoryCount += 1;
        }

        if (mGradeField != null) {
            mGradeField.setData(mCurrentGradePercent);
        }

        var speed = (info.currentSpeed != null) ? (info.currentSpeed as Lang.Float) : 0.0;
        var coefficient = Properties.getValue("gradeAdjustCoefficient") as Lang.Float;
        var factor = 1.0 + coefficient * (mCurrentGradePercent / 100.0);
        if (factor < 0.0) {
            factor = 0.0;
        }
        if (mGapSpeedField != null) {
            mGapSpeedField.setData(speed * factor);
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
