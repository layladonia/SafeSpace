# Color palette — implementation and peer-review guide

## Purpose and scope

This feature connects one real photo to an on-device palette engine and displays representative swatches, pixel shares, OKLCh values, and limitations on the iPhone assessment result screen.

It replaces the placeholder palette row and abandoned demo/import workflow. The current app does not require manual palette JSON import. Export JSON produces the actual generated assessment record.

Reference: Safe Space API and Data Contract v1 (proposed), particularly sections 2–5, 9, and 11. This is the Week-2 palette implementation, not a complete implementation of every module in the contract. Record team approval of the proposed contract and its open decisions separately.

The palette summarizes colors. It is not the planned two-region contrast measurement and is not a room-safety assessment.

## Current app configuration

In AppModel.analyzeAndAddAssessment:

```swift
var options = PipelineOptions()
options.paletteMethod = .kmeansPP
options.paletteParams.minShare = 0.005

let output = try await AssessmentPipeline.run(
    imageData: photo.originalData,
    source: photo.source == .camera ? .camera : .library,
    roomID: roomID.uuidString.lowercased(),
    producer: producer,
    options: options
)
```

| Parameter | Current app value |
|---|---|
| Method | kmeans_pp |
| Method version | 1 in the supplied extractor |
| Color space | OKLab |
| Initial clusters | 8 |
| Seed | 482 |
| Maximum Lloyd iterations | 50 |
| Merge distance | 0.04, Euclidean OKLab |
| Minimum retained share | 0.005 = 0.5% |
| Sample stride | 1 |

The 0.5% threshold is an explicit app-side override. The supplied shared PaletteParams.v1 default remains 0.01 (1%). Other consumers must pass the same options for an app/CLI comparison. The developer probe as originally supplied uses pipeline defaults; update its options to the same values before comparing it with the app.

Eight is the initial cluster count, not a percentage cutoff. Initialization, empty-cluster removal, merging, and filtering can produce fewer swatches. The current implementation supports at most eight initial clusters; increasing this requires coordinated validation, documentation, and contract review.

## Verification and known evidence

Reported/observed during development:

- The app ran on a physical iPhone and displayed real-photo swatches and percentages.
- A result export showed an actual completed palette with skipped quality/anonymization/contrast steps.
- The synthetic red-accent XCTest passed: one test, zero failures, on an x86_64 macOS runner. That test checks a 5% red patch through loading and both extractors.
- The developer reported that the real bedroom photo now displays a red swatch after selecting k-means++ with the 0.5% minimum share.
- An earlier exported record used median_cut with min_share 0.01, seven near-neutral groups, and dropped_share exactly zero.

These observations do not establish broad numerical accuracy, clinical suitability, cross-device equivalence, performance, or ten-run determinism. A passing synthetic test is not proof that every small accent will be represented.

The code was generated without an Apple SDK/Swift compiler in the authoring environment. The reported successful build/device behavior and XCTest execution occurred on the developer's machine. Remaining tests below need their own recorded evidence.

## Why the minimum share changed

The original result omitted a visibly red accent in a bedroom image. A synthetic two-color test passed, showing that the basic loader/extractor path could represent red, but that test did not reproduce the real scene.

