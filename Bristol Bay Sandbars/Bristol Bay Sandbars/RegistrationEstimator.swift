import Foundation

// MARK: - Registration Estimator (pure Swift, no UI dependencies)

public struct RegSnapshot: Equatable {
    public var driftPermits: Int?
    public var dualPermits: Int?
    public var driftBoats: Int?

    public init(driftPermits: Int?, dualPermits: Int?, driftBoats: Int?) {
        self.driftPermits = driftPermits
        self.dualPermits = dualPermits
        self.driftBoats = driftBoats
    }
}

public struct OpsSnapshot: Equatable {
    public var driftOpenHours: Double?
    public var driftDeliveries: Int?
    public var sockeyeDaily: Int?

    public init(driftOpenHours: Double?, driftDeliveries: Int?, sockeyeDaily: Int?) {
        self.driftOpenHours = driftOpenHours
        self.driftDeliveries = driftDeliveries
        self.sockeyeDaily = sockeyeDaily
    }
}

public struct RegistrationEstimatorDay: Equatable {
    public var date: String            // "YYYY-MM-DD"
    public var ops: OpsSnapshot
    public var regObserved: RegSnapshot?   // non-nil in observed window; nil post-window

    public init(date: String, ops: OpsSnapshot, regObserved: RegSnapshot?) {
        self.date = date
        self.ops = ops
        self.regObserved = regObserved
    }
}

public struct DateWindow: Equatable {
    public var startMMDD: String   // "07-09"
    public var endMMDD: String     // "07-16"

    public init(startMMDD: String, endMMDD: String) {
        self.startMMDD = startMMDD
        self.endMMDD = endMMDD
    }
}

public struct RegistrationWeights: Equatable {
    public var wHours: Double
    public var wDeliveries: Double
    public var wCatch: Double

    public init(wHours: Double, wDeliveries: Double, wCatch: Double) {
        self.wHours = wHours
        self.wDeliveries = wDeliveries
        self.wCatch = wCatch
    }
}

public struct RegistrationSignals: Equatable {
    public var hoursOpen: Double
    public var deliveries: Int
    public var sockeye: Int

    public var sHours: Double
    public var sDeliveries: Double
    public var sCatch: Double

    public var boatsFromDeliveries: Double
    public var boatsFromCatch: Double
}

public struct RegistrationBaselines: Equatable {
    public var boatsBase: Double
    public var permitsBase: Double
    public var dualBase: Double

    public var permitsPerBoat: Double
    public var dualPerBoat: Double

    public var deliveriesPerBoatObserved: Double
    public var catchPerBoatObserved: Double

    public var boatsMaxObserved: Double
    public var boatsMinFloor: Double
}

public struct RegistrationEstimate: Equatable {
    public var date: String

    public var driftBoats: Int
    public var driftPermits: Int
    public var dualPermits: Int

    public var confidence: Double
    public var isEstimated: Bool

    public var signals: RegistrationSignals
    public var weights: RegistrationWeights

    public var rawBoatEstimate: Double
    public var clampedBoatEstimate: Double
    public var smoothedBoatEstimate: Double

    public var notes: [String]
}

public struct RegistrationConfidenceOverrides: Equatable {
    public var hd: Double
    public var one: Double
    public var onlyCatch: Double
    public var none: Double

    public init(hd: Double, one: Double, onlyCatch: Double, none: Double) {
        self.hd = hd
        self.one = one
        self.onlyCatch = onlyCatch
        self.none = none
    }
}

public struct RegistrationEstimatorDistrictOverride: Equatable {
    public var weightsOverride: RegistrationWeights?
    public var treatZeroSignalAsZeroBoats: Bool?
    public var confidenceOverrides: RegistrationConfidenceOverrides?

    // Smoothing overrides
    public var smoothingAlphaOverride: Double?

    // Daily rate limit overrides (applied after smoothing when there is any signal)
    public var maxDailyDecreaseFractionOverride: Double?
    public var maxDailyIncreaseFractionOverride: Double?

    // Adaptive smoothing overrides
    public var sharpDropThresholdOverride: Double?
    public var boostedAlphaFloorOverride: Double?

    // Deliveries EMA smoothing override
    public var deliveriesEmaAlphaOverride: Double?

    // Cap/bounds overrides
    public var maxIncreaseOverBaselineOverride: Double?
    public var allowCapExceedObservedMaxOverride: Bool?
    public var capExceedObservedMaxMultiplierOverride: Double?

    // ✅ NEW: Post-window anchoring overrides
    public var postWindowAnchorDaysOverride: Int?
    public var postWindowAnchorStrengthOverride: Double?

    public init(
        weightsOverride: RegistrationWeights? = nil,
        treatZeroSignalAsZeroBoats: Bool? = nil,
        confidenceOverrides: RegistrationConfidenceOverrides? = nil,
        smoothingAlphaOverride: Double? = nil,
        maxDailyDecreaseFractionOverride: Double? = nil,
        maxDailyIncreaseFractionOverride: Double? = nil,
        sharpDropThresholdOverride: Double? = nil,
        boostedAlphaFloorOverride: Double? = nil,
        deliveriesEmaAlphaOverride: Double? = nil,
        maxIncreaseOverBaselineOverride: Double? = nil,
        allowCapExceedObservedMaxOverride: Bool? = nil,
        capExceedObservedMaxMultiplierOverride: Double? = nil,
        postWindowAnchorDaysOverride: Int? = nil,
        postWindowAnchorStrengthOverride: Double? = nil
    ) {
        self.weightsOverride = weightsOverride
        self.treatZeroSignalAsZeroBoats = treatZeroSignalAsZeroBoats
        self.confidenceOverrides = confidenceOverrides
        self.smoothingAlphaOverride = smoothingAlphaOverride
        self.maxDailyDecreaseFractionOverride = maxDailyDecreaseFractionOverride
        self.maxDailyIncreaseFractionOverride = maxDailyIncreaseFractionOverride
        self.sharpDropThresholdOverride = sharpDropThresholdOverride
        self.boostedAlphaFloorOverride = boostedAlphaFloorOverride
        self.deliveriesEmaAlphaOverride = deliveriesEmaAlphaOverride
        self.maxIncreaseOverBaselineOverride = maxIncreaseOverBaselineOverride
        self.allowCapExceedObservedMaxOverride = allowCapExceedObservedMaxOverride
        self.capExceedObservedMaxMultiplierOverride = capExceedObservedMaxMultiplierOverride
        self.postWindowAnchorDaysOverride = postWindowAnchorDaysOverride
        self.postWindowAnchorStrengthOverride = postWindowAnchorStrengthOverride
    }
}

