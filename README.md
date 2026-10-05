# SafeSpace

AI-assisted interior color environment assessment prototype. Texas A&M Senior Capstone.

**Team:** Caiti McInerny · Bhavana Venkatesh · Kloie Kim · Layla Donia

SafeSpace is an iPhone app. Users photograph or upload room photos and get a clear, visual breakdown of the room's color environment. The app then compares that breakdown to a configurable, general low-stimulation design profile built from public sources.

**Independent project:** SafeSpace is built only from student-written code and public/open-source tools, plus Apple's public developer frameworks. It uses no proprietary code, models, datasets, thresholds, or credentials from any outside organization.

## Features

- **Rooms and projects:** create a room (e.g. "Living Room"), take or choose multiple photos, and reopen saved assessments.
- **Privacy / anonymization:** detects visible faces and people on the phone and blurs them in an anonymized analysis copy. It reports when detection may be incomplete.
- **Image-quality checks:** warns about low brightness, overexposure, blur, or very low resolution. It warns and continues instead of blocking.
- **Color palette extraction:** finds dominant colors and the share of the image each covers.
- **Region contrast comparison:** pick two regions (e.g. wall vs. floor) and measure hue, saturation, lightness, and color difference (CIEDE2000).
- **Low-stimulation profile:** a configurable profile based on public design criteria. It keeps measurements, profile rules, and user-facing wording separate.
- **Visual results:** palette swatches with proportions, region overlays, toggleable layers, and plain-language findings with visible limitations.
- **Assessment history:** structured results are saved so assessments can be reopened or deleted.

## Workflow

1. Create or open a room.
2. Take or select one or more photos.
3. The app runs privacy and image-quality checks on the phone.
4. Optionally select two regions for contrast comparison.
5. The anonymized copy is sent to the analysis service for palette and color measurements.
6. Choose an environmental profile.
7. View swatches, overlays, and findings.
8. Save the assessment and reopen it later.

## Tech Stack

| Layer | Technology |
|---|---|
| Client | Native iOS app in Swift with SwiftUI (minimum iOS version: TBD) |
| On-device privacy | Apple Vision framework for face and person detection, with Core Image for blurring |
| Image handling | ImageIO / Core Image for EXIF removal, orientation fix, and HEIC-to-JPEG conversion |
| Analysis service | Python |
| API | FastAPI with OpenAPI / JSON Schema contract |
| Client networking | URLSession (multipart/form-data upload, JSON results) over HTTPS |
| On-device storage | SwiftData (or Core Data) for history; image files in the app sandbox |
| Server storage | SQLite / JSON |
| Optional shared DB | PostgreSQL (only if multi-user persistence is needed) |
| Color standards | sRGB, CIEDE2000 |
| Testing | Manual evaluation, plus optional unit, API, and UI tests (XCTest and XCUITest for the app, pytest for the service) |
| Version control | Git (A&M-controlled repository) |

Exact tested Xcode, iOS, Python, and package versions are pinned (Swift Package Manager `Package.resolved` and the Python lockfile).

**Requirements:** a Mac with Xcode to build the app, and an iPhone or the iOS Simulator to run it. The Python service runs on macOS, Windows, or Linux.

## Architecture

SafeSpace uses a hybrid design. The phone handles privacy steps first, and only the anonymized copy goes to the service.