An independent Python reproduction on the uploaded, reduced-size sRGB bedroom image produced a k-means dark-red group (#871930) with a share of approximately 0.762%. This group would fail a 1% filter and pass a 0.5% filter. The reproduction was not execution of the Swift pipeline or Apple's color-management path, so its exact color/count/share must not be presented as the phone's output.

The earlier median-cut export had zero dropped share: in that run, the missing separate red swatch was not caused by the final filter. Its red pixels were represented within other groups. Changing only that run's cutoff would not recover a group that had not been separately formed.

The app now uses k-means++ and a 0.5% cutoff; red was subsequently reported visible on the phone. This is a targeted improvement on one observed case, not evidence that k-means++ is universally better than median cut or that 0.5% is an optimal threshold.

Filtering happens after clustering/merging. Lowering minShare alone retains additional formed groups; it does not change their centers, invent colors, increase measured shares, or renormalize the retained shares. A displayed dropped percentage of 0.0% is rounded; inspect JSON for the exact value.

## User flow

1. Open/create a room.
2. Create a new assessment.
3. Select one library photo or capture one photo.
4. Tap Analyze & Save.
5. Review the palette, percentages, and limitations.
6. Optionally export the generated assessment JSON.
7. Return to the room's current-session history.

One assessment contains one photo, following the proposed contract's recommended D1 option. Photos are not combined into an aggregate palette. Newly selected options affect new analyses only; old assessments are not automatically recomputed.

## Architecture

```text
NewAssessmentView
  -> AppModel.analyzeAndAddAssessment
    -> AssessmentPipeline.run(originalData, options)
      -> ImageLoader
      -> quality: skipped
      -> anonymization: NoOpAnonymizer / skipped
      -> PaletteExtractor
      -> Findings.generate
      -> AssessmentValidator
    -> AssessmentRecord in in-memory shell history
  -> AssessmentResultView
    -> swatches, shares, OKLCh, limitations, step states
    -> optional JSON export
```

Analysis logic belongs in SafeSpaceCore. The app passes originalData, never the display preview, and renders returned measurements. The retained legacy ImagePipeline is not used by this path.

### File responsibilities

Core paths are relative to Sources/SafeSpaceCore/.

| File | Responsibility |
|---|---|
| Color/SRGBImage.swift | Image representation, PNG support, normalized rectangles |
| Color/EligibilityMask.swift | Explicit Boolean mask; isolated deprecated legacy adapter |
| Imaging/ImageLoader.swift | ImageIO/CoreGraphics preprocessing and provenance |
| Color/Palette/PaletteExtractor.swift | Parameters, extractor interface, k-means++, median-cut alternative, labels |
| Storage/PaletteRecordModels.swift | Early-build record types and JSON encoding |
| Storage/PaletteRecordValidation.swift | Early-build semantic validation and wire-key checks |
| Findings/Findings.swift | Finding templates, source pointers, banned-term checks |
| AssessmentPipeline.swift | Shared photo-to-result entry point and step statuses |
| App Models/AppModel.swift | App options, Core invocation, record attachment |
| App Support/ImportedPhoto.swift | Import provenance, preview, original-data lifecycle |
| App Views/NewAssessmentView.swift | One-photo input, analysis loading/cancellation |
| App Views/AssessmentResultView.swift | Result UI and export |
| Tests/SafeSpaceCoreTests/PaletteEngineTests.swift | Engine/record regression tests |
| Tests/SafeSpaceCoreTests/PaletteImageOrientationTests.swift | EXIF orientation and resize tests |
| Tests/SafeSpaceCoreTests/PaletteAccentTests.swift | Synthetic 5% red-accent test |
| tools/PaletteContractProbe | Optional real-image ten-run verification tool |

Keep Core files in the package target, not directly in the app target. App-only test files from the abandoned implementation must not remain in the Core test target.

## Preprocessing and algorithm

ImageLoader decodes with ImageIO, color-manages into full-resolution gamma-encoded sRGB, unpremultiplies to straight RGBA, applies EXIF orientation mapping, and uses explicit bilinear interpolation to resize without upscaling to a maximum long side of 1024.

It replaces the stb_image path. Package.swift removes the CStbImage dependency and uses iOS 17+. Review any remaining imports before deleting legacy third-party files.

Alpha does not decide eligibility. With NoOpAnonymizer, all working-copy pixels are eligible.

Palette processing:

1. Count eligible pixels in an exact 8-bit RGB histogram.
2. Sort packed RGB keys before numerical processing.
3. Convert unique colors to OKLab, weighted by pixel counts.
4. Initialize with seeded weighted k-means++ using SplitMix64.
5. Assign colors and recompute weighted means in fixed order.
6. Stop when assignments stabilize or the iteration limit is reached.
7. Remove empty clusters.
8. Greedily merge the closest pair strictly below the merge threshold.
9. Filter groups below the configured minimum share.
10. Rank retained colors and produce representations and labels.

Ties prefer lower indices; merge-pair ties use lexicographic order. Unordered dictionary traversal does not determine numerical reductions. Role A should review implementation choices not fully specified by the proposed contract, including merge order and the alternative median-cut variant.

Full-resolution rendering before resize can consume substantial memory. The 1024-pixel output limit is not a peak-memory guarantee. Profile representative phones.

## Shares and representations

- share = pixel_count / eligible_pixel_count.
- Fractions are stored at full precision; percentages are rounded only for display.
- Retained shares plus dropped_share total 1 within the contract tolerance.
- Dropped groups are not redistributed or used to renormalize displayed shares.
- OKLab centers are member means.
- Stored srgb8/uppercase hex are converted from the center and clipped.
- CIELAB uses the existing shared conversion on stored srgb8.
- OKLCh hue is null when chroma is below 0.002.
- Labels are rank minus one, or 255 for excluded/dropped pixels.

## Result UI and limitations

The result screen displays swatches, percentages, hex values, OKLCh values, limitations, and component statuses. The technical Method panel was removed; metadata remains in JSON. An Analysis footer explains in-memory storage.

The redundant largest-color-group sentence was removed from new finding generation. The screen filters findings to kind == limitation, so existing records containing the old finding do not show it either. If future measurement narratives are added, revise that UI filter deliberately rather than unintentionally hiding them.

Limitations explain photo-versus-room interpretation, lighting/camera effects, missing people masking, pixel shares versus physical area, the distinction from region comparison, and the absence of quality checking.

Stored findings use versioned template IDs and sources where applicable. Role D must review wording against F2 and the banned-term list; this is an initial limitation library, not every future finding template.

## Palette versus contrast

The palette is an overview, not an exhaustive list of image colors. More swatches or a lower share threshold do not by themselves establish contrast accuracy.

The contract specifies direct region comparison from eligible working-copy pixels: mean CIELAB values for two user-selected regions followed by CIEDE2000. It must not depend on whether those regions' colors appear in the palette.

Keeping a small red group does not reduce the accuracy of that separate calculation. Missing a palette swatch must not make the object's region unavailable for measurement. The region-contrast feature is not implemented in this patch. CIEDE2000 photographic color difference must not be presented as a validated room-safety or accessibility judgment.

## Scope, storage, and privacy

| Component | Current behavior |
|---|---|
| Image loading | Implemented |
| Quality metrics | Skipped/not_implemented, or disabled_by_user |
| Anonymization | NoOpAnonymizer; skipped/not_implemented |
| Palette | Real extraction, completed or failed |
| Region contrast | Not implemented; skipped/image_unavailable |
| Disk history persistence | Not implemented |

Only the NoOpAnonymizer route is supported by the current pipeline. Do not pass a real/custom anonymizer and assume its detection is integrated.

Use non-sensitive test photos without people. Faces/people are not hidden or excluded.

Original bytes are processed in memory and are not automatically written to disk. Saved shell photos clear their originalData reference; previews remain for display. Input state is released on success/cancellation. Releasing references is not secure zeroization.

The app stores no working image automatically, so image.stored=false and stored_file/label_map_file=null. Contrast is image_unavailable under the contract dependency rule. Returned image/label buffers do not imply files exist on disk.

Rooms/results remain in memory and disappear after restart. User-initiated JSON export keeps a result file without exporting original photo bytes. Full AssessmentStore migration, file protection, backup exclusion, persisted image artifacts, and reopen handling remain storage work.

Load failure creates no assessment. Palette failure records no partial palette. Cancellation is checked before commit. Verify these behaviors before acceptance.

The supplied decoder/validator supports the early-build palette subset, not all completed future v1 quality/privacy/contrast payloads. Compatibility shell wrappers remain to support existing room/history views; only AssessmentRecord is exported.

## Testing

### Package resources

If TestImages exists under Tests/SafeSpaceCoreTests, declare it:

```swift
.testTarget(
    name: "SafeSpaceCoreTests",
    dependencies: ["SafeSpaceCore"],
    resources: [.copy("TestImages")]
)
```

Declaring resources does not make a test analyze them automatically. PaletteAccentTests generates its own synthetic image; it does not load bedroom.jpg or red.png unless explicitly changed.

### Commands

```bash
swift test --filter PaletteEngineTests
swift test --filter PaletteImageOrientationTests
swift test --filter PaletteAccentTests
```

Also run the existing suite and distinguish unrelated baseline failures. The legacy ImagePipeline deprecation warning is separate from test success.

### Repeatability and app/probe comparison

Use the SAME options as the app in every comparison, including minShare 0.005:

```swift
var options = PipelineOptions()
options.paletteMethod = .kmeansPP
options.paletteParams.minShare = 0.005
```

In tools/PaletteContractProbe/Sources/palette-contract-probe/Probe.swift, pass those options to each AssessmentPipeline.run call; the original probe omitted options and therefore used the 1% default.

Run:

```bash
swift run --package-path tools/PaletteContractProbe \
  palette-contract-probe \
  /absolute/path/to/photo.heic \
  /absolute/path/to/output
```

The probe is a developer verification tool, not the complete planned CLI/CSV implementation. Compare steps.palette.result, not whole records: IDs, dates, durations, and producer fields legitimately differ. Identical original bytes, configuration, and code version are required. A fresh camera capture or recompressed export is not identical input.

Seeded code alone is not proof of cross-platform equality. Record ten-run and app/probe results on the actual platforms.

## Peer-review and acceptance checklist

- [ ] Review shared-file conflicts and proposed contract decisions.
- [ ] Confirm originalData, not preview, reaches Core.
- [ ] Confirm app AND comparison tool use kmeans_pp/min_share 0.005.
- [ ] Inspect actual JSON parameters rather than assuming defaults.
- [ ] Review orientation, color profiles, channel order, and alpha/mask handling.
- [ ] Review initialization, reduction order, ties, merging, filtering, ranks, and labels.
- [ ] Verify counts, shares, dropped share, color conversions, and hue nulls.
- [ ] Run existing and new tests; attach logs.
- [ ] Verify real library and camera photos on a physical iPhone.
- [ ] Match displayed values to exported JSON.
- [ ] Add a real-bedroom-photo regression if permitted, with the exact byte hash/configuration.
- [ ] Check cancellation and load/extraction failures.
- [ ] Check Back navigation, history thumbnail, and deletion.
- [ ] Check maximum text size, VoiceOver, and light/dark appearance.
- [ ] Confirm Method panel and largest-group sentence are absent; limitations remain.
- [ ] Review F2 text and banned terms.
- [ ] Measure time and memory on representative phones.
- [ ] Verify ten reruns and identical-byte app/probe agreement.
- [ ] Confirm no false claims about implemented privacy, quality, persistence, or contrast.

## Choosing a final default

The current configuration is a candidate, not an established optimum. Compare both extractors using matched thresholds across multiple representative images. Evaluate accent retention, redundant neutral swatches, known synthetic shares, repeatability, readability, time, and memory. Do not optimize only for this bedroom photo or change the maximum above eight without coordinated validation/contract updates.

## Pull-request evidence

Include the tested commit, iPhone/iOS/Xcode versions, approved non-sensitive input identifiers/hashes, actual exported JSON, screenshots, test logs, ten-run comparison output, options used, performance observations, review approvals, and known limitations. Do not commit personal signing configuration, credentials, or private photos.