public struct RegistrationEstimatorConfig: Equatable {

    public var observedWindow: DateWindow              // e.g. 07-09..07-16
    public var estimateStartMMDD: String               // typically "07-17"

    // signal normalization
    public var hoursMaxPerDay: Double                  // 24
    public var signalCapMultiplier: Double             // 1.2

    // deliveries/boat rule
    public var deliveriesPerBoatMinimum: Double        // 0.25
    public var deliveriesPerBoatHardRuleHoursThreshold: Double // 16
    public var deliveriesPerBoatHardRuleValue: Double          // 1.5
    public var useDeliveriesHardRule: Bool

    // weights
    public var baseWeights: RegistrationWeights        // wH/wD/wC

    // opener boost
    public var openerHoursThreshold: Double            // >0
    public var openerDeliveryWeightBoost: Double       // +0.10
    public var openerHoursWeightBoost: Double          // +0.05
    public var openerCatchWeightBoost: Double          // +0.00

    // missing data
    public var renormalizeWeightsWhenMissing: Bool

    // confidence
    public var confidenceWhenHoursAndDeliveries: Double
    public var confidenceWhenOneOfHoursDeliveries: Double
    public var confidenceWhenOnlyCatch: Double
    public var confidenceWhenNoSignals: Double

    // bounds (baseline cap)
    public var maxIncreaseOverBaseline: Double         // 1.05
    public var minFractionOfBaseline: Double           // 0.15

    // bounds (observed-max cap)
    public var useHardCapFromObservedMax: Bool
    public var hardCapSlackOverObservedMax: Double     // e.g. 1.02

    // ✅ NEW: allow cap to exceed observed max by a configured multiplier.
    public var allowCapExceedObservedMax: Bool
    public var capExceedObservedMaxMultiplier: Double  // e.g. 1.20

    // smoothing
    public var smoothingAlpha: Double                  // 0.35

    // Adaptive smoothing (used by adaptiveSmoothingAlpha)
    public var sharpDropThreshold: Double          // e.g. 0.25
    public var boostedAlphaFloor: Double           // e.g. 0.75

    // Deliveries EMA smoothing (applied BEFORE computing signals)
    // Alpha in [0,1]. Higher = more reactive, lower = smoother.
    public var deliveriesEmaAlpha: Double

    // persistence / daily rate limits (applied when there is any signal)
    // Example: 0.20 means boats can change at most 20% day-over-day unless signals are zero.
    public var maxDailyDecreaseFraction: Double        // e.g. 0.15
    public var maxDailyIncreaseFraction: Double        // e.g. 0.20

    // zero-signal behavior
    public var treatZeroSignalAsZeroBoats: Bool
    public var latentFractionOnZeroSignal: Double      // 0.10

    // ratio clamps
    public var permitsPerBoatClamp: ClosedRange<Double> // 0.6...1.4
    public var dualPerBoatClamp: ClosedRange<Double>    // 0.0...1.0

    // ✅ NEW: post-window anchoring fields
    public var postWindowAnchorDays: Int              // number of days after 07-16 to partially anchor
    public var postWindowAnchorStrength: Double       // 0..1 fraction of prior value to keep on first day

    // per-district overrides
    public var districtOverrides: [String: RegistrationEstimatorDistrictOverride]

    public func resolved(forDistrictKey districtKey: String) -> RegistrationEstimatorConfig {
        // Normalize keys so callers can pass e.g. "Naknek-Kvichak" or "naknek-kvichak".
        let key = districtKey.lowercased()
        guard let o = districtOverrides[key] else { return self }
        var c = self
        if let w = o.weightsOverride { c.baseWeights = w }
        if let z = o.treatZeroSignalAsZeroBoats { c.treatZeroSignalAsZeroBoats = z }
        if let conf = o.confidenceOverrides {
            c.confidenceWhenHoursAndDeliveries = conf.hd
            c.confidenceWhenOneOfHoursDeliveries = conf.one
            c.confidenceWhenOnlyCatch = conf.onlyCatch
            c.confidenceWhenNoSignals = conf.none
        }

        if let a = o.smoothingAlphaOverride { c.smoothingAlpha = a }
        if let down = o.maxDailyDecreaseFractionOverride { c.maxDailyDecreaseFraction = down }
        if let up = o.maxDailyIncreaseFractionOverride { c.maxDailyIncreaseFraction = up }
        if let t = o.sharpDropThresholdOverride { c.sharpDropThreshold = t }
        if let b = o.boostedAlphaFloorOverride { c.boostedAlphaFloor = b }
        if let dema = o.deliveriesEmaAlphaOverride { c.deliveriesEmaAlpha = dema }
        if let mib = o.maxIncreaseOverBaselineOverride { c.maxIncreaseOverBaseline = mib }
        if let allow = o.allowCapExceedObservedMaxOverride { c.allowCapExceedObservedMax = allow }
        if let mult = o.capExceedObservedMaxMultiplierOverride { c.capExceedObservedMaxMultiplier = mult }
        // ✅ Apply post-window anchoring overrides if present
        if let pwaDays = o.postWindowAnchorDaysOverride { c.postWindowAnchorDays = pwaDays }
        if let pwaStrength = o.postWindowAnchorStrengthOverride { c.postWindowAnchorStrength = pwaStrength }
        return c
    }

