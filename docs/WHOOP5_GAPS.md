# WHOOP 5.0 metric gaps — status and work list

What NOOP can and cannot read from a **WHOOP 5.0 / MG** over BLE, sorted by *why* each thing is
missing, and what would resolve it. The point of the sort: "absent from the wire" and "one capture
away" are different problems, and only the second kind belongs on a work list.

**Hardware this list is written against:** a **WHOOP 5.0** (non-MG). Anything needing an MG's ECG
clasp, a 4.0, or a second strap is marked as such and cannot be verified here — see
[MG ECG](#not-on-this-list-mg-ecg-891) below.

Companion docs: [`WHOOP5_DEEP_DATA.md`](WHOOP5_DEEP_DATA.md) (the R22 unlock and the `@82` SpO₂
candidate), [`BLE_REVERSE_ENGINEERING.md`](BLE_REVERSE_ENGINEERING.md#the-whoop-50-type-47-record-version-18)
(the v18 field map), [`PROTOCOL.md` §10](PROTOCOL.md) (SpO₂ on the wire).

## Two things that are not gaps

Both come up constantly, so they are stated first.

- **HRV is retrieved on a 5.0.** R-R intervals decode straight out of the v18 historical record
  (`rr_count@23`, `rr[i]@24+2i`) and HRV is scored on-device. There is a real 5.0-specific *quality*
  problem with that stream ([W2](#w2-hrv-beat-spread-distrusted-on-50-nights-1451)), but it is a
  degradation, not an absence.
- **Blood oxygen is an every-WHOOP policy, not a 5.0 defect.** `AnalyticsEngine` writes
  `spo2Pct = nil` on every live WHOOP path, 4.0 included
  (`Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift`, Kotlin twin
  `android/…/analytics/AnalyticsEngine.kt`). Only an import ever populates that card ([#548](https://github.com/ryanbr/noop/issues/548)).

The canonical in-code capability set gives a 5/MG a **superset** of the 4.0
(`Packages/WhoopStore/Sources/WhoopStore/WhoopLiveCapabilities.swift` + Kotlin twin):

```
base   = [hr, hrv, skinTemp, sleep, strainLoad]   // every WHOOP over BLE
+ steps                                           // 5.0 / MG only
spo2   excluded on every WHOOP — import-only (#548)
```

---

## The work list

Ordered by leverage, not severity. Each item says what would close it and what can be done on the
strap on hand.

### W1: R-R over-count census on a 5.0/MG ([#1451](https://github.com/ryanbr/noop/issues/1451))

- [ ] Run one history offload on a build carrying the post-[#1452](https://github.com/ryanbr/noop/issues/1452) `rr emit` line
- [ ] Record `offered / inserted / ratio / ratioRep / perSec / modalGap / fill`
- [ ] Post the line on #1451; compare against a 4.0 offload if one is reachable

**Why it is first.** [#1008](https://github.com/ryanbr/noop/issues/1008) /
[#1118](https://github.com/ryanbr/noop/issues/1118) sized the R-R over-count entirely from **4.0**
nights (raw coverage ~1.74×). Nobody has measured a 5.0, and the answer decides which fix is correct.
It also sits upstream of [W2](#w2-hrv-beat-spread-distrusted-on-50-nights-1451) and
[W3](#w3-respiratory-rate-straddles-the-rsa-quality-gate-1364) — both are symptoms of the
same stream.

**Correction to #1451's decode table — check this before interpreting a census.** The issue states
the 4.0 layout applies no interval cap and drops 0 ms values while the 5/MG layout caps at 4 and keeps
them. **That is not what this tree does.** Both historical paths cap *and* drop:

| Path | Site | Cap | 0 ms values |
|---|---|---|---|
| 4.0 historical (`historical_data`) | `PostHooks.swift:376` | `min(rrn, 4)` | dropped (`v != 0`) |
| 5.0 / MG historical | `Interpreter.swift:408` | `min(rrn, 4)` | dropped (`v > 0`) |
| Kotlin twins | `HistoricalStreams.kt:265` / `:361` | `minOf(rrn, 4)` | dropped (`v != 0`) |

The only site that keeps 0 ms values is the type-43 `raw_data` hook (`PostHooks.swift:249`) — a
realtime path, not a historical one, and not 5/MG-specific. So the "5.0 keeps zeros" asymmetry does not
hold here, and a census read through that lens would be misread. Post this on #1451 before drawing a
conclusion from the numbers.

**What is genuinely shared, and is the likely root.** Both families stamp **every** R-R in a record
with the record's own timestamp, discarding sub-second timing
(`HistoricalStreams.swift:251` and `:375`, plus the Kotlin twin):

```swift
if let rrs = p["rr_intervals"]?.intArrayValue {
    for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
}
```

That structurally caps `beatAccurateFraction` near 0.6 whatever the sensor does. And since the cap of 4
applies to *both* families, any record whose `rr_count` exceeds 4 is under-counted on both — which the
census's `offered` vs the record's own `rr_count` would show directly.

**Done when** the census line exists for a 5.0, #1451's decode table is corrected or explained, and the
family's actual failure mode (over- or under-count) is named.

### W2: HRV beat-spread distrusted on 5.0 nights ([#1451](https://github.com/ryanbr/noop/issues/1451))

- [ ] Confirm the `crossSecondOverCount` verdict reproduces on a current build
- [ ] Decide the fix once W1 says over- or under-count (both platforms, in one PR)
- [ ] Pin it with a `swift test` + Kotlin twin test that runs with no strap

**Symptom.** Measured nights read `rrIntegrity = crossSecondOverCount`, coverage **1.3–1.8** (more
beats stored than wall-clock allows), `dupBeats` 83–361. `HRVAnalyzer.beatSpreadIsTrustworthy` returns
`false` for that verdict, so beat-spread statistics are discarded on exactly those nights.

**Structural cause.** The record-level timestamp stamping described in
[W1](#w1-r-r-over-count-census-on-a-50mg-1451) — it is not a 4.0 quirk, the path is shared. Any fix
here is a **parity change**: Swift and Kotlin must move together, and the stored values cross the
`.noopbak` boundary.

**Done when** a measured 5.0 night reports a plausible coverage and `beatSpreadIsTrustworthy` is not
being tripped by decode-side duplication.

### W3: Respiratory rate straddles the RSA quality gate ([#1364](https://github.com/ryanbr/noop/issues/1364))

- [ ] Re-measure `beatAccurateFraction` after W1/W2 land
- [ ] If it still straddles, decide explicitly: re-open #1364, or document 5.0 respiration as
      best-effort in the UI rather than silently absent

Closed as **NOT_PLANNED** upstream, so this is live and unmitigated.

**Mechanism.** The 5.0's v18 record carries **no raw respiration ADC** — `respRateRawOff = 80` is set
on the 4.0 `HIST_V24` layout only — so respiration is derived from respiratory sinus arrhythmia in the
R-R stream. That derivation is gated on `HRVAnalyzer.beatAccuracyMinFraction = 0.5`, a threshold
documented as a boundary no real stream should land near: beat-accurate streams measure ~1.0, banked
Oura measures 0.03–0.07.

A real WHOOP 5.0 measures **0.42–0.62**. It sits astride the gate, so respiration appears or does not
appear essentially at random from night to night.

**Scope caveat.** The reported hit rate — a respiratory rate on 1 of ~14 nights — is **one reporter,
one device, one firmware**, and #1364 itself asks whether other 5.0/MG owners see the same without an
answer. The load-bearing claim is the **mechanism** (0.42–0.62 measured against a 0.50 gate), not the
frequency.

**Note the dependency:** if W1/W2 show the fraction is depressed by decode-side duplicate stamping
rather than sensor noise, this closes as a side effect and the gate needs no change at all. Do not
tune the threshold before that is known — the gate is behaving as designed.

### W4: SpO₂ `@82` multi-device validation ([#103](https://github.com/ryanbr/noop/issues/103))

- [ ] Capture a night with `sleep_state = asleep` coverage plus the matching WHOOP CSV export
- [ ] Run `python3 Tools/linux-capture/validate_spo2_candidate.py capture.json export/ --device <label> --postable`
- [ ] Post the `--postable` block (offsets and aggregates only — no raw values) on #103

**Where it stands.** v18 `@82` is already decoded as `spo2_candidate_82` — a strap-computed SpO₂ %
scalar, tri-mode (70–100 a real %, bit-7 a saturation sentinel, other sub-70 a diagnostic code),
sleep-only — and independently corroborated by `whoop-local` ([#715](https://github.com/ryanbr/noop/issues/715)).
It is instrumentation only; a guard test (`testHistoricalV18OpticalFieldsAreNotNamedPhysiologically`)
stops it ever writing `spo2Pct`.

**The blocker is a contradiction, not a missing capture.** An 8-night independent validation reaches
r = +0.99 (~0.4 %/night) and is offset-specific, but two nights on the original #103 capture device
moved *opposite* the app value. Promotion needs **≥2 devices** each passing the tool's gate (≥5 paired
nights, export range ≥1 %, r ≥ 0.7, MAE ≤ 1.0, best offset = 82, in-band value variance, ≥50 %
duty-window coverage) **plus** resolution of that contradiction.

**Capture trap.** `@82` is duty-cycled: nonzero in 2.4 % of records, in runs of exactly 30 at a fixed
`unix % 1200` phase. A badly phased or too-short capture reads a flat `0x00` and is indistinguishable
from a strap without the feature — which is why the tool classifies that case `feature_absent` rather
than FAIL. Judge coverage by **observed** sample time, not wall-clock span.

**Until then:** SpO₂ stays import-only. A WHOOP CSV export (`blood_oxygen_pct`) or a Health Connect /
Apple Health import populates the card with WHOOP's own values.

### W5: Live raw accel / IMU on 5/MG ([#423](https://github.com/ryanbr/noop/issues/423))

- [ ] Agree the gated-probe plan on #423 before touching the BLE path (per
      [`CONTRIBUTING.md`](CONTRIBUTING.md) §BLE safety contract)
- [ ] Probe, behind `PuffinExperiment`, one opcode per attempt with a 30 s frame census and no
      persistence: 81 (`START_RAW_DATA`) → 63 → 105 (`TOGGLE_IMU_MODE_HISTORICAL`) → 132
      (`GET_RESEARCH_PACKET`), disarming after each
- [ ] Only if a stream confirms: a bounded capture to pin samples/frame, cadence and scale, then a
      schema variant + decode PR as default-off instrumentation

**Why it is blocked today.** Commands 63 / 81 / 82 / 106 are dropped by the 5/MG allowlist in
`Strand/BLE/BLEManager.swift` ("no WHOOP 5/MG framing for this command yet"), and the full 6-axis IMU
stream (packet 51, via `TOGGLE_IMU_MODE`) is *confirmed refused* by 5.0 firmware — the command acks
SUCCESS and no stream materialises. Community evidence indicates a live raw-**accelerometer** stream
(type `0x2B`, packed int16-LE XYZ) does exist on the 5.0.

**What it would buy.** 5/MG motion today is ~1 Hz gravity plus `step_motion_counter@57`. High-rate
motion is what any cadence, rep-counting or activity-classification work would need. Note 105 banking
IMU into the historical buffer would suit the offload architecture far better than a live flood.

**Risk note.** This is the only item on the list that arms a new BLE stream. Keep it opt-in,
reversible, one opcode per attempt, and never default-on — battery and airtime are the reason the
4.0's equivalent flood is deliberately silenced on connect.

### W6: "Clock latched" reads no forever ([#827](https://github.com/ryanbr/noop/issues/827))

- [ ] Either decode the 5/MG `GET_CLOCK` COMMAND_RESPONSE and feed `clockLatchedLabel`, or change the
      readout to say the field does not apply to this family

Cosmetic — no metric is lost. `GET_CLOCK` is deliberately undecoded for 5/MG (`Interpreter.swift`:
realtime and historical records already carry real unix seconds), so the label's inputs are
structurally nil for the whole family. Worth closing because it reads as a fault to every 5.0 owner
who opens Devices.

### W7: Stale 5/MG capability copy (Android)

- [ ] Re-read `android/app/src/main/java/com/noop/ui/WhoopModelComparisonScreen.kt` against what the
      5.0 does today
- [ ] Flag the same wording on the upstream wiki page (not editable from this fork)

The screen still tells users **"Sleep, recovery & strain history: 4.0 = Yes, 5/MG = Partial — deeper
history is still being mapped."** The last commit touching that file is an i18n sweep from
2026-07-15, so the copy predates the v18 field mapping and the hardware-verified 5.0 offload
(chunk-ack handshake, `trim_cursor` walking, 3,193 CRC-valid type-47 frames in one 90 s capture).
[#1414](https://github.com/ryanbr/noop/issues/1414) also shows a 5/MG serving history — one strap,
not proof every 5/MG does. Android-only copy; there is no Swift twin of that screen.

---

## Not on this list — and why

### Not on this list: MG ECG ([#891](https://github.com/ryanbr/noop/issues/891))

**Dropped: no MG hardware on hand.** The ECG ("Labrador") subsystem needs the MG's conductive clasp; a
plain 5.0 has no electrodes, and the command family is gated off unless the strap positively attests
itself an MG over the Device Information Service. Nothing here can be tested or falsified on this
strap, so claiming progress on it would be claiming an untested result. #891 stands as the record: all
three `TOGGLE_LABRADOR_*` commands return SUCCESS and produce zero packets, `enable_raw_data_w_ecg`
was written and read back and did not change that, and five explanations remain live.

### Absent from the v18 wire — nothing to decode

The 4.0's `v24` record carries a full DSP sensor block; the 5.0's `v18` is a different, leaner layout.
Nothing here is encrypted — NOOP decodes the whole 124-byte record in plaintext — these fields are not
*in* it.

| Channel | 4.0 v24 | 5.0 v18 | Consequence |
|---|---|---|---|
| `spo2_red` / `spo2_ir` (raw ADC) | `@68` / `@70` | absent | The 4.0 banks raw red/IR; the 5.0 banks nothing. Neither yields a calibrated %. |
| `resp_rate_raw` | `@80` | absent | Forces the RSA estimate — see [W3](#w3-respiratory-rate-straddles-the-rsa-quality-gate-1364) |
| `ppg_green`, `ppg_red_ir`, `ambient`, `led_drive_1/2` | `@33 @35 @74 @76 @78` | absent | No labelled optical channels. v18's `@106/@107` baselines and `@108/@109` amplitudes are signal-quality / AGC signals of **unknown wavelength** — explicitly not SpO₂ substrate. |
| `skin_contact` (capacitive) | `@55` | absent | Off-wrist is inferred instead (both optical baselines read 0 alongside `HR == 0`, plus the `sleep_state@81` on-wrist sub-flag). |
| second gravity triplet | `@56 @60 @64` | one triplet | No second accelerometer reference. |
| `signal_quality` (u16 DSP) | `@82` | positional only | v18's quality group (`@33`, `@40`, the `@108/@109` sentinel, `@113`) is characterised statistically; no scale is asserted. |

The R22 deep-data unlock does **not** restore these. It opens the larger v20 (2,140 B, five optical
blocks), v21 (1,244 B, six-axis IMU) and v26 (24 Hz PPG) records — all structurally decoded, none
carrying a proven red/IR pair. Pulse oximetry needs two wavelengths; the v26 waveform is
single-channel.

### Withheld by policy on every WHOOP

- **Calibrated SpO₂ %** — needs WHOOP's proprietary curve; fabricating one is the trap that withdrew
  the [#194](https://github.com/ryanbr/noop/issues/194) PPG→HR estimate.
- **Blood pressure** — no BP scalar identified; would need a validated model, cuff reference data,
  population calibration and an explicit non-medical boundary.
- **Sleep stages from the strap** — the band emits only a coarse four-state flag (`sleep_state@81` =
  wake / still / asleep / up) on *every* WHOOP. Light / deep / REM are off-band and are produced by
  NOOP's own stager. Improving them is stager work
  ([#930](https://github.com/ryanbr/noop/issues/930), [#364](https://github.com/ryanbr/noop/issues/364)),
  not decode work.

### Not strap gaps at all

NOOP computes none of these on *any* WHOOP, so they do not belong in a 5.0 gap list:
VO₂ max ([#1391](https://github.com/ryanbr/noop/issues/1391)), native active-energy calories
([#113](https://github.com/ryanbr/noop/issues/113)), WHOOP's own cloud-computed recovery / strain /
sleep scores, and GPS / microphone / speaker / display (hardware the strap does not have).

---

## Where the 5.0 is ahead of the 4.0

Stated so the list is not read as "the 5.0 is the crippled generation":

- **Steps** — read directly from `step_motion_counter@57` (wrap-aware diffs). A 4.0 has no readable
  step counter and must be *estimated* from motion;
  [#1149](https://github.com/ryanbr/noop/issues/1149) (steps and calories read 0) is a 4.0 bug.
- **Band sleep flag** — `sleep_state@81` gives real on-device sleep detection. The 4.0 has no
  equivalent and its motion buffer is too sparse to stage reliably
  ([#345](https://github.com/ryanbr/noop/issues/345)).
- **Activity class** — `@63` (still / walk / run) plus `step_cadence@59`.
- **A strap-computed SpO₂ scalar exists at all** (`@82`) — the 4.0 has raw ADC but no on-device value.
- **Deep records** — v26's 24 Hz PPG waveform and v21's six-axis IMU have no 4.0 analogue.
- **Battery reporting works** — on recent 4.0 firmware every battery source is currently dead
  ([#791](https://github.com/ryanbr/noop/issues/791)).

## Working rules for anything on this list

From [`CLAUDE.md`](../CLAUDE.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md), repeated because every item
above touches at least one of them:

- **One concern per PR.** A decode change, a migration and a UI change do not travel together.
- **Parity is not optional.** A decoder, formula or stored-value change on one platform changes its
  twin in the same PR, or says why not.
- **BLE changes are validated on hardware.** Compile-success proves nothing about connection
  behaviour; say what was tested on the strap.
- **Derived physiological signals ship as instrumentation or behind a default-off toggle** until they
  demonstrably track a *varying* input. One matching night is not validation.
