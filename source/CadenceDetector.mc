using Toybox.Sensor;
using Toybox.Math;
using Toybox.Lang;

// Estimates cadence (rhythmic wrist-motion cycles per minute) from the
// accelerometer. Deliberately magnitude-based (sqrt(x^2+y^2+z^2)) rather
// than picking a single axis: the watch's rotational orientation on the
// wrist isn't fixed or known, so a single-axis signal would depend on how
// the rider happens to be wearing it, while magnitude is orientation-
// independent -- the same reason step counters use it instead of a
// specific axis.
//
// Originally scoped as "pump cadence" (skating only), but the same wrist
// motion detector picks up walking arm-swing just as well, and running it
// continuously -- not just while tagged skating -- turns it into a
// labeled dataset for free: ActivityController already records ground-
// truth walk/skate and regular/goofy tags every second, so recording this
// signal in every state (rather than zeroing it out while walking) is what
// makes it possible to later ask whether accelerometer data alone can
// distinguish walk vs. goofy vs. regular skating, instead of relying on
// the manual button/menu tags. Not implemented yet -- this class only
// produces the raw cadence number; the classification is future work.
//
// A wrist accelerometer is a poor proxy for the actual board/footplate
// mechanics (it measures arm swing, not edge angle or pivot), but pumping
// does drive a rhythmic arm swing, similar to how running dynamics infers
// cadence from a wrist swing rather than a foot-mounted sensor.
//
// PEAK_THRESHOLD_MILLIG below is a rough starting guess, not yet
// calibrated against real data -- same caveat as ActivityController's
// gradeAdjustCoefficient. The first real ride recorded under this name
// (skate-only, gated) showed close to zero correlation between cadence and
// skate speed, so treat this as a first pass pending retuning, not a
// validated metric.
class CadenceDetector {

    private const SAMPLE_RATE_HZ = 25;
    private const SENSOR_PERIOD_SECONDS = 1;
    // Exponential-moving-average smoothing factor for the rolling baseline
    // (acts as a cheap high-pass filter isolating swing motion from the
    // ~1000 milli-G gravity offset), applied per-sample.
    private const BASELINE_ALPHA = 0.05;
    private const PEAK_THRESHOLD_MILLIG = 150.0;
    // Minimum samples between counted peaks (~0.25s at SAMPLE_RATE_HZ),
    // caps detected cadence at 240/min so sensor noise can't be counted as
    // multiple cycles within one real motion cycle.
    private const REFRACTORY_SAMPLES = 6;
    // Cadence is reported as a trailing rolling average over this many
    // one-second buckets, rather than the instantaneous last-second count,
    // so it doesn't jump around between individual strides/pumps.
    private const CADENCE_WINDOW_SECONDS = 4;

    private var mBaseline as Lang.Float = 1000.0;
    private var mSamplesSinceLastPeak as Lang.Number = REFRACTORY_SAMPLES;
    private var mPeakCountsPerSecond as Lang.Array<Lang.Number?>;
    private var mPeakCountsIndex as Lang.Number = 0;
    private var mCurrentSecondPeaks as Lang.Number = 0;
    private var mEnabled as Lang.Boolean = false;

    function initialize() {
        mPeakCountsPerSecond = new [CADENCE_WINDOW_SECONDS];
        reset();
    }

    // Called from ActivityController.start(), same as the other per-ride
    // accumulators -- clears out any trailing window data from a previous
    // ride so cadence doesn't start artificially high.
    function reset() as Void {
        mBaseline = 1000.0;
        mSamplesSinceLastPeak = REFRACTORY_SAMPLES;
        mCurrentSecondPeaks = 0;
        mPeakCountsIndex = 0;
        for (var i = 0; i < CADENCE_WINDOW_SECONDS; i += 1) {
            mPeakCountsPerSecond[i] = 0;
        }
    }

    // Tied to the same RECORDING-only lifecycle as ActivityController's
    // mTimer (start()/resume() enable, pause()/stopAndSave()/discard()
    // disable), NOT to the walk/skate tag -- runs the whole time you're
    // recording, regardless of activity, which is what makes the walk-vs-
    // skate dataset possible. Enduro 3's battery budget makes continuous
    // accelerometer sampling during a single activity a non-issue relative
    // to its multi-day GPS endurance, so there's no need to gate this any
    // tighter than "is a session actually running."
    function start() as Void {
        if (mEnabled) {
            return;
        }
        var rate = SAMPLE_RATE_HZ;
        var maxRate = Sensor.getMaxSampleRateForSensorType(:accelerometer);
        if (maxRate != null && (maxRate as Lang.Number) < rate) {
            rate = maxRate as Lang.Number;
        }
        Sensor.registerSensorDataListener(method(:onSensorData), {
            :period => SENSOR_PERIOD_SECONDS,
            :accelerometer => { :enabled => true, :sampleRate => rate }
        });
        mEnabled = true;
    }

    function stop() as Void {
        if (!mEnabled) {
            return;
        }
        Sensor.unregisterSensorDataListener();
        mEnabled = false;
    }

    function onSensorData(sensorData as Sensor.SensorData) as Void {
        var accel = sensorData.accelerometerData;
        if (accel == null) {
            return;
        }
        var xs = accel.x;
        var ys = accel.y;
        var zs = accel.z;
        if (xs == null || ys == null || zs == null) {
            return;
        }
        var n = xs.size();
        for (var i = 0; i < n; i += 1) {
            var x = xs[i].toFloat();
            var y = ys[i].toFloat();
            var z = zs[i].toFloat();
            var magnitude = Math.sqrt(x * x + y * y + z * z);
            mBaseline = mBaseline * (1.0 - BASELINE_ALPHA) + magnitude * BASELINE_ALPHA;
            mSamplesSinceLastPeak += 1;
            if (magnitude - mBaseline > PEAK_THRESHOLD_MILLIG && mSamplesSinceLastPeak >= REFRACTORY_SAMPLES) {
                mCurrentSecondPeaks += 1;
                mSamplesSinceLastPeak = 0;
            }
        }
        // One callback batch corresponds to one SENSOR_PERIOD_SECONDS
        // bucket -- advance the rolling window by exactly one slot.
        mPeakCountsPerSecond[mPeakCountsIndex] = mCurrentSecondPeaks;
        mPeakCountsIndex = (mPeakCountsIndex + 1) % CADENCE_WINDOW_SECONDS;
        mCurrentSecondPeaks = 0;
    }

    // Wrist-motion cycles per minute, averaged over the trailing
    // CADENCE_WINDOW_SECONDS. Meaningful in any activity state (walking,
    // skating) -- it's the caller's job to label it, not this class's.
    function getCadence() as Lang.Number {
        var total = 0;
        for (var i = 0; i < CADENCE_WINDOW_SECONDS; i += 1) {
            total += mPeakCountsPerSecond[i] as Lang.Number;
        }
        return (total * 60) / CADENCE_WINDOW_SECONDS;
    }
}