    public static func `default`() -> RegistrationEstimatorConfig {
        var cfg = RegistrationEstimatorConfig(
            observedWindow: DateWindow(startMMDD: "07-09", endMMDD: "07-16"),
            estimateStartMMDD: "07-17",

            hoursMaxPerDay: 24,
            signalCapMultiplier: 1.7,

            deliveriesPerBoatMinimum: 0.8,
            deliveriesPerBoatHardRuleHoursThreshold: 24,
            deliveriesPerBoatHardRuleValue: 1.5,
            useDeliveriesHardRule: true,

            baseWeights: RegistrationWeights(wHours: 0.10, wDeliveries: 0.80, wCatch: 0.10),

            openerHoursThreshold: 0.0,
            openerDeliveryWeightBoost: 0.10,
            openerHoursWeightBoost: 0.05,
            openerCatchWeightBoost: 0.00,

            renormalizeWeightsWhenMissing: true,

            confidenceWhenHoursAndDeliveries: 1.0,
            confidenceWhenOneOfHoursDeliveries: 0.7,
            confidenceWhenOnlyCatch: 0.4,
            confidenceWhenNoSignals: 0.1,

            maxIncreaseOverBaseline: 1.4,
            minFractionOfBaseline: 0.01,

            useHardCapFromObservedMax: true,
            hardCapSlackOverObservedMax: 1.02,

            allowCapExceedObservedMax: true,
            capExceedObservedMaxMultiplier: 1.5,

            smoothingAlpha: 0.20,
            sharpDropThreshold: 0.90,
            boostedAlphaFloor: 0.20,
            deliveriesEmaAlpha: 0.10,

            maxDailyDecreaseFraction: 0.30,
            maxDailyIncreaseFraction: 0.25,

            treatZeroSignalAsZeroBoats: false,
            latentFractionOnZeroSignal: 0.10,

            permitsPerBoatClamp: 0.6...1.4,
            dualPerBoatClamp: 0.0...1.0,

            postWindowAnchorDays: 0,
            postWindowAnchorStrength: 0.0,

            districtOverrides: [:]
        )

        // ✅ Togiak special-case tuning
        cfg.districtOverrides["togiak"] = RegistrationEstimatorDistrictOverride(
            // Togiak: deliveries-per-boat ratio is the primary driver post 7/16.
            // Hours/catch are noisier; keep them small.
            weightsOverride: RegistrationWeights(wHours: 0.03, wDeliveries: 0.95, wCatch: 0.02),

            // Keep zero-signal as a latent fleet (don’t collapse to 0 immediately)
            treatZeroSignalAsZeroBoats: false,

            // Make the estimate responsive enough to taper when deliveries taper,
            // without re-introducing spiky day-to-day peaks/troughs.
            smoothingAlphaOverride: 0.12,
            maxDailyDecreaseFractionOverride: 0.5,
            maxDailyIncreaseFractionOverride: 0.15,

            // Trigger faster response when deliveries drop materially vs prior day.
            sharpDropThresholdOverride: 0.35,
            boostedAlphaFloorOverride: 0.55,

            // Deliveries EMA: mild smoothing on increases; drops are handled faster via asymmetric EMA in code.
            deliveriesEmaAlphaOverride: 0.08,

            // Keep caps tighter for Togiak so a single high-delivery day can't peg boats too high.
            maxIncreaseOverBaselineOverride: 1.25,
            allowCapExceedObservedMaxOverride: false
        )

        // ✅ Bristol Bay districts where daily boat count should be more responsive:
        // Naknek-Kvichak, Egegik, Ugashik, Nushagak
        //
        // Goals:
        // - Reduce smoothing (more day-to-day responsiveness)
        // - Put more weight on the observed 07/09–07/16 deliveries-per-boat ratio
        // - Allow faster snap-back on a big harvest/delivery day after closures/low days
        let dailyRatioDrivenDistricts: [String] = [
            "naknek_kvichak",
            "egegik",
            "ugashik",
            "nushagak"
        ]

        for k in dailyRatioDrivenDistricts {
            var o = RegistrationEstimatorDistrictOverride()
            o.weightsOverride = RegistrationWeights(wHours: 0.05, wDeliveries: 0.85, wCatch: 0.10)

            // reduce smoothing / more daily accuracy
            o.smoothingAlphaOverride = 0.55
            o.deliveriesEmaAlphaOverride = 0.60

            // allow snap-back on big reopen days
            o.maxDailyDecreaseFractionOverride = 0.35
            o.maxDailyIncreaseFractionOverride = 1.25

            // sharper reaction when things change fast
            o.sharpDropThresholdOverride = 0.30
            o.boostedAlphaFloorOverride = 0.80

            cfg.districtOverrides[k] = o
        }

        return cfg
    }
}

// MARK: - Namespace

public enum RegistrationEstimator {

    // MARK: - Estimator API

