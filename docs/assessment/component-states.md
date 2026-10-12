# Assessment component states — v0

## Scope
This contract describes finalized saved assessments, not in-progress jobs.
Every assessment contains quality, anonymization, palette, and contrast.
UI text below is a proposed shared behavior; no UI implementation is included.

| Saved status | Meaning | Data | UI |
| --- | --- | --- | --- |
| completed | The operation finished and returned a valid result. | Non-null result; null reason. | Completed; display result. |
| skipped | The operation was not attempted. | Null result; reason code. | Skipped; display explanation. |
| failed | The operation was attempted but could not return a valid result. | Null result; reason code. | Couldn't complete; display explanation. |

A low-contrast finding is not a processing failure. A successfully executed
quality check can return acceptable=false and still be completed.
No partial results are stored for failed or skipped steps in v0.

## Live component states
Use idle and processing in app memory, separately from saved statuses.
Do not write them to assessment.json. Save after all four outcomes are resolved.
If interrupted/in-progress assessments must be saved, revise the contract first;
do not mislabel an unfinished operation as skipped.

## Reason-code presentation
- not_implemented: This check is not available yet.
- dependency_failed: This check could not run because a required earlier step failed.
- dependency_skipped: This check could not run because a required earlier step was skipped.
- palette_extraction_failed: The app could not extract a usable color palette.
- quality_check_failed: The app could not check image quality.
- anonymization_failed: The app could not anonymize the image.
- contrast_calculation_failed: The app could not calculate color contrast.
- user_disabled: This optional check was disabled.
- Unknown code: This step could not be completed. Show technical code in details.

Reason codes use lowercase snake_case. This list is intentionally extensible.
Never infer a retry action from status alone. A retry button needs an implemented
handler and access to the necessary input.

## Results to display
- quality: acceptable and issues. An empty issues array means no issues reported.
- anonymization: applied and regions_modified. Completed with applied=false and
  regions_modified=0 means the operation ran but did not modify any regions.
  It is not the same as skipped and does not guarantee the image contains no
  identifying information.
- palette: color swatches, hex values, and stable color IDs within this assessment.
- contrast: the selected color pairs and their numerical ratios.

Do not label room measurements as a WCAG pass or a safety guarantee.
The v0 pairs describe colors, not identified physical objects or adjacency.

## Dependencies and privacy
Completed contrast requires completed palette and at least one valid pair.
If palette fails, skip contrast with dependency_failed. If palette is skipped,
skip contrast with dependency_skipped. The validator enforces these rules.
The quality gate and anonymization-failure policy require explicit team approval.
Do not automatically save or display an original image after anonymization fails.
This JSON format contains no image paths, image bytes, room names, or user names.
Image retention and anonymization enforcement are separate implementation work.

## Review
These are proposed v0 decisions. All four teammates must review before approval.
