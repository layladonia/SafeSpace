# SafeSpace — median-cut baseline and method comparison patch

## Status
Code patch generated against the uploaded Swift sources. No Swift compiler is installed in the generation environment: native compilation, XCTest execution, and the ten-image Swift benchmark have NOT been run. No measured comparison.csv is included or fabricated. The command below creates it on your Mac. Do not mark the full task complete until that run succeeds and its artifacts are committed.

## Install
From this patch, copy the Sources and Tests files into the same relative locations in your repository. Replace ONLY the existing AssessmentPipeline.swift and safespace-cli/main.swift. Add the other Swift files. Copy docs/palette-comparison-images.txt and this guide into your docs folder. Keep all your existing files. The included PaletteExtractor.swift is an unchanged copy of your uploaded baseline for review; it can be left untouched in your repository. Do not add duplicate copies of a replaced file to a target. No Package.swift, AppModel.swift, result-view, or app Palette-folder change is required: SwiftPM automatically discovers added Swift files in the existing targets.

## Existing baseline retained
Your existing PaletteExtractor.swift already implements KMeansPlusPlus and MedianCut behind PaletteExtractor and makePaletteExtractor. Median cut uses pixel-count-weighted splits in OKLab: choose the box/axis with greatest range; sort with deterministic ties; split near half the pixel weight; compute weighted mean centroids. Both methods use the existing identical merge/minimum-share/label-map code. This patch does not replace that algorithm, change method version 1, or change defaults.

Defaults retained from your uploaded code: kInitial=8, seed=482, maxIterations=50, mergeDeltaEOk=0.04, minShare=0.01, sampleStride=1, space=oklab. This is a 1% minimum share, not the 0.5% setting discussed previously. If the team wants 0.5%, change the shared setting deliberately and rerun BOTH methods. Do not compare different parameter sets.

## App fallback
PipelineOptions.paletteFallback defaults to .medianCutOnFailure. The pipeline still requests k-means++ by default. PaletteRunner attempts median cut once if k-means++ throws noRetainedColors or returns an output that fails the runner's count/share/label/numeric integrity checks. Invalid parameters, no eligible pixels, cancellation and unexpected errors propagate; median-cut failures propagate without recursion. The existing pipeline converts ordinary propagated extraction errors to a failed step; cancellation remains cancellation.

The completed method record names the method that actually produced the palette. A limitation finding records fallback and its reason. No new assessment JSON keys are added (your wire validator rejects unknown keys). Palette duration includes primary extraction, checks, and any fallback. If fallback also fails, there is no completed result; the failed step retains the requested method record.

This is failure recovery, NOT automatic perceptual-instability detection. The existing engine has no convergence diagnostic; reaching maxIterations is not treated as failure. It also does not detect whether a visually important object color is missing. Same-seed repeatability and cross-seed sensitivity are measured by the comparison command; the team can explicitly select median cut if those results warrant it:

```swift
var options = PipelineOptions()
options.paletteMethod = .medianCut
// Pass options to AssessmentPipeline.run as before.
```

To disable automatic fallback:
```swift
options.paletteFallback = .disabled
```

## Run on your Mac
Open Terminal in the repository root (the folder with Package.swift):

```sh
swift test --filter MedianCutBaselineTests
swift run -c release safespace-cli --compare Datasets/room-photos docs/palette-comparison-images.txt docs/palette-comparison-results
```

If your images are in a different folder, replace only Datasets/room-photos. The manifest uses the exact case-sensitive filenames you uploaded. All ten originals must be present locally. Comparison runs are independent photo analyses, not pooled room palettes; nothing changes your room photo limit or app capture flow.

## Outputs
- comparison.csv: 20 rows (ten images times two methods); failures remain explicit rows.
- run-metadata.json: actual parameters, core version, OS, CPU count, date and file list.
- 20 palette JSON files and 20 raw row-major label maps (one UInt8 per working-copy pixel, 255=excluded/dropped).

Each image is decoded once by your ImageLoader; both methods share that working copy and mask. No fallback is used in the benchmark. One untimed warm-up precedes three timed same-seed extractions. The CSV uses the median of the three durations. A monotonic timer measures only extractor execution, excluding decoding, metrics, output serialization and runner integrity checks. Order alternates by image. This is a small in-process comparison, not a controlled production performance study. Repeat on the same Mac and record hardware/build context in your report.

same_seed_identical_3_runs compares exact PaletteResult values and label maps, not timestamps. It is distinct from seed sensitivity. seed_sensitivity_chamfer_oklab is the mean symmetric share-weighted nearest-centroid distance from seed 482's retained palette to seeds 483 and 484. Smaller indicates lower sensitivity in these three probes; zero is expected for median cut because it does not use a seed. This is not an exhaustive stability guarantee and is not a trigger for automatic app fallback.

mean_nearest_oklab_error averages Euclidean OKLab distance from EVERY eligible input pixel to its nearest RETAINED unrounded OKLab centroid, including pixels dropped by the final share threshold. Lower means better nearest-centroid color approximation by this metric. It does not measure object recognition, region contrast, safety, physical area, or validated clinical accuracy. The exported hex colors can differ slightly because they are clipped/rounded for display. dropped_share is a fraction of all eligible pixels; retained shares plus dropped share equal one.

The deliberately blurry image remains in the benchmark and is not silently rejected. Your current quality step is not implemented; palette results must not be interpreted as passing a photo-quality check.

Missing/undecodable images and extraction failures are saved as error rows and cause nonzero command exit after saving. A non-repeatable result also causes nonzero exit. Setup/file-write failures can prevent saving; fix the reported error and rerun. Do not replace missing images silently after starting the report; update the manifest and rerun both methods if the sample changes.

## Tests included (not yet executed here)
Shared-interface/count conservation; weighted one-centroid mean; solid-color input; mask exclusion; no eligible pixels; invalid parameters; median-cut seed independence; fallback success/provenance; disabled fallback; invalid-output fallback; unexpected-error propagation; secondary failure without recursion; cancellation propagation; sampled clustering/full-pixel accounting.

## Done when
1. The app and SwiftPM targets compile.
2. New and existing tests pass.
3. comparison.csv has 20 successful rows for the fixed ten originals.
4. Repeatability and seed-sensitivity results have been reviewed (differences are evidence, not automatic algorithm failure).
5. Commit the patch, manifest, comparison outputs and report interpretation.