    public static func estimatePostWindowRegistration(
        districtKey: String,
        year: Int,
        days: [RegistrationEstimatorDay],
        config: RegistrationEstimatorConfig
    ) -> [String: RegistrationEstimate] {

        let cfg = config.resolved(forDistrictKey: districtKey)

        guard let baselines = RegistrationEstimator.calibrateRegistrationBaselines(
            districtKey: districtKey,
            year: year,
            days: days,
            config: cfg
        ) else {
            return [:]
        }

        let startDate = RegistrationEstimator.yearDateString(year: year, mmdd: cfg.estimateStartMMDD)
        let sortedDays = days.sorted { $0.date < $1.date }

        var out: [String: RegistrationEstimate] = [:]

        let dk = districtKey.lowercased()
        let isTogiak = (dk == "togiak")
        let isDailyRatioDistrict = (dk == "naknek-kvichak" || dk == "egegik" || dk == "ugashik" || dk == "nushagak")
        let avoidBoatsLEDeliveriesCaps = isTogiak || isDailyRatioDistrict

        // Seed smoothing with last observed boats at the observed window end (e.g., 07-16) if available.
        let observedEndDate = RegistrationEstimator.yearDateString(year: year, mmdd: cfg.observedWindow.endMMDD)
        let seededPrev: Double? = sortedDays
            .first(where: { $0.date == observedEndDate })
            .flatMap { $0.regObserved?.driftBoats }
            .map(Double.init)

        var prevSmoothed: Double? = seededPrev

        // Optional moving-average smoothing:
        // - Togiak: heavy trailing average to reduce timing spikes
        // - Daily-ratio districts: disable trailing average (more accurate day-to-day)
        // - Others: small trailing average
        let movingAverageWindowSize: Int = isTogiak ? 7 : (isDailyRatioDistrict ? 1 : 3)
        var rollingWindow: [Double] = []
        rollingWindow.reserveCapacity(movingAverageWindowSize)

        // Track previous day's deliveries (raw) for adaptive smoothing.
        var prevDeliveries: Int? = sortedDays
            .first(where: { $0.date == observedEndDate })
            .flatMap { $0.ops.driftDeliveries }

        // ✅ Smooth deliveries first (EMA), then compute signals from the smoothed deliveries.
        let demaAlpha = RegistrationEstimator.clamp(cfg.deliveriesEmaAlpha, 0.0...1.0)
        var prevDeliveriesEma: Double? = prevDeliveries.map(Double.init)

        // ✅ Late-season "no data" behavior:
        // When BOTH harvest (sockeyeDaily) and delivery (driftDeliveries) inputs disappear (nil),
        // taper registration linearly to 0 over 5 days.
        let noDataTaperDays: Int = 5
        var noDataTaperDayIndex: Int = 0
        var noDataTaperStartBoats: Double? = nil

        // Track consecutive "low activity" days for the daily-ratio districts so we can
        // snap back quickly on a large harvest/delivery day after closures.
        var consecutiveLowActivityDays: Int = 0

        // Track consecutive days with 0 deliveries AND 0 catch (zeros are treated as real observed zeros).
        // This is used to avoid keeping Togiak boats artificially high during extended stretches of no activity.
        var consecutiveNoDelNoSockDays: Int = 0

        for d in sortedDays where d.date >= startDate {
            // IMPORTANT: Do not generate post-window *estimated* registration for Togiak 2020.
            // We now store the 2020-07-17..2020-08-20 registration directly in the offline DB.
            if isTogiak && year == 2020 && d.date >= "2020-07-17" && d.date <= "2020-08-20" {
                continue
            }

            // Detect when key post-window inputs are no longer available.
            // (Nil means "not reported"; zeros are treated as real observed zeros.)
            let harvestAndDeliveryMissing = (d.ops.driftDeliveries == nil) && (d.ops.sockeyeDaily == nil)
            if harvestAndDeliveryMissing {
                // Start or continue a linear taper from the last known registration.
                if noDataTaperDayIndex == 0 {
                    noDataTaperStartBoats = max(0.0, prevSmoothed ?? 0.0)
                    rollingWindow.removeAll(keepingCapacity: true)
                }

                noDataTaperDayIndex += 1

                let startBoats = max(0.0, noDataTaperStartBoats ?? 0.0)
                let frac = max(0.0, 1.0 - (Double(noDataTaperDayIndex) / Double(max(1, noDataTaperDays))))
                let taperedBoats = startBoats * frac

                let permits = RegistrationEstimator.permitsFromBoats(boats: taperedBoats, baselines: baselines, config: cfg)

                // Signals are unavailable here; keep them zeroed for clarity.
                let zeroOps = OpsSnapshot(driftOpenHours: nil, driftDeliveries: nil, sockeyeDaily: nil)
                let signals = RegistrationEstimator.computeSignals(ops: zeroOps, baselines: baselines, config: cfg)
                let weights = RegistrationEstimator.effectiveWeights(ops: zeroOps, baseWeights: cfg.baseWeights, config: cfg)

                let result = RegistrationEstimate(
                    date: d.date,
                    driftBoats: permits.driftBoats,
                    driftPermits: permits.driftPermits,
                    dualPermits: permits.dualPermits,
                    confidence: cfg.confidenceWhenNoSignals,
                    isEstimated: true,
                    signals: signals,
                    weights: weights,
                    rawBoatEstimate: taperedBoats,
                    clampedBoatEstimate: taperedBoats,
                    smoothedBoatEstimate: taperedBoats,
                    notes: ["no_data_linear_taper_\(noDataTaperDayIndex)_of_\(noDataTaperDays)"]
                )

                out[d.date] = result
                prevSmoothed = taperedBoats
                prevDeliveries = nil
                prevDeliveriesEma = nil
                consecutiveNoDelNoSockDays = 0
                consecutiveLowActivityDays = 0
                continue
            } else {
                // Data is present again; reset taper state.
                noDataTaperDayIndex = 0
                noDataTaperStartBoats = nil
            }

            // Deliveries EMA smoothing
            let curDelRaw = max(0, d.ops.driftDeliveries ?? 0)
            let rawDeliveriesForCap = curDelRaw

            let curDelEma: Double = {
                guard let prev = prevDeliveriesEma else { return Double(curDelRaw) }

                if isTogiak {
                    // Asymmetric EMA:
                    // - Smooth increases (avoid spikes from delivery timing)
                    // - React faster on decreases (avoid keeping boats artificially high)
                    let alphaUp = demaAlpha
                    let alphaDown = RegistrationEstimator.clamp(max(alphaUp, 0.5), 0.0...1.0)
                    let a = (Double(curDelRaw) < prev) ? alphaDown : alphaUp
                    return a * Double(curDelRaw) + (1.0 - a) * prev
                }

                return demaAlpha * Double(curDelRaw) + (1.0 - demaAlpha) * prev
            }()
            prevDeliveriesEma = curDelEma

            // Use smoothed deliveries for signal computation
            var opsForSignals = d.ops
            opsForSignals.driftDeliveries = Int(round(curDelEma))

            let signals = RegistrationEstimator.computeSignals(
                ops: opsForSignals,
                baselines: baselines,
                config: cfg
            )

            let weights = RegistrationEstimator.effectiveWeights(
                ops: opsForSignals,
                baseWeights: cfg.baseWeights,
                config: cfg
            )

            // Track consecutive zero-delivery+zero-catch days (post-smoothing).
            if signals.deliveries == 0 && signals.sockeye == 0 {
                consecutiveNoDelNoSockDays += 1
            } else {
                consecutiveNoDelNoSockDays = 0
            }

            // --- Daily-ratio districts: detect "rebound" days ---
            // A rebound day is a large harvest/delivery day after >=2 consecutive low activity days.
            let priorLowStreak = consecutiveLowActivityDays

            let lowActivityToday: Bool = {
                if signals.deliveries == 0 && signals.sockeye == 0 { return true }
                let lowDelBoats = signals.boatsFromDeliveries < baselines.boatsBase * 0.20
                let lowCatchBoats = signals.boatsFromCatch < baselines.boatsBase * 0.20
                return lowDelBoats && lowCatchBoats
            }()

            if lowActivityToday {
                consecutiveLowActivityDays += 1
            } else {
                consecutiveLowActivityDays = 0
            }

            let bigSignalToday: Bool = {
                // Either deliveries- or catch-implied boats exceed baseline materially.
                return (signals.boatsFromDeliveries >= baselines.boatsBase * 1.10) ||
                       (signals.boatsFromCatch >= baselines.boatsBase * 1.10)
            }()

            let isReboundDay = isDailyRatioDistrict && (priorLowStreak >= 2) && (!lowActivityToday) && bigSignalToday

            let est = RegistrationEstimator.estimateBoatsForDay(
                date: d.date,
                signals: signals,
                weights: weights,
                baselines: baselines,
                previousSmoothedBoats: prevSmoothed,
                previousDayDeliveries: prevDeliveries,
                config: cfg
            )

            // Rate-limit day-to-day swings (when we have a previous value).
            var extraNotes: [String] = []
            var limitedSmoothed: Double = {
                guard let prev = prevSmoothed else { return est.smoothed }

                // On rebound days, jump much closer to today's signal-based estimate
                // (less smoothing) so we can capture big reopen/harvest days.
                var candidate = est.smoothed
                if isReboundDay {
                    let reboundAlpha = 0.85
                    candidate = reboundAlpha * est.clamped + (1.0 - reboundAlpha) * prev
                    extraNotes.append("rebound_boost_alpha_0.85")
                }

                // Relax the up rate-limit on rebound days so we can "snap back" quickly.
                // up=2.0 => maxAllowed = prev * (1 + 2.0) = 3x
                let upOverride: Double? = isReboundDay ? max(cfg.maxDailyIncreaseFraction, 2.0) : nil

                return RegistrationEstimator.applyDailyRateLimit(
                    current: candidate,
                    previous: prev,
                    config: cfg,
                    downOverride: nil,
                    upOverride: upOverride
                )
            }()
            var didCarryForward = false

            // Optional deliveries-based floor for NON-Togiak:
            // - For daily-ratio districts we keep the floor (helps snap up on big delivery days)
            // - But we avoid the old "boats <= deliveries" caps because deliveries-per-boat can be < 1.
            if signals.deliveries > 0 && !isTogiak {
                let target = RegistrationEstimator.deliveriesPerBoatTarget(
                    hours: signals.hoursOpen,
                    deliveriesPerBoatObserved: baselines.deliveriesPerBoatObserved,
                    config: cfg
                )

                let boatsFromDel = Double(signals.deliveries) / max(cfg.deliveriesPerBoatMinimum, target)

                // Floor: don't let smoothing push boats below what deliveries imply
                limitedSmoothed = max(limitedSmoothed, boatsFromDel)

                // Legacy cap boats<=deliveries is disabled for districts where deliveries/boat may be <1.
                if !avoidBoatsLEDeliveriesCaps {
                    limitedSmoothed = min(limitedSmoothed, Double(signals.deliveries))
                }
            }

            // When both deliveries and catch are zero, don't keep Togiak pinned at yesterday forever.
            // Hold only briefly for a likely one-day "weather/no-delivery" gap, then decay.
            if signals.deliveries == 0 && signals.sockeye == 0, let prev = prevSmoothed {
                if isTogiak {
                    if signals.hoursOpen > 0 && consecutiveNoDelNoSockDays == 1 {
                        limitedSmoothed = prev
                        extraNotes.append("togiak_zero_del_sock_hold1")
                    } else {
                        let down = RegistrationEstimator.clamp(cfg.maxDailyDecreaseFraction, 0.0...1.0)
                        limitedSmoothed = prev * (1.0 - down)
                        extraNotes.append("togiak_zero_del_sock_decay")
                    }
                } else {
                    let down = RegistrationEstimator.clamp(cfg.maxDailyDecreaseFraction, 0.0...1.0)
                    limitedSmoothed = prev * (1.0 - down)
                }
                didCarryForward = true
            }

            // ✅ Extra smoothing: trailing moving average.
            if movingAverageWindowSize > 1 {
                rollingWindow.append(limitedSmoothed)
                if rollingWindow.count > movingAverageWindowSize { rollingWindow.removeFirst() }

                let avg = rollingWindow.reduce(0.0, +) / Double(rollingWindow.count)
                var rolled = avg

                // Re-apply daily rate limit against previous day after moving-average smoothing.
                if let prev = prevSmoothed {
                    let upOverride: Double? = isReboundDay ? max(cfg.maxDailyIncreaseFraction, 2.0) : nil
                    rolled = RegistrationEstimator.applyDailyRateLimit(
                        current: rolled,
                        previous: prev,
                        config: cfg,
                        downOverride: nil,
                        upOverride: upOverride
                    )
                }

                // Re-apply deliveries caps after rolling ONLY for conservative districts.
                if signals.deliveries > 0 && !avoidBoatsLEDeliveriesCaps {
                    let target = RegistrationEstimator.deliveriesPerBoatTarget(
                        hours: signals.hoursOpen,
                        deliveriesPerBoatObserved: baselines.deliveriesPerBoatObserved,
                        config: cfg
                    )
                    let boatsFromDel = Double(signals.deliveries) / max(cfg.deliveriesPerBoatMinimum, target)

                    rolled = min(rolled, boatsFromDel)

                    if rawDeliveriesForCap > 0 {
                        rolled = min(rolled, Double(rawDeliveriesForCap))
                    }
                }

                limitedSmoothed = rolled
            }

            if rawDeliveriesForCap > 0 && !avoidBoatsLEDeliveriesCaps {
                limitedSmoothed = min(limitedSmoothed, Double(rawDeliveriesForCap))
            }
            limitedSmoothed = max(0, limitedSmoothed)

            let permits = RegistrationEstimator.permitsFromBoats(boats: limitedSmoothed, baselines: baselines, config: cfg)

            let conf = RegistrationEstimator.confidenceForDay(
                driftOpenHours: signals.hoursOpen,
                driftDeliveries: signals.deliveries,
                sockeye: signals.sockeye,
                config: cfg
            )

            var notes = est.notes + extraNotes
            if movingAverageWindowSize > 1 {
                notes.append("rolling_avg_\(movingAverageWindowSize)d")
            } else {
                notes.append("rolling_avg_off")
            }

            let result = RegistrationEstimate(
                date: d.date,
                driftBoats: permits.driftBoats,
                driftPermits: permits.driftPermits,
                dualPermits: permits.dualPermits,
                confidence: conf,
                isEstimated: true,
                signals: signals,
                weights: weights,
                rawBoatEstimate: est.raw,
                clampedBoatEstimate: est.clamped,
                smoothedBoatEstimate: limitedSmoothed,
                notes: notes
            )

            out[d.date] = result
            prevSmoothed = limitedSmoothed
            prevDeliveries = signals.deliveries
        }

        return out
    }

