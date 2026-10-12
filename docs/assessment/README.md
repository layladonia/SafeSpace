# SafeSpace assessment.json v0

## Deliverables
- assessment.schema.json: JSON Schema Draft 2020-12 rules.
- examples/assessment-completed.json: all operations completed; anonymization ran
  but modified no regions.
- examples/assessment-skipped.json: quality/anonymization not implemented.
- examples/assessment-failed.json: palette failed; contrast blocked.
- component-states.md: status semantics and component behavior.
- validate_assessments.py: schema validation, semantic validation, and self-tests.

All example results are synthetic fixtures, not outputs from a real room.

## Installation in the repository
Copy this assessment directory into the existing SafeSpace/docs directory.
Do not replace App, Sources, Tests, Package.swift, or the root README.md.
No Swift manifest changes are necessary for these documentation deliverables.
These example filenames are fixtures. Actual assessment storage is not specified
by their location. Store real assessments by unique assessment ID; do not
repeatedly overwrite one global assessment.json.

## Contract
schema_version is the string "0". assessment_id is a nonempty unique identifier
assigned by the producer; uniqueness across saved records is storage's job.
created_at is an RFC 3339 timestamp; use UTC Z timestamps when writing files.
All four steps and all status/reason/result fields are required.
Unexpected object fields are rejected. Completed steps contain a typed result
and null reason. Other statuses contain null result and a reason code.

### Step result shapes
quality: {acceptable: boolean, issues: string[]}. No blur/brightness metrics are
mandated in v0. The future quality algorithm must map findings to this shape.
anonymization: {applied: boolean, regions_modified: nonnegative integer}.
applied must equal whether regions_modified > 0.
palette: {colors: [{id: string, hex: #RRGGBB}]}. At least two colors are required
for a usable v0 contrast palette. IDs are unique within one assessment.
contrast: {method: "srgb_relative_luminance", pairs: [{color_a_id: string,
color_b_id: string, ratio: number}]}. Ratios range from 1 through 21 inclusive.
Pair IDs reference palette colors, reference different IDs, and may not repeat
an unordered pair. Store selected pairs; v0 does not require all combinations.
Ratios use sRGB relative luminance, not measured real-world luminance. Different
measurement methods require a contract revision. The validator checks structure
and references, not whether the algorithm calculated the ratio correctly.

Quality and anonymization result fields are a deliberate minimum. If future
algorithms need more persisted fields, revise the schema version instead of
silently adding fields. Reserving a step now does not promise unlimited future
compatibility. Image assets, object/region labeling, thresholds, overall pass/fail,
and live progress persistence are outside v0.

## Validation
From the SafeSpace repository root, run:

    python3 -m pip install jsonschema rfc3339-validator
    python3 docs/assessment/validate_assessments.py

The script checks its schema, validates all three fixtures, checks semantic
constraints, and confirms representative invalid records are rejected.
It uses paths relative to its own location, so it also works from another directory.
To validate your own assessment:

    python3 docs/assessment/validate_assessments.py path/to/assessment.json

JSON Schema alone cannot enforce these cross-value rules here: unique palette
IDs, valid pair references, nonduplicate pairs, and anonymization count agreement.
Equivalent checks must be implemented by the app/CLI before saving or accepting
records. Swift Codable decoding alone is not this complete validator.

## Team approval checklist
- [ ] Storage owner approves identifiers, timestamp, and version behavior.
- [ ] App owner approves result shapes and component-state presentation.
- [ ] CLI owner approves parsing and validation behavior.
- [ ] Pipeline owner approves outputs, dependencies, and future-step placeholders.
- [ ] All four teammates review all three samples.
- [ ] Team decides whether poor image quality blocks later processing.
- [ ] Team decides how anonymization failures affect image processing and retention.
- [ ] Team confirms finalized-only persistence is sufficient.

Reviewer 1: __________________ Date: __________
Reviewer 2: __________________ Date: __________
Reviewer 3: __________________ Date: __________
Reviewer 4: __________________ Date: __________

Status: ready for review; not team-approved. No Swift models, UI components,
image-processing algorithms, or automated Swift tests are implemented here.
