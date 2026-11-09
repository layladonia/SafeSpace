# Palette method comparison (Task 8)

## Scope
Median cut already exists in PaletteExtractor.swift behind the same PaletteExtractor interface as k-means++. Task 8 adds baseline tests and a reproducible method-comparison tool, not the algorithm. The app continues to use the explicitly configured method. There is no automatic runtime fallback. Median cut is the alternative baseline for the S1/D5 default-method decision if k-means++ is judged unstable.

## Recorded baseline
The local review reports that the committed palette-comparison-results/comparison.csv contains 20 successful method rows for ten images, with identical same-seed reruns for both methods. It reports lower nearest-centroid color error for k-means++ on all ten images, approximately 1.5–2x faster extraction for median cut, median-cut seed independence, and k-means++ cross-seed palette distances of approximately 0.002–0.031 in OKLab. These observations describe this ten-image sample and local run; they are not guarantees for other images or devices. Consult the committed CSV and run metadata for exact measurements.

This evidence supports retaining k-means++ as the current default on color-error grounds, with median cut retained as a deterministic alternative. Formal D5 approval remains a project decision; seed sensitivity and exact same-seed repeatability are distinct properties.

## Reproduce
Run from the repository root:

```sh
swift test --filter MedianCutBaselineTests
swift run -c release safespace-cli --compare Datasets/room-photos/images docs/Palette/palette-comparison-images.txt docs/Palette/palette-comparison-results

```

The manifest fixes the Task 8 sample of ten filenames. The tool itself accepts any non-empty manifest of distinct basenames, one per line, ignoring blank lines and lines starting with #. Image paths are resolved against the image folder. Use a new output directory for another sample or experiment to keep runs separate. Rerunning overwrites artifacts for the selected filenames but does not remove old artifacts from other runs.

`--compare` is a development-only utility, not an additional contract analyze/contrast/validate command. `--help` identifies it as such. Usage/configuration errors return exit code 1; unsuccessful execution returns 2; a successful run returns 0. Diagnostics go to stderr; progress and help go to stdout. Input image decode failures are execution failures recorded in the CSV, not usage errors.

## Method and timing
Each image is decoded once by ImageLoader. Both extractors receive the same working image, mask and PaletteParams.v1. Defaults remain kInitial=8, seed=482, maxIterations=50, mergeDeltaEOk=0.04, minShare=0.01, sampleStride=1, space=oklab. Do not change parameters for only one method.

Each method has one untimed warm-up and three timed same-seed extractions. A monotonic clock measures extraction only; decoding, metrics and file serialization are excluded. The CSV reports median extraction time. Method order alternates between images to reduce systematic ordering bias. This small in-process benchmark is not a controlled production performance study. Timing comparisons should use the same machine and build configuration.

## Reading the CSV
- image/method/status identify the input, extractor and outcome. An N-image manifest produces 2N rows, including explicit failure rows.
- colors is the retained color count. dropped_share is a fraction of eligible pixels, not a percentage. Retained shares plus dropped_share equal one.
- same_seed_identical_3_runs compares exact PaletteResult values and full label maps across three runs. Runtime is not part of that equality.
- mean_nearest_oklab_error is mean Euclidean OKLab distance from every eligible pixel to its nearest retained unrounded centroid. It includes pixels whose assigned cluster was dropped. Lower means better approximation by this metric, not object recognition or validated contrast/safety accuracy. Displayed hex colors are rounded and gamut-clipped.
- seed_sensitivity_chamfer_oklab is the mean symmetric, share-weighted nearest-centroid distance from the base seed palette to the palettes for seed+1 and seed+2. Smaller indicates less sensitivity for these probes, not an exhaustive stability guarantee. Median cut does not use a seed and should have zero sensitivity.
- palette_hex_and_shares lists display colors and their fractions.
- error is populated for load/extraction failures. Failed rows or differing same-seed reruns cause a nonzero command exit after table generation.

## Retained artifacts
Keep comparison.csv, per-image/method palette JSON files, and run-metadata.json. Label maps are used only in memory for repeatability checks; this tool no longer saves .labels.bin files. Do not commit previously generated label-map binaries. The command does not delete existing files.

The deliberately blurry image remains in this sample. The current quality step is not implemented, so inclusion does not indicate a passed quality check. These are individual-photo comparisons, not pooled room analyses; the app's photo limit and capture flow are unchanged.