    // MARK: - Calibration

    public static func calibrateRegistrationBaselines(
        districtKey: String,
        year: Int,
        days: [RegistrationEstimatorDay],
        config: RegistrationEstimatorConfig
    ) -> RegistrationBaselines? {

        let start = RegistrationEstimator.yearDateString(year: year, mmdd: config.observedWindow.startMMDD)
        let end   = RegistrationEstimator.yearDateString(year: year, mmdd: config.observedWindow.endMMDD)
        let window = days.filter { $0.date >= start && $0.date <= end }

        let boatsVals = window.compactMap { $0.regObserved?.driftBoats }.map(Double.init)
        guard let boatsBase = RegistrationEstimator.robustMedian(boatsVals), boatsBase > 0 else { return nil }

        let boatsMaxObserved = RegistrationEstimator.robustMax(boatsVals) ?? boatsBase

        let permitsVals = window.compactMap { $0.regObserved?.driftPermits }.map(Double.init)
        let dualVals    = window.compactMap { $0.regObserved?.dualPermits }.map(Double.init)

        let permitsBase = RegistrationEstimator.robustMedian(permitsVals) ?? boatsBase
        let dualBase    = RegistrationEstimator.robustMedian(dualVals) ?? 0

        var rP = permitsBase / max(1.0, boatsBase)
        var rD = dualBase / max(1.0, boatsBase)

        rP = RegistrationEstimator.clamp(rP, config.permitsPerBoatClamp)
        rD = RegistrationEstimator.clamp(rD, config.dualPerBoatClamp)

        // Weighted-average deliveries/boat over the best available "observed" period:
        // totalDeliveries / totalBoats (more stable than median of per-day ratios).
        //
        // For Togiak, we prefer the longer period where observed registration exists
        // (typically 06/20–07/16) to better capture the true deliveries-per-boat behavior.
        let ratioStartMMDD: String = (districtKey.lowercased() == "togiak") ? "06-20" : config.observedWindow.startMMDD
        let ratioStart = RegistrationEstimator.yearDateString(year: year, mmdd: ratioStartMMDD)
        let ratioWindow = days.filter { $0.date >= ratioStart && $0.date <= end }

        var totalDeliveries: Double = 0
        var totalBoats: Double = 0

        for d in ratioWindow {
            let b = Double(d.regObserved?.driftBoats ?? 0)
            guard b > 0 else { continue }

            let del = Double(d.ops.driftDeliveries ?? 0)

            // Use only days with actual deliveries reported.
            // Days with del==0 are often closures/weather/reporting gaps and will bias the ratio downward
            // (which would inflate post-window boat estimates).
            guard del > 0 else { continue }

            totalDeliveries += del
            totalBoats += b
        }

        let deliveriesPerBoatObservedRaw: Double = {
            guard totalBoats > 0 else { return 1.0 }
            return totalDeliveries / totalBoats
        }()

        let deliveriesPerBoatObserved = max(
            config.deliveriesPerBoatMinimum,
            deliveriesPerBoatObservedRaw
        )

        let cpbVals: [Double] = window.compactMap { d in
            let b = Double(d.regObserved?.driftBoats ?? 0)
            guard b > 0 else { return nil }
            let c = Double(d.ops.sockeyeDaily ?? 0)
            guard c > 0 else { return nil }
            return c / b
        }

        let catchPerBoatObserved = max(1.0, RegistrationEstimator.robustMedian(cpbVals) ?? 1.0)

        let boatsMinFloor = boatsBase * config.minFractionOfBaseline

        return RegistrationBaselines(
            boatsBase: boatsBase,
            permitsBase: permitsBase,
            dualBase: dualBase,
            permitsPerBoat: rP,
            dualPerBoat: rD,
            deliveriesPerBoatObserved: deliveriesPerBoatObserved,
            catchPerBoatObserved: catchPerBoatObserved,
            boatsMaxObserved: boatsMaxObserved,
            boatsMinFloor: boatsMinFloor
        )
    }

