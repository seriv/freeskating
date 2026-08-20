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

    // Manual skate/walk tagging -- an automatic GPS-speed-threshold version
    // of this was tried and dropped (speed alone can't distinguish
    // gait-based movement from skating). Replaced with a direct manual tag
    // instead of accelerometer-based auto-detection, since the Up/Down
    // buttons (onPreviousPage/onNextPage) were confirmed empirically, on
    // real Enduro 3 hardware while actively RECORDING, to be free and
    // independent of Back/lap -- see FreeskateDelegate.mc. Being manual
    // means no smoothing/latching is needed: the tag is exactly whatever
    // the rider last set, so unlike the dropped classifier this can't
    // misclassify.
    private var mSkating as Lang.Boolean = true;
    private var mSkateSeconds as Lang.Number = 0;
    private var mOtherSeconds as Lang.Number = 0;
    private var mSkateField as FitContributor.Field?;
    private var mOtherField as FitContributor.Field?;
    // Distance covered while tagged skating -- mSkateDistanceMeters is a
    // running session total (for the live watch display, which should keep
    // growing over the whole ride rather than resetting); mLapSkateDistanceMeters
    // is the same thing but reset at each lap boundary, feeding a
    // MESG_TYPE_LAP field so Garmin Connect/MonkeyGraph can show a per-lap
    // breakdown.
    private var mSkateDistanceMeters as Lang.Float = 0.0;
    private var mLapSkateDistanceMeters as Lang.Float = 0.0;
    private var mPreviousDistanceMeters as Lang.Float = 0.0;
    private var mLapSkateDistanceField as FitContributor.Field?;
    // Speed split into two record-level fields (nonzero only in their own
    // tag, zero otherwise) as an approximation of a single color-coded
    // speed graph, since Garmin Connect's built-in Speed chart has no
    // customization hook for third-party developer fields.
    private var mSkateSpeedField as FitContributor.Field?;
    private var mWalkSpeedField as FitContributor.Field?;

    // Manual regular/goofy stance tagging -- same rationale as mSkating:
    // GPS speed/position can't tell stance apart, so this is a direct
    // manual tag, set via a ToggleMenuItem in the pause menu (see
    // PauseMenuDelegate) rather than a live button, since every physical
    // button during RECORDING is already committed (see FreeskateDelegate).
    // Only meaningful while mSkating is true -- stance doesn't apply to the
    // walking tag, so goofy/regular bookkeeping is gated on mSkating below.
    // Defaults to goofy (false): that's the stance ridden the large
    // majority of the time, so it's the safer assumption if a ride starts
    // before the rider remembers to check/flip it.
    private var mRegular as Lang.Boolean = false;
    private var mRegularSeconds as Lang.Number = 0;
    private var mGoofySeconds as Lang.Number = 0;
    private var mRegularField as FitContributor.Field?;
    private var mGoofyField as FitContributor.Field?;
    private var mRegularDistanceMeters as Lang.Float = 0.0;
    private var mRegularSpeedField as FitContributor.Field?;
    private var mGoofySpeedField as FitContributor.Field?;

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

    // See CadenceDetector for the accelerometer signal processing -- this
    // class only owns its lifecycle (RECORDING-only, same as mTimer) and
    // the FIT field. Recorded in every activity state (not gated on
    // mSkating) -- see CadenceDetector's comment for why: it's meant to
    // become a labeled walk-vs-skate-vs-stance dataset, which requires
    // data from all of them, not just skating. It IS gated on actual GPS
    // movement, though (see updateSkateBookkeeping) -- real ride data
    // showed nonzero cadence readings from arm-jostle noise while fully
    // stopped, and gating on speed rather than the accelerometer itself
    // avoids using the noisy sensor to judge its own noise floor.
    private const MOVING_SPEED_THRESHOLD_MPS = 0.3;
    private var mCadenceDetector as CadenceDetector;
    private var mCadenceField as FitContributor.Field?;

    function initialize() {
        // Garmin-configured zones, not hardcoded thresholds -- boundaries are
        // [min1, max1, max2, max3, max4, max5] in bpm.
        mZoneBoundaries = UserProfile.getHeartRateZones(UserProfile.HR_ZONE_SPORT_GENERIC);
        mTimer = new Timer.Timer();
        mDistanceHistory = new [GRADE_WINDOW_SECONDS];
        mAltitudeHistory = new [GRADE_WINDOW_SECONDS];
        mCadenceDetector = new CadenceDetector();

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

    // Set directly by the Up/Down buttons (FreeskateDelegate), not a
    // toggle -- each button means "I am doing this now," so a repeated or
    // out-of-sync press is harmless.
    function setSkating(skating as Lang.Boolean) as Void {
        mSkating = skating;
    }

    function getCurrentlySkating() as Lang.Boolean {
        return mSkating;
    }

    function getSkateDistanceMeters() as Lang.Float {
        return mSkateDistanceMeters;
    }

    // Set directly by the pause-menu ToggleMenuItem (PauseMenuDelegate), not
    // a toggle method here -- same "last value wins" rationale as
    // setSkating().
    function setStance(regular as Lang.Boolean) as Void {
        mRegular = regular;
    }

    function getRegularStance() as Lang.Boolean {
        return mRegular;
    }

    // Average speed while tagged skating AND regular, ignoring goofy/
    // walking time -- null until at least one regular-skating second has
    // been recorded.
    function getAverageRegularSpeedMps() as Lang.Float? {
        if (mRegularSeconds <= 0) {
            return null;
        }
        return mRegularDistanceMeters / mRegularSeconds.toFloat();
    }

    // Average speed while tagged skating, ignoring walking/idle time --
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
            mHistoryIndex = 0;
            mHistoryCount = 0;
            mCurrentGradePercent = 0.0;
            mSkating = true;
            mSkateSeconds = 0;
            mOtherSeconds = 0;
            mSkateDistanceMeters = 0.0;
            mLapSkateDistanceMeters = 0.0;
            mPreviousDistanceMeters = 0.0;
            mRegular = false;
            mRegularSeconds = 0;
            mGoofySeconds = 0;
            mRegularDistanceMeters = 0.0;
            mCadenceDetector.reset();

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
            mGradeField = mSession.createField(
                "grade_percent",
                1,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "%" }
            );
            mGapSpeedField = mSession.createField(
                "grade_adjusted_speed",
                2,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mSkateField = mSession.createField(
                "skate_seconds",
                3,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mOtherField = mSession.createField(
                "other_seconds",
                4,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mLapSkateDistanceField = mSession.createField(
                "lap_skate_distance",
                5,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_LAP, :units => "m" }
            );
            mSkateSpeedField = mSession.createField(
                "skate_speed",
                6,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mWalkSpeedField = mSession.createField(
                "walk_speed",
                7,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mRegularField = mSession.createField(
                "regular_seconds",
                8,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mGoofyField = mSession.createField(
                "goofy_seconds",
                9,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "s" }
            );
            mRegularSpeedField = mSession.createField(
                "regular_speed",
                10,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mGoofySpeedField = mSession.createField(
                "goofy_speed",
                11,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "m/s" }
            );
            mCadenceField = mSession.createField(
                "accel_cadence",
                12,
                FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "cpm" }
            );
        }

        if (mSession != null) {
            mSession.start();
            mTimer.start(method(:onTimerTick), 1000, true);
            mCadenceDetector.start();
            state = STATE_RECORDING;
        }
    }

    function pause() as Void {
        if (state == STATE_RECORDING && mSession != null) {
            mSession.stop();
            mTimer.stop();
            mCadenceDetector.stop();
            state = STATE_PAUSED;
        }
    }

    function resume() as Void {
        if (state == STATE_PAUSED && mSession != null) {
            mSession.start();
            mTimer.start(method(:onTimerTick), 1000, true);
            mCadenceDetector.start();
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
            mCadenceDetector.stop();
            if (mZoneField != null) {
                mZoneField.setData(mZoneSeconds);
            }
            if (mSkateField != null) {
                mSkateField.setData(mSkateSeconds);
            }
            if (mOtherField != null) {
                mOtherField.setData(mOtherSeconds);
            }
            if (mRegularField != null) {
                mRegularField.setData(mRegularSeconds);
            }
            if (mGoofyField != null) {
                mGoofyField.setData(mGoofySeconds);
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
            mCadenceDetector.stop();
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

        updateSkateBookkeeping(info);
        updateGradeAndGap(info);
        checkAutoLap(info);
    }

    // Accumulates skate/other seconds and skate distance according to the
    // manually-set mSkating tag (see setSkating()) -- purely bookkeeping,
    // no classification logic here since the tag is already known.
    private function updateSkateBookkeeping(info as Activity.Info) as Void {
        var speed = (info.currentSpeed != null) ? (info.currentSpeed as Lang.Float) : 0.0;

        if (info.elapsedDistance != null) {
            var currentDistance = info.elapsedDistance as Lang.Float;
            var delta = currentDistance - mPreviousDistanceMeters;
            if (mSkating && delta > 0) {
                mSkateDistanceMeters += delta;
                mLapSkateDistanceMeters += delta;
                if (mRegular) {
                    mRegularDistanceMeters += delta;
                }
            }
            mPreviousDistanceMeters = currentDistance;
        }

        if (mSkating) {
            mSkateSeconds += 1;
            if (mRegular) {
                mRegularSeconds += 1;
            } else {
                mGoofySeconds += 1;
            }
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
            mSkateSpeedField.setData(mSkating ? speed : 0.0);
        }
        if (mWalkSpeedField != null) {
            mWalkSpeedField.setData(mSkating ? 0.0 : speed);
        }
        if (mRegularField != null) {
            mRegularField.setData(mRegularSeconds);
        }
        if (mGoofyField != null) {
            mGoofyField.setData(mGoofySeconds);
        }
        if (mRegularSpeedField != null) {
            mRegularSpeedField.setData((mSkating && mRegular) ? speed : 0.0);
        }
        if (mGoofySpeedField != null) {
            mGoofySpeedField.setData((mSkating && !mRegular) ? speed : 0.0);
        }
        if (mCadenceField != null) {
            // Not gated on mSkating, unlike skate_speed/regular_speed/etc --
            // see CadenceDetector's comment: recording this in every state
            // (walking included) is what makes it usable later as a
            // labeled dataset against the tags that ARE gated. It IS gated
            // on actual movement, though -- see MOVING_SPEED_THRESHOLD_MPS.
            var moving = speed > MOVING_SPEED_THRESHOLD_MPS;
            mCadenceField.setData(moving ? mCadenceDetector.getCadence() : 0.0);
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
            // Require at least 5m of horizontal movement over the window --
            // otherwise (near-stopped) the denominator is noise-dominated
            // and would blow the grade estimate up arbitrarily. Keep the
            // last computed value instead of resetting to 0 in that case.
            // Raised from 1m after a real ride showed grade spikes to
            // -89%/+58% while near-stationary; every one of those outliers
            // occurred at a 15s-window distanceDelta under 4.35m, so 5m
            // covers the observed noise floor with a small margin.
            if (distanceDelta > 5.0) {
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
