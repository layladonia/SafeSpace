# SafeSpace

AI-assisted interior color environment assessment prototype.
Texas A&M Senior Capstone.

**Team:** Caiti McInerny · Bhavana Venkatesh · Kloie Kim · Layla Donia

**Sponsor:** Nuronest

SafeSpace lets users upload room photos and get a clear, visual breakdown of the room's color environment. It then compares that breakdown to a configurable, general low-stimulation design profile built from public sources.

> **Independent project:** SafeSpace is built only from student-written code and public/open-source tools. It uses no proprietary code, models, datasets, thresholds, or credentials from any outside organization.

---

## Features

- **Rooms and projects:** create a room (e.g. "Living Room"), upload multiple photos, and reopen saved assessments.
- **Privacy / anonymization:** detects visible faces and people and blurs them in an anonymized analysis copy. It reports when detection may be incomplete.
- **Image-quality checks:** warns about low brightness, overexposure, blur, or very low resolution. It warns and continues instead of blocking.
- **Color palette extraction:** finds dominant colors and the share of the image each covers.
- **Region contrast comparison:** pick two regions (e.g. wall vs. floor) and measure hue, saturation, lightness, and color difference (CIEDE2000).
- **Low-stimulation profile:** a configurable profile based on public design criteria. It keeps measurements, profile rules, and user-facing wording separate.
- **Visual results:** palette swatches with proportions, region overlays, toggleable layers, and plain-language findings with visible limitations.
- **Assessment history:** structured results are saved so assessments can be reopened or deleted.

## Workflow

1. Create or open a room.
2. Upload one or more photos.
3. Run privacy and image-quality checks.
4. Optionally select two regions for contrast comparison.
5. Extract the palette and color measurements.
6. Choose an environmental profile.
7. View swatches, overlays, and findings.
8. Save the assessment and reopen it later.

## Tech Stack

| Layer | Technology |
|---|---|
| Client | _[Confirm: React Native / Flutter / Web]_ |
| Analysis service | Python |
| API | FastAPI with OpenAPI / JSON Schema contract |
| Local storage | SQLite / JSON |
| Optional shared DB | PostgreSQL (only if multi-user persistence is needed) |
| Color standards | sRGB, CIEDE2000 |
| Testing | Manual evaluation plus optional unit, API, and UI tests |
| Version control | Git (A&M-controlled repository) |

Exact tested OS, runtime, and package versions are pinned in the lockfiles.

## Architecture

Each analyzer is modular and returns a structured JSON result independent of the UI.

| Component | Purpose |
|---|---|
| `privacy` | Face/person detection and anonymization |
| `image_quality` | Brightness, exposure, blur, resolution checks |
| `color_palette` | Dominant colors and proportions |
| `visual_contrast` | Region-pair color difference |
| `surface_color` | Optional major-surface analysis |
| `environment_profile` | Applies the configurable profile |

Every result records a schema version, component version, state (`completed`, `skipped`, `failed`), which image copy was used, color space, method, and warnings. A failed optional component never erases results from the others.

**Example API routes** (illustrative):
- `POST /v1/assessments`: submit photos (multipart/form-data)
- `GET /v1/assessments/{id}`: get status and results

## Getting Started

```bash
# Clone
git clone <repo-url>
cd safespace

# Backend
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload

# Client
cd ../client
# install and run steps depend on the chosen framework
```

_Update the commands above to match the final repository structure._

## Privacy and Data Handling

- Only public or consented test images are used. No real client or resident images are collected.
- Raw uploads are kept only as long as needed for testing or anonymization. Saved history uses the anonymized copy and structured results.
- Location and camera metadata are removed.
- Originals, anonymized copies, and derived artifacts are stored separately.
- No secrets, credentials, or sensitive images are committed.
- Supported formats: JPEG and PNG (HEIC only if converted and tested).

## Limitations

- Results are observations about a photo, not verified material properties.
- Values change with lighting, shadows, and camera processing.
- SafeSpace does **not** report illuminance (lux) or light reflectance value (LRV).
- Color difference alone does not show that a feature is visible or accessible to a person.
- Findings are design-focused and **not** diagnostic or clinical. SafeSpace never labels a room "good" or "bad" for any condition.
- Tested file-size, photo-count, and timeout limits are documented in the OpenAPI spec.

## Testing

Evaluation covers anonymization recall, image-quality agreement with manual labels, palette repeatability under lighting changes, region-contrast repeatability, profile rule correctness, API schema validation, and UI error/retry flows. Results and known failure cases are reported honestly in the test documentation.

## Datasets and Licenses

All datasets, models, and libraries are listed with source, version, and license in the license manifest (`docs/LICENSES.md`).

## Acknowledgments

Texas A&M University Senior Capstone.