    public static func robustMedian(_ values: [Double]) -> Double? {
        let clean = values.filter { $0.isFinite }.sorted()
        guard !clean.isEmpty else { return nil }
        let mid = clean.count / 2
        if clean.count % 2 == 1 { return clean[mid] }
        return 0.5 * (clean[mid - 1] + clean[mid])
    }

    public static func robustMax(_ values: [Double]) -> Double? {
        let clean = values.filter { $0.isFinite }
        return clean.max()
    }

    // MARK: - Signals / weights / confidence

    public static func computeSignals(
        ops: OpsSnapshot,
        baselines: RegistrationBaselines,
        config: RegistrationEstimatorConfig
    ) -> RegistrationSignals {

        let hours = max(0.0, ops.driftOpenHours ?? 0)
        let del = max(0, ops.driftDeliveries ?? 0)
        let sock = max(0, ops.sockeyeDaily ?? 0)

        // Normalize hours to 0..1
        let sHours = RegistrationEstimator.clamp(
            hours / max(1e-9, config.hoursMaxPerDay),
            0.0...1.0
        )

        // --- Deliveries-driven signal (PRIMARY) ---
        // Use the observed-window deliveries/boat ratio as the target, with optional hard rule.
        let delTarget = RegistrationEstimator.deliveriesPerBoatTarget(
            hours: hours,
            deliveriesPerBoatObserved: baselines.deliveriesPerBoatObserved,
            config: config
        )

        let boatsFromDelRaw = Double(del) / max(config.deliveriesPerBoatMinimum, delTarget)

        // IMPORTANT: deliveries can be < boats (not every boat delivers every day).
        // Do NOT cap boats by deliveries here.
        let boatsFromDel: Double = (del > 0) ? boatsFromDelRaw : 0

        let sDeliveries = RegistrationEstimator.clamp(
            boatsFromDel / max(1.0, baselines.boatsBase),
            0.0...(config.signalCapMultiplier)
        )

        // --- Catch-driven signal (SECONDARY) ---
        let boatsFromCatch = Double(sock) / max(1.0, baselines.catchPerBoatObserved)

        let sCatch = RegistrationEstimator.clamp(
            boatsFromCatch / max(1.0, baselines.boatsBase),
            0.0...(config.signalCapMultiplier)
        )

        return RegistrationSignals(
            hoursOpen: hours,
            deliveries: del,
            sockeye: sock,
            sHours: sHours,
            sDeliveries: sDeliveries,
            sCatch: sCatch,
            boatsFromDeliveries: boatsFromDel,
            boatsFromCatch: boatsFromCatch
        )
    }

