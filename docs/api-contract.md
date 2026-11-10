# Safe Space: API and Data Contract (v1, proposed)

Status: **proposed, needs approval from all four roles** (see [Approval](#13-approval)).
Written Oct 16, 2026 (Week 1) from `docs/safe-space-implementation-plan.md`, the code on `main`/`ciede2000`, and the `assessmentJson`, `swiftUIShell` and `first20TestImages` branches.

This document defines every boundary between the four roles, so each person can build against it without waiting on the others. If code and this document disagree, one of them is a bug: fix it or change the contract (see [Change process](#12-change-process)).

## Contents

1. [Scope and architecture](#1-scope-and-architecture)
2. [Conventions](#2-conventions)
3. [Pipeline and step lifecycle](#3-pipeline-and-step-lifecycle)
4. [assessment.json v1](#4-assessmentjson-v1)
5. [SafeSpaceCore Swift API](#5-safespacecore-swift-api)
6. [Storage layout (F3)](#6-storage-layout-f3)
7. [CLI contract (T)](#7-cli-contract-t)
8. [Test-image manifest](#8-test-image-manifest)
9. [Numeric tolerances and determinism](#9-numeric-tolerances-and-determinism)
10. [Integration timeline and stubs](#10-integration-timeline-and-stubs)
11. [Gaps found in current code](#11-gaps-found-in-current-code)
12. [Change process](#12-change-process)
13. [Approval](#13-approval)
14. [Open decisions](#14-open-decisions)

---

## 1. Scope and architecture

**Everything runs on the device. There is no server and no network API.** (Decision log, Oct 11. The README's FastAPI/URLSession/"analysis service" sections are out of date and must be rewritten; see §11.) In this project, "API" means four things:

| Contract | Producer | Consumers | Section |
|---|---|---|---|
| `assessment.json` v1 file format | Core (pipeline) | App, Storage, CLI, Python validator, eval scripts | §4 |
| SafeSpaceCore public Swift API | A, C, D (per module) | App (B), CLI (D) | §5 |
| On-disk storage layout | C | App (B) | §6 |
| CLI arguments, output files and CSV columns | D | Evaluation (A, D), report | §7 |

```
                       ┌──────────────────── SafeSpaceCore (Swift package) ────────────────────┐
 App (B) ── Data ──▶   │ ImageLoader ─▶ QualityCheck ─▶ Anonymizer ─▶ PaletteExtractor ─▶ Findings │ ──▶ AssessmentRecord
 CLI (D) ── file ──▶   │   (A)            (A)            (C)            (A)               (D)      │        │
                       │                                   RegionContrast (A, on demand) ◀─────────│◀── user regions (B)
                       │ AssessmentStore (C) · AssessmentValidator (C) · Codable models (C)        │
                       └───────────────────────────────────────────────────────────────────────────┘
```

Rules:

- **Only SafeSpaceCore holds analysis logic.** The app and the CLI are thin shells over the same entry point, `AssessmentPipeline.run` (§5.9). That is how the plan's "CLI and app agree on the same 5 images" Friday check can pass.
- **Core imports Apple frameworks only** (Foundation, ImageIO, CoreGraphics, Vision, Accelerate). No SwiftUI or UIKit in Core. No third-party code (see §11 on `CStbImage`).
- **The app never computes a measurement.** It shows what is in an `AssessmentRecord` and sends user input (photo bytes, region rectangles) to Core.

## 2. Conventions

These apply to every JSON file, Swift type and CSV in the project.

| Topic | Rule |
|---|---|
| JSON keys | `snake_case`. Swift uses `camelCase` and maps with `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`. |
| Enum values in JSON | lowercase `snake_case` strings, e.g. `"completed"`, `"too_dark"`. Swift `enum X: String, Codable` with matching raw values. |
| IDs | `assessment_id`, `room_id`, `measurement_id`: UUID v4, **lowercase** string (`UUID().uuidString.lowercased()`). Palette color IDs: `"c1"`, `"c2"`, … in rank order, unique only within one assessment. |
| Timestamps | RFC 3339 UTC with `Z` and no fractional seconds, e.g. `"2026-10-19T18:04:11Z"`. `JSONEncoder.dateEncodingStrategy = .iso8601`. |
| Durations | Integer milliseconds, key suffix `_ms`. |
| Fractions | `share`-style values are fractions in `[0, 1]`, never percentages. The UI converts to percentages for display. |
| Colors | `hex` is `#RRGGBB`, **uppercase**, made from the 8-bit sRGB value. Perceptual values are stored as objects: `{"l":…, "a":…, "b":…}`. |
| Floating point | Store full `Double` precision (Swift's `JSONEncoder` writes the shortest round-trip form). **Round only for display.** This keeps reopen exact (S6). |
| Absent vs null | A required key is always present. "Not applicable" is `null`, never a missing key. Unknown keys are rejected (`additionalProperties: false`). |
| JSON output | `outputFormatting = [.prettyPrinted, .sortedKeys]`, so files diff cleanly and CLI and app output are byte-comparable. |
| Coordinates | Normalized `[0, 1]` to the **upright working copy** (EXIF orientation already applied), origin top-left, `{x, y, width, height}`. Never use pixel coordinates in JSON. |
| Text encoding | UTF-8, LF line endings. |

## 3. Pipeline and step lifecycle

### 3.1 Order

```
original bytes ─▶ [load] working copy ─▶ [quality] ─▶ [anonymization] ─▶ [palette] ─▶ [findings] ─▶ save
                                                                                         ▲
                                                 later, any time: [contrast] ────────────┘ (appends, re-saves)
```

1. **load** (Core, A): decode the bytes, apply EXIF orientation, convert to sRGB, and resize so the long side is 1024 px. If loading fails, there is no assessment: the app shows an error and nothing is saved.
2. **quality** (A): reads the working copy before masking. **It warns only and never blocks** (decision log, Oct 11).
3. **anonymization** (C): finds faces and people, blurs them in the stored image, and outputs an `EligibilityMask` that marks those pixels ineligible.
4. **palette** (A): clusters only the eligible pixels.
5. **findings** (D): generates plain-language sentences from the stored measurements.
6. **contrast** (A math, B UI): runs only when the user draws two regions, possibly after the first save. Each run appends a measurement and re-saves the file.

### 3.2 Step status

Three statuses are **persisted**, and two more exist **only in memory**:

| Status | Persisted | Meaning | `reason` | `result` |
|---|---|---|---|---|
| `pending` | no | Not started yet | n/a | n/a |
| `running` | no | In progress | n/a | n/a |
| `completed` | yes | Ran and produced a valid result | `null` | object |
| `skipped` | yes | Not attempted | reason code | `null` |
| `failed` | yes | Attempted but no valid result | reason code | `null` |

A finding like "low quality" or "no faces found" is a `completed` step with that result. It is not `failed`. Failed and skipped steps keep no partial results. The app's placeholder `ComponentStatus.pending` becomes `StepState.pending` in Core, and it is never written to disk.

### 3.3 Reason codes (closed list)

Reason codes are a **closed** enum in v1. Adding a code is a contract change (§12), which keeps the app's wording table complete.

| Code | Steps | Status | User-facing text (D owns final wording) |
|---|---|---|---|
| `not_implemented` | any | skipped | This check isn't available in this version. |
| `disabled_by_user` | quality, anonymization | skipped | You turned this check off. |
| `not_requested` | contrast | skipped | No areas have been compared yet. |
| `dependency_failed` | palette, contrast | skipped | This couldn't run because an earlier step failed. |
| `image_unavailable` | contrast | skipped | The saved photo isn't available, so areas can't be compared. |
| `quality_check_failed` | quality | failed | The app couldn't check photo quality. |
| `detection_unavailable` | anonymization | failed | Face and person detection couldn't run on this device. |
| `anonymization_failed` | anonymization | failed | The app couldn't hide faces and people. |
| `no_eligible_pixels` | palette | failed | Too little of the photo was left to analyze after hiding people. |
| `palette_extraction_failed` | palette | failed | The app couldn't find a color palette. |
| `contrast_calculation_failed` | contrast | failed | The app couldn't compare the two areas. |

### 3.4 Dependencies (validator-enforced)

- palette `failed` → findings may describe only quality and limitations; contrast is `skipped` with `not_requested` or `image_unavailable` (contrast does **not** need the palette in v1, because it averages raw region pixels).
- `image.stored == false` → contrast must be `skipped` with `image_unavailable`.
- anonymization not `completed` → palette still runs, without a mask, and `palette.result.mask_applied == false`. The findings must then include the `limitation.people_not_masked` sentence. Whether the image is stored in that case is open decision **D2**.

### 3.5 Assessment-level state (derived, not stored)

`AssessmentRecord.overallState` is a computed property in Core. The app's `AssessmentState` placeholder is replaced by it.

| State | Rule |
|---|---|
| `complete` | palette `completed`, and no step `failed` |
| `partial` | palette `completed`, and at least one other step `failed` |
| `failed` | palette not `completed` |

(Contrast `skipped/not_requested` does not make an assessment partial.)

## 4. assessment.json v1

v1 **replaces** v0 (`origin/assessmentJson`). Because v0 was never written by shipping code, there is no migration. v1 keeps v0's core ideas: four required steps, the `{status, reason, result}` triple, closed objects, and a validator script. It changes what's inside each step to match the plan:

| v0 | v1 | Why |
|---|---|---|
| contrast = WCAG luminance ratio between two palette colors | contrast = CIEDE2000 between two user-drawn regions, averaged in CIELAB | F6, Task 16/17, S11 |
| palette color = `{id, hex}` | adds share, OKLab/OKLCh, CIELAB, sRGB, pixel count | F1 ("share, lightness, chroma, hue") |
| quality = `{acceptable, issues[]}` | numeric metrics, the thresholds used, and warning codes | F4, Task 19, S7 |
| anonymization = `{applied, regions_modified}` | detected regions, masked share, whether the original was discarded | F5, Task 21, S8 |
| no provenance | `producer`, `image`, a `method` block per step | S3 (100% of results record space, method, preprocessing, conditions, image copy) |
| no findings | `findings[]` with JSON-Pointer provenance | F2, Task 11, S4 |
| no room | `room_id` | F3, Task 14 |

### 4.1 Top level

```jsonc
{
  "schema_version": "1",                       // string; bump rules in §12
  "assessment_id": "3f0c…",                    // UUID v4, lowercase
  "room_id": "9a1e…",                          // UUID v4; "cli" for CLI runs
  "created_at": "2026-10-19T18:04:11Z",
  "updated_at": "2026-10-19T18:06:40Z",        // changes when a contrast measurement is added
  "producer":  { … },                          // §4.2
  "image":     { … },                          // §4.3
  "steps": {
    "quality":       { … },                    // §4.5
    "anonymization": { … },                    // §4.6
    "palette":       { … },                    // §4.7
    "contrast":      { … }                     // §4.8
  },
  "findings": [ … ]                            // §4.9
}
```

### 4.2 `producer`

```json
{
  "kind": "app",
  "app_version": "0.2.0 (14)",
  "core_version": "0.2.0",
  "device": "iPhone15,2",
  "os": "iOS 18.1"
}
```

`kind` is `app` or `cli`. For the CLI, `app_version` is `null` and `device` is the Mac model identifier. `core_version` is `SafeSpaceCore.version`, which **must be bumped on every tag** (v0.1, Release 1, and so on) so the Week 6 CSVs can be traced back to a build.

### 4.3 `image`: provenance of the input and the working copy (S3)

```json
{
  "source": "library",
  "original": {
    "format": "heic",
    "color_space": "display_p3",
    "width": 4032,
    "height": 3024,
    "exif_orientation": 6,
    "retained": false
  },
  "working_copy": {
    "color_space": "srgb",
    "width": 768,
    "height": 1024,
    "max_long_side": 1024,
    "resize_method": "area_average_gamma_encoded",
    "orientation_applied": true,
    "gamut_mapping": "clip"
  },
  "stored": true,
  "stored_file": "image.png"
}
```

| Field | Values |
|---|---|
| `source` | `library`, `camera`, `file` (CLI) |
| `original.format` | `heic`, `jpeg`, `png`, `other` |
| `original.color_space` | `srgb`, `display_p3`, `adobe_rgb`, `untagged` (treated as sRGB), `other` |
| `original.width/height` | Stored pixel size **before** orientation (same as `ImportedPhoto.pixelWidth/Height`). |
| `original.retained` | Always `false` in the app (the original is never written to disk, per F5). The CLI writes `true`, since the source file still exists in the test set. |
| `working_copy.*` | The size **after** orientation and resize. Every normalized coordinate refers to this image. |
| `stored` / `stored_file` | Whether the anonymized working copy was saved next to the JSON. `stored_file` is `null` when `stored` is `false`. |

### 4.4 Step envelope (all four steps)

```json
{
  "status": "completed",
  "reason": null,
  "duration_ms": 412,
  "method": { "name": "…", "version": 1, "params": { } },
  "result": { }
}
```

- `duration_ms`: integer, or `null` when skipped. Feeds S9 (the app adds the total in memory; see §5.9).
- `method`: present for completed **and failed** steps, and `null` when skipped. `version` is an integer, bumped whenever the algorithm or a default parameter changes, so results from different tags are never mixed by accident.
- `result`: per-step shape below; `null` unless completed.

### 4.5 `steps.quality` (F4, owner A)

```json
{
  "status": "completed", "reason": null, "duration_ms": 38,
  "method": { "name": "quality_basic", "version": 1, "params": {
      "dark_mean_luminance_max": 0.08, "bright_mean_luminance_min": 0.80,
      "clipped_share_max": 0.05, "blur_variance_min": 100.0, "min_long_side_px": 640 } },
  "result": {
    "metrics": {
      "mean_luminance": 0.43,
      "clipped_dark_share": 0.012,
      "clipped_bright_share": 0.071,
      "blur_laplacian_variance": 233.4,
      "original_long_side_px": 4032
    },
    "warnings": ["overexposed"],
    "user_continued": true
  }
}
```

- `mean_luminance` is relative luminance Y (linear sRGB, 0–1) over the working copy. Clipping counts pixels with every channel ≤ 2 (dark) or ≥ 253 (bright), in 8-bit. Blur is the population variance of the 3×3 Laplacian `[0 1 0; 1 -4 1; 0 1 0]` on 8-bit luma, computed on the working copy over every pixel with reflect-101 borders. Luma is BT.601 in OpenCV's fixed point, `(4899R + 9617G + 1868B + 8192) >> 14`, so the value equals `cv2.Laplacian(cv2.cvtColor(img, cv2.COLOR_RGB2GRAY), cv2.CV_64F).var()`. All metrics use exact integer math in pure Swift (no Accelerate), so they are bit-identical on every platform. Warnings: `too_dark` if mean ≤ `dark_mean_luminance_max`; `too_bright` if mean ≥ `bright_mean_luminance_min`; `overexposed` / `underexposed` if the bright / dark clipped share > `clipped_share_max`; `blurry` if variance < `blur_variance_min`; `low_resolution` if the original long side < `min_long_side_px`. **`dark_mean_luminance_max` was calibrated to 0.08 in Task 19 (evidence in `QualityParams`); the other thresholds are placeholders until A calibrates them on the 40-image set (Week 5).** They live in `params` so they are recorded.
- `warnings`: closed enum, sorted by string value, no duplicates: `too_dark`, `too_bright`, `overexposed`, `underexposed`, `blurry`, `low_resolution`. An empty array means no warnings.
- `user_continued`: `true` once analysis continues past a warning. In v1 it is always `true` (the plan says the user can always continue). It is recorded for S7's "user can always continue".
- Resolution is judged on the **original** size, since the working copy is always ≤ 1024.

### 4.6 `steps.anonymization` (F5, owner C)

```json
{
  "status": "completed", "reason": null, "duration_ms": 190,
  "method": { "name": "vision_faces_people", "version": 1, "params": {
      "detect_faces": true, "detect_people": true, "box_padding": 0.10, "blur_radius_px": 24 } },
  "result": {
    "regions": [
      { "kind": "face",   "rect": { "x": 0.41, "y": 0.22, "width": 0.06, "height": 0.08 }, "confidence": 0.93 },
      { "kind": "person", "rect": { "x": 0.35, "y": 0.18, "width": 0.20, "height": 0.62 }, "confidence": 0.88 }
    ],
    "masked_share": 0.124,
    "may_be_incomplete": false
  }
}
```

- `regions[].kind`: `face` or `person`. `rect` is the **padded** box that was masked.
- `masked_share`: the fraction of working-copy pixels marked ineligible.
- `may_be_incomplete`: `true` when only face detection ran (the Week 5 cut, risk R4) or when C's heuristics flag doubt. In that case the findings must include `limitation.anonymization_incomplete`.
- No regions found: `completed`, with `regions: []` and `masked_share: 0`. This is not a guarantee that nobody appears in the photo, and the wording must say so.
- Validator rule: `masked_share > 0` if and only if `regions` is non-empty.

### 4.7 `steps.palette` (F1, owner A)

```json
{
  "status": "completed", "reason": null, "duration_ms": 640,
  "method": { "name": "kmeans_pp", "version": 1, "params": {
      "space": "oklab", "k_initial": 8, "seed": 482, "max_iterations": 50,
      "merge_delta_e_ok": 0.04, "min_share": 0.01, "sample_stride": 1 } },
  "result": {
    "mask_applied": true,
    "eligible_pixel_count": 690112,
    "dropped_share": 0.018,
    "colors": [
      {
        "id": "c1",
        "rank": 1,
        "share": 0.412,
        "pixel_count": 284326,
        "hex": "#D9D2C5",
        "srgb8": [217, 210, 197],
        "oklab":  { "l": 0.862, "a": 0.002, "b": 0.016 },
        "oklch":  { "l": 0.862, "c": 0.016, "h": 82.9 },
        "cielab": { "l": 84.1, "a": 0.6, "b": 6.0 }
      }
    ],
    "label_map_file": "labels.png"
  }
}
```

- `method.name`: `kmeans_pp` or `median_cut` (Task 8 sits behind the same interface). Week 3's S1 baseline chooses the default; whichever it is, the record says which one ran.
- `colors` is sorted by `share`, descending; `rank` runs 1…n; IDs are `c{rank}`. 1 ≤ n ≤ `k_initial`.
- `share` = `pixel_count / eligible_pixel_count`. The shares sum to `1 - dropped_share` (±1e-9). `dropped_share` covers clusters removed by `min_share`.
- **"Lightness, chroma, hue" in the plan means OKLCh** `l` (0–1), `c` (≥ 0) and `h` (degrees in `[0, 360)`). When `c < 0.002`, `h` is `null`, because the color is achromatic and has no meaningful hue. The wording must not name a hue for it.
- The cluster center is the mean of member pixels in OKLab. `srgb8`/`hex` is that center converted back to sRGB and clamped. `cielab` is computed from `srgb8`, so contrast and palette use the same conversion path.
- `label_map_file`: an 8-bit grayscale PNG at working-copy size. Each pixel holds `rank - 1` (0–7), or 255 for ineligible or dropped pixels. It drives the Task 10 overlay on reopen without recomputing. It is `null` when the image isn't stored.
- `mask_applied`: whether an anonymization mask removed pixels.

### 4.8 `steps.contrast` (F6, math A, UI B)

```json
{
  "status": "completed", "reason": null, "duration_ms": 9,
  "method": { "name": "region_mean_ciede2000", "version": 1, "params": {
      "averaging_space": "cielab_d65", "kl": 1, "kc": 1, "kh": 1, "min_eligible_pixels": 100 } },
  "result": {
    "measurements": [
      {
        "measurement_id": "b7d2…",
        "created_at": "2026-10-19T18:06:40Z",
        "label": null,
        "region_a": {
          "rect": { "x": 0.10, "y": 0.05, "width": 0.30, "height": 0.25 },
          "pixel_count": 17280, "eligible_pixel_count": 17280,
          "mean_cielab": { "l": 84.1, "a": 0.6, "b": 6.0 }, "mean_hex": "#D9D2C5"
        },
        "region_b": { "rect": { … }, "pixel_count": 9800, "eligible_pixel_count": 9650,
          "mean_cielab": { … }, "mean_hex": "#6B4F3A" },
        "delta_e_2000": 41.27
      }
    ]
  }
}
```

- Before the user compares anything: `skipped` with `not_requested`, and `method: null`. On the first successful measurement the step becomes `completed` and the file is re-saved. Later measurements are appended to the array. **Failed attempts are not persisted.** The UI shows the error, and the step's stored status doesn't change.
- Rect to pixel bounds: `x0 = floor(x·W)`, `x1 = ceil((x+width)·W)` (exclusive); y uses H the same way. Each rect must lie within `[0, 1]` and cover at least 1 pixel.
- Averaging: each eligible pixel's **CIELAB** value (D65, from 8-bit sRGB through `ColorSpace.sRGBToCIELAB`), arithmetic mean. If either region has fewer than `min_eligible_pixels` eligible pixels, `RegionContrast` throws `.regionTooSmall`, and the UI asks the user to draw a larger box.
- Invariants (S11, enforced by unit tests, not the validator): identical regions → `0`; swapping a and b → the same value within 1e-9.
- Overlapping regions are allowed.
- `label`: an optional user-entered name, such as "wall vs floor". It is `null` in v1 UI unless B adds a text field.
- The UI must name the color space and the formula: "Color difference (CIEDE2000, CIELAB D65) in this photo". Display ΔE to one decimal.

### 4.9 `findings` (F2, owner D)

```json
[
  {
    "id": "f1",
    "kind": "palette_overall",
    "template_id": "palette.overall.light_neutral",
    "template_version": 1,
    "text": "Most of this photo (about 41%) is a light, low-color beige.",
    "sources": ["/steps/palette/result/colors/0/share", "/steps/palette/result/colors/0/oklch"]
  },
  {
    "id": "f2",
    "kind": "limitation",
    "template_id": "limitation.photo_not_room",
    "template_version": 1,
    "text": "These colors describe this photo, not the room itself. Lighting and the camera change how colors look.",
    "sources": []
  }
]
```

- `kind`: `palette_overall`, `palette_dominant`, `palette_accent`, `quality`, `anonymization`, `contrast`, `limitation`.
- `sources`: [RFC 6901 JSON Pointers](https://www.rfc-editor.org/rfc/rfc6901) into this same file. Each pointer must resolve (the validator checks this). Every non-`limitation` finding needs at least one source; this is what makes S4 (text faithfulness) checkable by script.
- The text is **stored, not regenerated** on reopen, so reopen shows exactly what was first shown (S6), even if templates change later. `template_version` records which version produced it.
- Order in the array is display order.
- Every assessment includes `limitation.photo_not_room`. Conditional limitations: `limitation.people_not_masked`, `limitation.anonymization_incomplete`, `limitation.quality_warning`.
- Findings for a contrast measurement are appended when the measurement is added, and their sources point at `/steps/contrast/result/measurements/<i>/delta_e_2000`.
- No finding may contain a banned term (`Findings.bannedTerms`, owned by D, case-insensitive whole-word match). The list starts with: lux, safe, unsafe, suitable, unsuitable, dementia, autism, autistic, diagnose, certify, compliant, WCAG pass, calming, therapeutic. Core enforces this in `Findings.generate` and **in the validator**, so text that bypasses the templates is still caught.

### 4.10 Validation

Core has `AssessmentValidator.validate(_:) throws` (C). The Python script `docs/assessment/validate_assessments.py` mirrors it with the v1 JSON Schema plus the semantic checks below. **Both** run on the shared fixtures (§10.2). Storage refuses to save a record that fails validation, and the CLI exits with a nonzero code on failure.

Semantic rules beyond what JSON Schema can express:

1. A `completed` step has a non-null `result` and `method` and a null `reason`. `skipped`/`failed` have a null `result` and a reason code allowed for that step and status (§3.3).
2. Every §3.4 dependency rule holds.
3. Palette: IDs are `c1…cn` in rank order; shares are sorted descending; `Σshare + dropped_share = 1 ± 1e-9`; `Σpixel_count ≤ eligible_pixel_count`; `h == null ⇔ c < 0.002`; `hex` matches `srgb8`.
4. Anonymization: `masked_share > 0 ⇔ regions non-empty`.
5. Contrast: unique `measurement_id`s; rects inside `[0,1]`; `eligible_pixel_count ≥ min_eligible_pixels`; `0 ≤ delta_e_2000`.
6. Findings: unique `id`s; every source pointer resolves; non-limitation findings have ≥ 1 source; no banned terms; `limitation.photo_not_room` is present.
7. `image.stored == false ⇒ stored_file == null ∧ label_map_file == null`.
8. `updated_at ≥ created_at`.

## 5. SafeSpaceCore Swift API

Signatures are binding. Bodies are the owner's call. Everything listed here is `public`; anything else stays `internal`. All model types are `Sendable` and `Equatable`, and the persisted ones are `Codable`. Every function is either a pure function or `async`, and nothing touches the main actor.

### 5.1 Module layout (existing folders)

| Folder | Types | Owner |
|---|---|---|
| `Color/` | `ColorSpace`, `ColorDifference`, `PerceptualColor` (exist); `SRGBImage`, `EligibilityMask`, `NormalizedRect` | A |
| `Imaging/` | `ImageLoader`, `WorkingCopy` | A |
| `Quality/` | `QualityCheck` | A |
| `Privacy/` | `Anonymizer`, `VisionAnonymizer` | C |
| `Color/Palette/` (new) | `PaletteExtractor`, `KMeansPlusPlus`, `MedianCut` | A |
| `Color/Contrast/` (new) | `RegionContrast` | A |
| `Findings/` | `Findings`, templates | D |
| `Storage/` | `AssessmentRecord` and the other Codable models, `AssessmentValidator`, `AssessmentStore`, `FileAssessmentStore` | C |
| root | `AssessmentPipeline`, `SafeSpaceError` | A (with C) |

### 5.2 Images and masks

```swift
/// 8-bit sRGB, RGBA, straight (non-premultiplied) alpha, row-major, top-left origin, upright.
/// Replaces `Pixels`. Alpha is NOT used for eligibility; use EligibilityMask.
public struct SRGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]            // count == width * height * 4
    public init(width: Int, height: Int, rgba: [UInt8])   // precondition on count
    public func pngData() -> Data       // sRGB-tagged PNG, used by storage
    public init(pngData: Data) throws   // used on reopen
}

/// true = pixel may be used in color statistics. Same size as the image it masks.
public struct EligibilityMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let eligible: [Bool]
    public static func all(width: Int, height: Int) -> EligibilityMask
    public var eligibleCount: Int { get }
    public func excluding(_ rects: [NormalizedRect]) -> EligibilityMask
    public func pngData() -> Data       // 8-bit gray: 255 eligible, 0 not
    public init(pngData: Data) throws
}

public struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    public var x, y, width, height: Double   // all in [0, 1], origin top-left
    public func pixelBounds(width: Int, height: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int)  // §4.8 rule
}
```

### 5.3 Loading (Task 3, A)

```swift
public struct WorkingCopy: Sendable {
    public let image: SRGBImage
    public let provenance: ImageProvenance     // Codable; is `image` in §4.3 minus `stored`/`stored_file`
}

public enum ImageSource: String, Codable, Sendable { case library, camera, file }

public enum ImageLoader {
    /// Decodes with ImageIO, applies EXIF orientation, converts to sRGB via CoreGraphics,
    /// resizes long side to `maxLongSide`. Works on iOS and macOS.
    public static func load(data: Data, source: ImageSource, maxLongSide: Int = 1024) throws -> WorkingCopy
    public static func load(url: URL, maxLongSide: Int = 1024) throws -> WorkingCopy  // source = .file
}
```

The app passes `ImportedPhoto.originalData` directly. It must **not** pass `preview`.

### 5.4 Quality (Task 19, A)

```swift
public struct QualityParams: Codable, Sendable, Equatable { /* §4.5 params */ public static let v1: QualityParams }
public struct QualityResult: Codable, Sendable, Equatable { public let metrics: QualityMetrics; public let warnings: [QualityWarning]; public var userContinued: Bool }
public enum QualityWarning: String, Codable, Sendable, CaseIterable { case tooDark = "too_dark", tooBright = "too_bright", overexposed, underexposed, blurry, lowResolution = "low_resolution" }

public enum QualityCheck {
    public static let methodName = "quality_basic", methodVersion = 1
    public static func run(_ copy: WorkingCopy, params: QualityParams = .v1) throws -> QualityResult
}
```

### 5.5 Anonymization (Task 21, C)

```swift
public struct AnonymizationOutput: Sendable {
    public let result: AnonymizationResult     // Codable, §4.6
    public let mask: EligibilityMask
    public let anonymizedImage: SRGBImage      // detected regions blurred; this is what gets stored
}

public protocol Anonymizer: Sendable {
    var methodName: String { get }
    var methodVersion: Int { get }
    func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput
}

public struct VisionAnonymizer: Anonymizer { public init(params: AnonymizationParams = .v1) }
/// Until Task 21 merges, the pipeline uses this; it makes the step `skipped / not_implemented`.
public struct NoOpAnonymizer: Anonymizer { public init() }
```

### 5.6 Palette (Tasks 7–8, A)

```swift
public enum PaletteMethod: String, Codable, Sendable { case kmeansPP = "kmeans_pp", medianCut = "median_cut" }
public struct PaletteParams: Codable, Sendable, Equatable { /* §4.7 params */ public static let v1: PaletteParams }

public struct PaletteOutput: Sendable {
    public let result: PaletteResult           // Codable, §4.7 (label_map_file filled in by storage)
    public let labelMap: [UInt8]               // width*height, rank-1 or 255
}

public protocol PaletteExtractor: Sendable {
    var method: PaletteMethod { get }
    var methodVersion: Int { get }
    /// Must be deterministic: same image + mask + params ⇒ bit-identical output.
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput
}
public func makePaletteExtractor(_ method: PaletteMethod) -> PaletteExtractor
```

### 5.7 Region contrast (Task 16, A)

```swift
public struct ContrastMeasurement: Codable, Sendable, Equatable, Identifiable { /* §4.8 measurement */ }

public enum RegionContrast {
    public static let methodName = "region_mean_ciede2000", methodVersion = 1
    public static func measure(image: SRGBImage, mask: EligibilityMask,
                               a: NormalizedRect, b: NormalizedRect,
                               minEligiblePixels: Int = 100) throws -> ContrastMeasurement
}
```

`ColorDifference.ciede2000` (already on `ciede2000`) is the only ΔE implementation. `RegionContrast` calls it, and nothing else may reimplement it.

### 5.8 Findings (Task 11, D)

```swift
public struct Finding: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let kind: FindingKind
    public let templateId: String; public let templateVersion: Int
    public let text: String; public let sources: [String]   // JSON Pointers
}

public enum Findings {
    public static let bannedTerms: [String]
    /// Builds all findings for a record whose steps are final. Never throws for valid input;
    /// any template that would emit a banned term is a programmer error (precondition).
    public static func generate(for record: AssessmentRecord) -> [Finding]
    /// Findings for one newly added contrast measurement (index into measurements).
    public static func contrastFindings(for record: AssessmentRecord, measurementIndex: Int) -> [Finding]
}
```

### 5.9 Pipeline (entry point for app and CLI)

```swift
public enum StepID: String, Codable, Sendable, CaseIterable { case quality, anonymization, palette, contrast }
public enum StepState: Sendable, Equatable { case pending, running, completed, skipped(ReasonCode), failed(ReasonCode) }

public struct PipelineOptions: Sendable {
    public var paletteMethod: PaletteMethod = .kmeansPP
    public var paletteParams: PaletteParams = .v1
    public var qualityParams: QualityParams = .v1
    public var runQuality = true
    public var anonymizer: Anonymizer = NoOpAnonymizer()   // VisionAnonymizer once Task 21 merges
    public init()
}

public struct PipelineOutput: Sendable {
    public let record: AssessmentRecord        // validated; contrast = skipped/not_requested
    public let storedImage: SRGBImage?         // anonymized working copy, nil if not to be stored (§3.4, D2)
    public let mask: EligibilityMask
    public let labelMap: [UInt8]?
    public let totalDurationMs: Int            // for S9 timing; not persisted
}

public enum AssessmentPipeline {
    /// Runs load → quality → anonymization → palette → findings. Never throws for step failures
    /// (they become `failed` steps); throws only `SafeSpaceError.load(_)` or CancellationError.
    public static func run(imageData: Data, source: ImageSource, roomID: String,
                           producer: Producer, options: PipelineOptions = .init(),
                           progress: @Sendable (StepID, StepState) -> Void = { _, _ in }) async throws -> PipelineOutput

    /// Adds one contrast measurement + its findings, bumps updated_at, re-validates.
    public static func addContrast(to record: AssessmentRecord, image: SRGBImage, mask: EligibilityMask,
                                   a: NormalizedRect, b: NormalizedRect) throws -> AssessmentRecord
}
```

The app calls `run` from a `Task` and updates its UI through `progress`. If the user cancels, the task is cancelled, nothing is saved, and the original bytes are dropped.

### 5.10 Errors

```swift
public enum SafeSpaceError: Error, Equatable, Sendable {
    case load(LoadFailure)              // unreadableData, unsupportedFormat, unsupportedColorSpace, emptyImage
    case regionTooSmall(region: RegionSide, eligiblePixels: Int)
    case regionOutOfBounds(region: RegionSide)
    case validation([String])           // human-readable rule failures, for logs and CLI output
    case storage(StorageFailure)        // notFound, corrupt, unsupportedSchemaVersion(String), writeFailed, insufficientSpace
}
public enum ReasonCode: String, Codable, Sendable, CaseIterable { /* §3.3 */ }
```

Step-level errors never leave the pipeline; they become `failed` + `ReasonCode`. `SafeSpaceError` is only for things the caller has to handle.

### 5.11 Storage (Task 14, C)

```swift
public struct Room: Codable, Sendable, Equatable, Identifiable { public let id: String; public var name: String; public let createdAt: Date }
public struct AssessmentSummary: Sendable, Equatable, Identifiable {   // for lists; cheap to load
    public let id: String; public let roomID: String; public let createdAt: Date
    public let overallState: OverallState; public let topColors: [String] /* hex, ≤ 5 */; public let hasImage: Bool
}

public protocol AssessmentStore: Sendable {
    func rooms() async throws -> [Room]                                   // sorted by createdAt
    func createRoom(name: String) async throws -> Room                    // empty name → "Untitled room"
    func renameRoom(id: String, to name: String) async throws
    func deleteRoom(id: String) async throws                              // removes all its assessments
    func assessments(inRoom roomID: String) async throws -> [AssessmentSummary]   // newest first
    func save(_ output: PipelineOutput) async throws                      // validates first; atomic
    func load(assessmentID: String) async throws -> StoredAssessment      // record + image + mask + labelMap
    func update(_ record: AssessmentRecord) async throws                  // after addContrast; atomic
    func deleteAssessment(id: String) async throws                        // removes whole folder
}

public struct StoredAssessment: Sendable { public let record: AssessmentRecord; public let image: SRGBImage?; public let mask: EligibilityMask?; public let labelMap: [UInt8]? }

public final class FileAssessmentStore: AssessmentStore { public init(root: URL) }  // §6
public final class InMemoryAssessmentStore: AssessmentStore { public init() }       // previews and tests
```

The app's `AppModel` becomes a thin `@Observable` wrapper over an `AssessmentStore`. Its placeholder `Room`/`Assessment`/`AnalysisComponent`/`ComponentStatus`/`AssessmentState` types are deleted.

## 6. Storage layout (F3)

```
<Application Support>/SafeSpace/
  rooms/
    <room_id>/
      room.json                         {"schema_version":"1","room_id":…,"name":…,"created_at":…}
      assessments/
        <assessment_id>/
          assessment.json               §4
          image.png                     anonymized working copy (if image.stored)
          mask.png                      eligibility mask (if image.stored)
          labels.png                    palette label map (if image.stored and palette completed)
```

- **The original photo is never written to disk** by the app. Everything a saved assessment uses is in its folder.
- **Atomic writes.** Write into `<assessment_id>.tmp/`, then rename. `update` writes `assessment.json.tmp`, then replaces the original. A leftover `*.tmp` is deleted at launch.
- **Delete** removes the assessment folder (or the room folder) recursively. The storage statement (Task 15) states this exact behavior: "Deleting removes the saved photo copy, the color results and the text for that assessment from this iPhone."
- **Reopen never recomputes.** It decodes `assessment.json` and the PNGs and shows them. If `assessment.json` is corrupt or the schema version is unknown, that assessment appears in the list as "Can't open this assessment", with a Delete action. It must never crash the room list.
- Files use `FileProtectionType.complete`, and the `SafeSpace/` folder is excluded from iCloud backup (open decision **D4**).
- `schema_version` other than `"1"` → `SafeSpaceError.storage(.unsupportedSchemaVersion)`. Once v1 ships, a v2 reader must still read v1 (§12).

## 7. CLI contract (T, owner D)

```
safespace-cli analyze  <image-or-folder> --out <dir> [--method kmeans_pp|median_cut] [--seed N]
                       [--manifest <manifest.csv>] [--no-anonymize] [--no-quality]
                       [--variants none|s1] [--save-images]
safespace-cli contrast <assessment-dir> --a x,y,w,h --b x,y,w,h      # appends to that assessment.json
safespace-cli validate <assessment.json>...
safespace-cli version
```

- The CLI runs `AssessmentPipeline.run` with `source: .file`, `room_id: "cli"`, `producer.kind: "cli"`, and the same default `PipelineOptions` as the app. Anonymization uses `VisionAnonymizer`, since Vision runs on macOS too.
- With `--manifest`, `image_id` comes from the manifest (§8); otherwise it is the file name without its extension. Files in a folder are processed in sorted file-name order. Non-image files are skipped with a warning.
- `--variants s1` also analyzes four derived versions of each image for S1: `resize_50`, `jpeg_q70`, `crop_90` (center 90%) and `rerun` (identical input). Variants are produced in memory with ImageIO.
- **Exit codes:** `0` all images produced valid records (steps may still be failed); `1` usage error; `2` at least one image failed to load or validate; `3` output directory not writable.

### 7.1 Output

```
<out>/
  run.json                    {"core_version", "started_at", "args", "manifest_sha256", "image_count"}
  images.csv                  one row per image × variant
  palette.csv                 one row per palette color
  contrast.csv                one row per contrast measurement (from `contrast` runs)
  <image_id>/[<variant>/]assessment.json    (+ image.png, mask.png, labels.png with --save-images)
```

**images.csv** columns, in order:
`image_id, variant, file, room_type, people_present, quality_label, quality_status, quality_warnings, mean_luminance, clipped_dark_share, clipped_bright_share, blur_laplacian_variance, original_long_side_px, anonymization_status, faces_detected, people_detected, masked_share, palette_status, palette_method, palette_seed, color_count, dropped_share, overall_state, duration_ms, core_version`

**palette.csv**: `image_id, variant, rank, color_id, share, hex, oklab_l, oklab_a, oklab_b, oklch_c, oklch_h, cielab_l, cielab_a, cielab_b`

**contrast.csv**: `image_id, measurement_id, a_x, a_y, a_w, a_h, b_x, b_y, b_w, b_h, a_cielab_l, a_cielab_a, a_cielab_b, b_cielab_l, b_cielab_a, b_cielab_b, delta_e_2000`

CSV rules: RFC 4180, comma separator, header row, UTF-8, `.` as the decimal point. Floats are written with `%.6f`; empty cell for null. List cells such as `quality_warnings` are joined with `;`. `room_type`, `people_present` and `quality_label` are copied from the manifest, so the S7/S8 agreement scripts need only these CSVs.

The Week 6 evaluation scripts (S1, S2, S7, S8, S11) read **only** `images.csv`, `palette.csv`, `contrast.csv` and `run.json`, never the Swift internals. A defines the S1 palette-distance metric in Week 3 and adds it here as a §7.2 amendment.

## 8. Test-image manifest

`room-photos-v0/manifest.csv` is the shared input for the CLI and every evaluation. Required columns:

`image_id, filename, source_page_url, source_title, creator, license, license_url, photo_date, people_present, room_type, split, quality_label, source_checked_at`

| Column | Rule |
|---|---|
| `image_id` | unique, `[A-Za-z0-9_-]+`, stable forever (CSV joins depend on it) |
| `filename` | relative to the manifest; must exist with **exactly** that case and extension |
| `photo_date`, `source_checked_at` | `YYYY-MM-DD` (the README already says so; current rows use `M/D/YY`) |
| `people_present` | `yes`, `no`, `uncertain` |
| `room_type` | `living_room`, `bedroom`, `kitchen`, `bathroom`, `hallway`, `other` |
| `split` | `dev` or `test` (Task 6 "done when" requires it). Tune on `dev`, report on `test`. |
| `quality_label` | `acceptable`, `dark`, `bright`, `blurry`, `low_resolution`, or empty until labeled (Task 13) |

The dataset is versioned by folder (`room-photos-v0`, `-v1`, …), and `run.json` records the manifest's SHA-256.

## 9. Numeric tolerances and determinism

| Check | Tolerance | Where |
|---|---|---|
| CIEDE2000 vs Sharma's 34 pairs | ≤ 1e-4 | `ColorDifferenceTests` (exists) |
| Swift vs Python OKLab / CIELAB | ≤ 1e-3 / ≤ 1e-2 | `testSwiftMatchesPythonReference` (exists) |
| Contrast: identical regions | == 0 | Task 16 tests |
| Contrast: swap a and b | ≤ 1e-9 | Task 16 tests |
| Palette: same input, 10 reruns | **bit-identical** JSON | Task 7 tests, CLI `rerun` variant |
| App vs CLI, same image (Friday check) | bit-identical `steps.palette.result` when given the same bytes | integration day |
| Reopen (S6) | decoded `AssessmentRecord ==` saved one | Task 14 tests |

Determinism rules for palette code: use a seeded PRNG implemented in Core (for example SplitMix64), never `SystemRandomNumberGenerator`. Use no `Set` or `Dictionary` iteration order in the math. Use no parallel reductions whose order can vary, or if they are needed, combine the chunks in a fixed order. Break ties by lower index.

## 10. Integration timeline and stubs

### 10.1 What each role needs from whom, and when

| By | Deliverable | Owner | Unblocks |
|---|---|---|---|
| **Oct 18 (M1)** | This contract approved; v1 JSON Schema + validator + 4 fixtures (§10.2) | C | everyone |
| Oct 18 | Codable models + `AssessmentValidator` + `InMemoryAssessmentStore` in Core | C | B (Task 9 palette screen from fixtures), D (Task 11) |
| Oct 18 | `ImageLoader` on ImageIO (HEIC, orientation); `SRGBImage`/`EligibilityMask` types | A | B, C (Task 21), D (CLI) |
| Oct 18 | `AssessmentPipeline.run` returning a **stub palette** (fixed two colors) with `NoOpAnonymizer` | A | B can wire the real call path in Week 2 |
| Oct 22 | `KMeansPlusPlus` behind `PaletteExtractor` | A | B, D (CLI) |
| Oct 28 | `Findings.generate` + banned-term test | D | B shows text |
| Oct 30 | CLI `analyze` writing §7 outputs | D | S1 baseline |
| Nov 4 | `FileAssessmentStore` | C | B Task 15 |
| Nov 5 | `RegionContrast` + `addContrast` | A | B Task 17 |
| Nov 11 | `QualityCheck` with real metrics | A | B Task 20 |
| Nov 13 | `VisionAnonymizer` | C | Release 3 |

Every module merges early behind its stub (`NoOpAnonymizer`, `runQuality = false`, and so on), so its step shows `skipped / not_implemented` until the real implementation lands (risk R5). Swapping in the real implementation must not change the file format.

### 10.2 Shared fixtures

`Tests/Fixtures/assessments/` (C maintains, everyone uses):

| File | Covers |
|---|---|
| `v1-complete.json` | every step completed, with 2 contrast measurements, 1 face masked |
| `v1-early-build.json` | quality and anonymization `skipped/not_implemented`; palette completed; contrast `not_requested` (the shape of Weeks 2–4 output) |
| `v1-partial.json` | anonymization `failed/detection_unavailable`, `mask_applied: false`, image not stored, contrast `image_unavailable` |
| `v1-palette-failed.json` | palette `failed/no_eligible_pixels` |
| `invalid/*.json` | one file per §4.10 rule, each of which must be rejected |

They are used by: the Swift decode/validate tests, the Python validator, SwiftUI previews (B), the findings tests (D), and the CLI `validate` test. **A fixture change is a contract change.**

## 11. Gaps found in current code

These were found while writing this contract. Each needs an owner and an issue. **Bold** items block other people.

| # | Where | Problem | Contract fix | Owner |
|---|---|---|---|---|
| 1 | `ImageToSRGB.swift` (stb_image) | **stb_image can't decode HEIC.** `NewAssessmentView` asks Photos for `.current` encoding, so most library photos arrive as HEIC and would fail to load. | §5.3: `ImageLoader` on ImageIO/CoreGraphics; remove `CStbImage`. This also satisfies "Apple frameworks only" (decision log, Oct 11). | A |
| 2 | `ImageToSRGB.swift` | **EXIF orientation is ignored.** The working copy would be sideways relative to what B shows, so regions drawn for F6 would average the wrong pixels. | §5.3 applies orientation; §2 defines coordinates on the upright copy. | A |
| 3 | `ImageToSRGB.colorProfile` | ICC is read only from JPEG APP2. PNG/HEIC Display P3 is treated as untagged sRGB. | Let CoreGraphics do the conversion (`CGColorSpace(name: .sRGB)`); record `original.color_space`. | A |
| 4 | `EligibilityMask.swift` | **The mask is typed as `Pixels?`, and `apply` does nothing.** The pipeline uses alpha=0 as "skip", which mixes transparency with eligibility. | §5.2 `EligibilityMask` with `[Bool]`. C (Task 21) depends on this type. | A |
| 5 | `ImagePipeline.analyze` | Returns two raw per-pixel arrays; there is no step structure, status or provenance. | Replace with `AssessmentPipeline.run` (§5.9). Keep the per-pixel conversions as internal helpers. | A |
| 6 | `origin/assessmentJson` v0 | Contrast is a WCAG luminance ratio between palette colors; the palette has no share/L/C/h; there is no provenance (S3), findings (F2) or room. | §4 v1. The validator and README are reused and extended. | C |
| 7 | `origin/swiftUIShell` `AppModel.swift` | Step names `image_quality/privacy/color_palette/visual_contrast` ≠ v0 `quality/anonymization/palette/contrast`; `AssessmentState.partial/pending` isn't in v0. | §3.2, §3.5, §5.9 `StepID`. B deletes the placeholders when C's models land. | B |
| 8 | `origin/swiftUIShell` `NewAssessmentView.maxPhotos = 3` | **1–3 photos per assessment**, but every result in the plan is for one photo (combined palette US-09 is not scheduled). | Open decision **D1**. | B, all |
| 9 | `origin/first20TestImages` `manifest.csv` | Dates are `M/D/YY` (the README says `YYYY-MM-DD`); `livingRoom3` is listed as `.jpg` but the file is `.png`; the `split` column (required by Task 6) and the `quality_label` column are missing. | §8. | C |
| 10 | `README.md` | Describes a Python FastAPI service, URLSession uploads and SQLite/PostgreSQL. This contradicts the decision log (on-device, no server). | Rewrite Tech Stack and Architecture to match §1. | C |
| 11 | `Package.swift` vs app | Package says iOS 16, app target is iOS 17. | Set the package to `.iOS(.v17)`. | A |
| 12 | `ColorSpaceTests.testColorSpaceRed` | Relative path and `exit(1)`: running tests from Xcode or another directory kills the test process instead of failing. | Use `Bundle.module` resources + `XCTFail`. | A |
| 13 | `reference/__pycache__/` | Committed `.pyc` files. | `git rm --cached`; add `__pycache__/` to `.gitignore`. | D |
| 14 | `SafeSpaceCore.version` | `0.1.0` and never bumped. | Bump on every tag (§4.2). | all |

## 12. Change process

1. The contract version is `schema_version` plus this document's version at the top. Both change in the same PR.
2. **Additive change** (new optional field, new reason code, new enum value): PR that edits this doc, the schema, the validator, Swift models and the affected fixtures **together**. It needs approval from every role whose consumer code reads that field. `schema_version` stays `"1"` until the freeze, but the doc's change log records it. (After v1.0-rc a field change means `"2"`.)
3. **Breaking change** (rename, removal, meaning change): all four approve, plus a fixture update and a note in the plan's decision log. Not allowed after Nov 8 ("no new scope").
4. Code that disagrees with this doc doesn't merge, even if it works. Fix the code or the doc first.
5. **Change log**

| Date | Change | By |
|---|---|---|
| Oct 16 | v1 proposed | Kloie (D), drafted with Claude |
| Oct 26 | §4.3 `resize_method` is `area_average_gamma_encoded` (each output pixel averages every source pixel it covers; replaces 4-tap bilinear). Out-of-range EXIF orientation is treated as 1. | Kloie (D) |
| Nov 9 | §4.5 pins the luma formula, Laplacian kernel, border mode, warning comparison rules and warning sort order (clarification, no shape change). Blur uses pure-Swift integer math, not Accelerate, so Windows builds match. `dark_mean_luminance_max` default 0.25 → 0.08 (calibrated on the room-photo set; no completed quality results existed yet, so method version stays 1) (Task 19). | Kloie |
| Nov 8 | §4.3 `original.color_space` adds `adobe_rgb` (additive). The loader detects Adobe RGB and converts it to sRGB; the validator now accepts the value (PR #11). | Kloie (D) |

## 13. Approval

| Role | Checks in particular | Approved (name, date) |
|---|---|---|
| A: Color engine | §4.5, §4.7, §4.8, §5.2–5.7, §9, gaps 1–5 | |
| B: iOS app | §2 coordinates, §3.2–3.5, §4.8 UI text, §5.9, §5.11, gaps 7–8 | |
| C: Storage and safeguards | §4 overall, §4.6, §4.10, §5.5, §5.11, §6, §10.2, gaps 6, 9, 10 | |
| D: Evaluation, wording, docs | §4.9, §5.8, §7, §8, §9 | |

## 14. Open decisions

These need a team answer at or before the Oct 18 gate. The recommended answer is in bold, and the contract above assumes it.

| ID | Question | Options | Recommendation |
|---|---|---|---|
| D1 | One assessment = one photo? | (a) 1 photo per assessment; picking 3 creates 3 assessments; (b) keep 1–3 with per-photo results (photos array; every pointer, rect and file path gains a photo index) | **(a)**. Every feature and success criterion is per photo, and (b) roughly doubles storage and UI work for an unscheduled feature (US-09). Set `maxPhotos = 1`, or make "Save" create one assessment per photo. |
| D2 | If anonymization fails, do we store the working copy? | (a) never store it: no overlay or contrast on reopen; (b) store it anyway; (c) ask the user | **(a) for `failed`**, which matches v0's "Do not automatically save … after anonymization fails". For `skipped/not_implemented` (Weeks 2–4 dev builds, test images without people), store it so B can build the overlay and contrast. |
| D3 | Does a quality warning ever block analysis? | (a) never; (b) block below a hard floor | **(a)**, per the decision log. `user_continued` is always `true`. |
| D4 | Exclude stored assessments from iCloud/device backup? | yes / no | **Yes**. It keeps the "what is stored" statement true (only on this iPhone). |
| D5 | Default palette method | `kmeans_pp` / `median_cut` | Decided by the S1 baseline on Nov 1 (plan, Week 3 gate). Contract supports both. |
| D6 | Is `label` on contrast measurements in the v1 UI? | yes / no | **No**. The field stays reserved as `null`, so adding the UI later isn't a schema change. |
