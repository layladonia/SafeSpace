# Task 5: SwiftUI shell and PhotosPicker import

Owner: B. Window: Oct 12–18. Needs: Task 1 (repository).

Done when: a photo is picked on a real iPhone and displayed, and the navigation skeleton exists.

## What's in here

```
SafeSpace/
  App/SafeSpaceApp.swift          @main, NavigationStack driven by Route values
  App/Router.swift                Route enum + navigation path
  Models/AppModel.swift           In-memory rooms/assessments + placeholder contract enums
  Support/ImportedPhoto.swift     Keeps original bytes; ImageIO preview with orientation applied
  Views/RoomListView.swift        Rooms: add, list, delete, empty state
  Views/RoomDetailView.swift      One room: "New assessment" + history, delete
  Views/NewAssessmentView.swift   PhotosPicker (1–3 photos), loading, per-photo errors, Save
  Views/AssessmentResultView.swift Photos + one "Not run yet" row per pipeline step
Config/Signing.xcconfig           Shared signing settings (commit)
Config/Local.xcconfig.example     Per-developer template (copy to Local.xcconfig, don't commit)
.gitignore.additions              Lines to append to the repo's .gitignore
```

Navigation skeleton: Rooms → Room → New assessment → Result. After Save, the result screen replaces the picker, so Back goes to the room.

Apple frameworks only: SwiftUI, PhotosUI, ImageIO, UniformTypeIdentifiers, Observation. Deployment target iOS 17 (needed for `@Observable` and `ContentUnavailableView`).

## Create the Xcode project (once, by B)

1. Xcode → File → New → Project → iOS → App. Product Name `SafeSpace`, Interface SwiftUI, Language Swift, Storage None. Save it inside the repository (for example `App/`).
2. Delete the template's `ContentView.swift` and `SafeSpaceApp.swift`.
3. Drag the `SafeSpace/` folder from this package into the project navigator. Choose "Copy items if needed" and check the SafeSpace target.
4. Target → General → Minimum Deployments → iOS 17.0.
5. Target → Info → Custom iOS Target Properties → add **Privacy - Camera Usage Description** with the text `Safe Space uses the camera to photograph a room for color analysis.` Without it the app crashes when Take photo is tapped.
6. Build for an iPhone simulator (⌘B) to confirm it compiles before touching signing.
7. Commit the project and the `Config/` folder; append `.gitignore.additions` to `.gitignore`.

When the `SafeSpaceCore` package from Task 1 exists: File → Add Package Dependencies → Add Local… → select the package, add it to the SafeSpace target. The shell doesn't import it yet.

## Signing without merge conflicts (recommended)

With free Apple Accounts, each person has a different Personal Team, and a bundle ID registered by one team can't be used by another. If everyone edits Signing & Capabilities directly, `project.pbxproj` will conflict on every pull. Instead:

1. Drag `Config/Signing.xcconfig` into the project navigator, unchecking all targets (it's a build setting file, not app content). Then Project (not target) → Info → Configurations → set Debug and Release to `Signing` for the SafeSpace target.
2. Target → Build Settings → search "Development Team" and "Product Bundle Identifier". If either is bold (set at target level), select it and press Delete so it inherits from the xcconfig.
3. Each developer: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in their team ID and a unique suffix (e.g. NetID).

Each person then gets their own bundle ID, such as `edu.tamu.safespace.cmcinerny`.

## Run on a real iPhone (each developer)

1. Xcode → Settings → Accounts → add your Apple Account.
2. Connect the iPhone with a cable and tap Trust on the phone.
3. On the iPhone: Settings → Privacy & Security → Developer Mode → On, then restart.
4. Select the iPhone as the run destination and press Run (⌘R).
5. First launch only: Settings → General → VPN & Device Management → your Apple Account → Trust.

Free-account builds expire after 7 days and you can register at most 3 devices. Re-run from Xcode every Monday (risk R3).

## Acceptance check

Do this on a physical iPhone and save a screenshot of each step for the M1 tag.

- [ ] App launches to Rooms with the empty-state message.
- [ ] Add room "Living Room"; it opens the room screen.
- [ ] New assessment → Choose photos opens the system picker with no permission prompt.
- [ ] Pick one HEIC photo from the camera roll; it appears upright with size and format shown (e.g. `4032 × 3024 pixels, HEIC`).
- [ ] Pick three photos; all three appear in the order selected.
- [ ] Take photo asks for camera permission once, then the captured photo appears upright, marked "from camera".
- [ ] With 3 photos added, Take photo is disabled; Remove on any photo re-enables it.
- [ ] Save goes to the result screen; all four steps say "Not run yet".
- [ ] Back returns to the room (not the picker); the assessment is in History with a thumbnail.
- [ ] Swipe to delete the assessment, then the room.
- [ ] Settings → Accessibility → Larger Text at maximum: no clipped text on any screen.
- [ ] Record the iPhone model, iOS version and Xcode version in the repo.

## Notes for the other roles

- C (Task 2): `AssessmentState`, `AnalysisComponent` and `ComponentStatus` in `AppModel.swift` are placeholders using the contract's words. Once `assessment.json` v0 types are in SafeSpaceCore, delete these and use yours.
- A (Task 3): `ImportedPhoto.originalData` is the untouched file from Photos, including its color profile (often Display P3). `preview` is for display only and must not be used for color analysis. `exifOrientation` is recorded so the working copy can normalize orientation.
- C (Task 14): nothing is written to disk; quitting the app clears everything. The original bytes live in memory only, which fits the plan to discard originals after anonymization.
- Camera photos come from the system camera screen as a processed image, not a file, so they're saved as an upright full-quality JPEG (`Support/CameraPicker.swift`). Library photos keep their original bytes. `ImportedPhoto.source` records which is which. Camera photos are not saved to the user's photo library.
- Image decoding for previews runs on the main thread. That's fine for 1–3 photos; analysis in Phase 2 should run off the main actor.