    public static func deliveriesPerBoatTarget(
        hours: Double,
        deliveriesPerBoatObserved: Double,
        config: RegistrationEstimatorConfig
    ) -> Double {
        var target = deliveriesPerBoatObserved

        if config.useDeliveriesHardRule && hours > config.deliveriesPerBoatHardRuleHoursThreshold {
            target = min(target, config.deliveriesPerBoatHardRuleValue)
        }

        // Clamp deliveries/boat to a realistic range.
        // IMPORTANT: forcing the *lower* bound near 1.0 will UNDER-estimate boats when
        // not every boat delivers every day.
        target = RegistrationEstimator.clamp(target, config.deliveriesPerBoatMinimum...2.0)

        return target
    }

    public static func effectiveWeights(
        ops: OpsSnapshot,
        baseWeights: RegistrationWeights,
        config: RegistrationEstimatorConfig
    ) -> RegistrationWeights {

        var w = baseWeights

        let hours = (ops.driftOpenHours ?? 0)
        let del = (ops.driftDeliveries ?? 0)
        let sock = (ops.sockeyeDaily ?? 0)

        let opener = hours > config.openerHoursThreshold
        if opener {
            w.wDeliveries += config.openerDeliveryWeightBoost
            w.wHours += config.openerHoursWeightBoost
            w.wCatch += config.openerCatchWeightBoost
        }

        if config.renormalizeWeightsWhenMissing {
            let hasH = hours > 0
            let hasD = del > 0
            let hasC = sock > 0
            w = RegistrationEstimator.renormalizeWeights(weights: w, hasHours: hasH, hasDeliveries: hasD, hasCatch: hasC)
        }

        return w
    }

    public static func renormalizeWeights(
        weights: RegistrationWeights,
        hasHours: Bool,
        hasDeliveries: Bool,
        hasCatch: Bool
    ) -> RegistrationWeights {
        var wH = hasHours ? max(0, weights.wHours) : 0
        var wD = hasDeliveries ? max(0, weights.wDeliveries) : 0
        var wC = hasCatch ? max(0, weights.wCatch) : 0

        let sum = wH + wD + wC
        guard sum > 0 else { return weights } // fallback: keep original

        wH /= sum; wD /= sum; wC /= sum
        return RegistrationWeights(wHours: wH, wDeliveries: wD, wCatch: wC)
    }

    public static func confidenceForDay(
        driftOpenHours: Double,
        driftDeliveries: Int,
        sockeye: Int,
        config: RegistrationEstimatorConfig
    ) -> Double {
        let hasH = driftOpenHours > 0
        let hasD = driftDeliveries > 0
        let hasC = sockeye > 0

        if hasH && hasD { return config.confidenceWhenHoursAndDeliveries }
        if hasH || hasD { return config.confidenceWhenOneOfHoursDeliveries }
        if hasC { return config.confidenceWhenOnlyCatch }
        return config.confidenceWhenNoSignals
    }

    // MARK: - Boats / permits

    public static func estimateBoatsForDay(
        date: String,
        signals: RegistrationSignals,
        weights: RegistrationWeights,
        baselines: RegistrationBaselines,
        previousSmoothedBoats: Double?,
        previousDayDeliveries: Int?,
        config: RegistrationEstimatorConfig
    ) -> (raw: Double, clamped: Double, smoothed: Double, notes: [String]) {

        let hasH = signals.hoursOpen > 0
        let hasD = signals.deliveries > 0
        let hasC = signals.sockeye > 0

        var notes: [String] = []
        if !hasH { notes.append("no_hours") }
        if !hasD { notes.append("no_deliveries") }
        if !hasC { notes.append("no_catch") }

        let zeroSignal = !(hasH || hasD || hasC)

        let raw: Double
        if zeroSignal {
            if config.treatZeroSignalAsZeroBoats {
                raw = 0
                notes.append("zero_signal->zero_boats")
            } else {
                raw = baselines.boatsBase * config.latentFractionOnZeroSignal
                notes.append("zero_signal->latent_fleet")
            }
        } else {
            // Make deliveries/boat from the observed window the primary driver.
            // Combine *direct* boat estimates rather than scaling normalized signals by boatsBase.

            let boatsFromHours = baselines.boatsBase * signals.sHours
            let boatsFromDeliveries = signals.boatsFromDeliveries
            let boatsFromCatch = signals.boatsFromCatch

            raw =
                weights.wHours * boatsFromHours +
                weights.wDeliveries * boatsFromDeliveries +
                weights.wCatch * boatsFromCatch
        }

        let clamped = RegistrationEstimator.clampBoats(boatsRaw: raw, baselines: baselines, config: config)

        let smoothed: Double
        if let prev = previousSmoothedBoats {
            let alpha = RegistrationEstimator.adaptiveSmoothingAlpha(
                baseAlpha: config.smoothingAlpha,
                previousDeliveries: previousDayDeliveries,
                currentDeliveries: signals.deliveries,
                config: config
            )
            smoothed = RegistrationEstimator.smoothBoats(current: clamped, previous: prev, alpha: alpha)
        } else {
            smoothed = clamped
        }

        return (raw: raw, clamped: clamped, smoothed: smoothed, notes: notes)
    }

    public static func clampBoats(
        boatsRaw: Double,
        baselines: RegistrationBaselines,
        config: RegistrationEstimatorConfig
    ) -> Double {
        let bMin = max(0.0, baselines.boatsMinFloor)

        // baseline-based cap
        var bMax = baselines.boatsBase * config.maxIncreaseOverBaseline

        // observed-window cap (optional)
        if config.useHardCapFromObservedMax {
            let observedCap = baselines.boatsMaxObserved * config.hardCapSlackOverObservedMax
            bMax = min(bMax, observedCap)
        }

        // ✅ NEW: allow exceeding observed-window max by some multiplier, if enabled
        if config.allowCapExceedObservedMax {
            let exceedCap = baselines.boatsMaxObserved * config.capExceedObservedMaxMultiplier
            bMax = max(bMax, exceedCap)
        }

        // final clamp
        return RegistrationEstimator.clamp(boatsRaw, bMin...max(bMin, bMax))
    }

    public static func smoothBoats(current: Double, previous: Double, alpha: Double) -> Double {
        let a = RegistrationEstimator.clamp(alpha, 0.0...1.0)
        return a * current + (1 - a) * previous
    }

    /// Adaptive smoothing: respond faster only when deliveries drop sharply day-over-day.
    public static func adaptiveSmoothingAlpha(
        baseAlpha: Double,
        previousDeliveries: Int?,
        currentDeliveries: Int,
        config: RegistrationEstimatorConfig
    ) -> Double {
        let base = RegistrationEstimator.clamp(baseAlpha, 0.0...1.0)
        guard let prev = previousDeliveries, prev > 0 else { return base }

        let cur = max(0, currentDeliveries)
        let dropFrac = Double(prev - cur) / Double(prev) // positive when dropping

        let threshold = RegistrationEstimator.clamp(config.sharpDropThreshold, 0.0...1.0)
        let boosted = min(1.0, max(base, RegistrationEstimator.clamp(config.boostedAlphaFloor, 0.0...1.0)))

        return (dropFrac >= threshold) ? boosted : base
    }

    public static func permitsFromBoats(
        boats: Double,
        baselines: RegistrationBaselines,
        config: RegistrationEstimatorConfig
    ) -> (driftPermits: Int, dualPermits: Int, driftBoats: Int) {

        let rp = RegistrationEstimator.clamp(baselines.permitsPerBoat, config.permitsPerBoatClamp)
        let rd = RegistrationEstimator.clamp(baselines.dualPerBoat, config.dualPerBoatClamp)

        let b = max(0, Int(round(boats)))
        let p = max(0, Int(round(Double(b) * rp)))
        let d = max(0, Int(round(Double(b) * rd)))

        return (driftPermits: p, dualPermits: d, driftBoats: b)
    }

    // MARK: - Utilities

    public static func clamp(_ x: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(x, range.lowerBound), range.upperBound)
    }

    public static func yearDateString(year: Int, mmdd: String) -> String {
        String(format: "%04d-%@", year, mmdd)
    }

    // MARK: - Persistence helpers

    public static func applyDailyRateLimit(
        current: Double,
        previous: Double,
        config: RegistrationEstimatorConfig,
        downOverride: Double? = nil,
        upOverride: Double? = nil
    ) -> Double {
        let down = RegistrationEstimator.clamp(downOverride ?? config.maxDailyDecreaseFraction, 0.0...1.0)
        let up = RegistrationEstimator.clamp(upOverride ?? config.maxDailyIncreaseFraction, 0.0...5.0)

        let minAllowed = previous * (1.0 - down)
        let maxAllowed = previous * (1.0 + up)
        return RegistrationEstimator.clamp(current, minAllowed...maxAllowed)
    }
}

// Swap argument order for any RegistrationEstimatorDistrictOverride where maxDailyIncreaseFractionOverride precedes maxDailyDecreaseFractionOverride
