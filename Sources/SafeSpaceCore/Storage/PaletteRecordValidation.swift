import Foundation

// Week-2 validator: handles the palette path and skipped later steps. It is not
// the complete future validator for completed quality/privacy/contrast modules.
public enum AssessmentValidator {
    public static func validate(_ r: AssessmentRecord) throws {
        var errors: [String] = []
        func require(_ condition: Bool, _ text: String) { if !condition { errors.append(text) } }
        func uuid4(_ value: String) -> Bool {
            value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
        }
        require(r.schemaVersion == "1", "Unsupported schema version")
        require(uuid4(r.assessmentId), "assessment_id must be a lowercase UUID v4")
        require(r.roomId == "cli" || uuid4(r.roomId), "room_id must be a lowercase UUID v4 or cli")
        require(r.updatedAt >= r.createdAt, "updated_at precedes created_at")
        require(["app", "cli"].contains(r.producer.kind), "Unknown producer kind")
        require(!r.producer.coreVersion.isEmpty, "Missing core version")
        require(r.producer.kind != "app" || r.producer.appVersion != nil, "Missing app version")
        require(r.image.workingCopy.colorSpace == "srgb", "Working copy must use sRGB")
        require(r.image.workingCopy.width > 0 && r.image.workingCopy.height > 0, "Invalid image dimensions")
        require(r.image.source == .file || !r.image.original.retained, "App originals must not be retained on disk")
        require(r.image.stored == (r.image.storedFile != nil), "Stored-image metadata disagrees")
        func envelope<T>(_ step: StepRecord<T>, _ name: String) where T: Codable & Equatable & Sendable {
            switch step.status {
            case .completed:
                require(step.reason == nil && step.result != nil && step.method != nil && step.durationMs != nil,
                        "Invalid completed \(name) envelope")
            case .skipped:
                require(step.reason != nil && step.result == nil && step.method == nil && step.durationMs == nil,
                        "Invalid skipped \(name) envelope")
            case .failed:
                require(step.reason != nil && step.result == nil && step.method != nil && step.durationMs != nil,
                        "Invalid failed \(name) envelope")
            }
            require(step.durationMs == nil || step.durationMs! >= 0, "Negative duration")
        }
        envelope(r.steps.palette, "palette"); envelope(r.steps.quality, "quality")
        envelope(r.steps.anonymization, "anonymization"); envelope(r.steps.contrast, "contrast")
        // Later complete result models are intentionally not implemented by this patch.
        require(r.steps.quality.status == .skipped, "This build cannot validate completed quality results")
        require(r.steps.anonymization.status != .completed, "This build cannot validate completed anonymization results")
        require(r.steps.contrast.status == .skipped, "This build cannot validate completed contrast results")
        require([ReasonCode.notImplemented, .disabledByUser].contains(r.steps.quality.reason ?? .notRequested), "Invalid quality reason")
        if r.steps.anonymization.status == .skipped {
            require([ReasonCode.notImplemented, .disabledByUser].contains(r.steps.anonymization.reason ?? .notRequested), "Invalid privacy reason")
        } else {
            require([ReasonCode.anonymizationFailed, .detectionUnavailable].contains(r.steps.anonymization.reason ?? .notRequested), "Invalid privacy failure")
        }
        require([ReasonCode.notRequested, .imageUnavailable, .notImplemented, .dependencyFailed].contains(r.steps.contrast.reason ?? .disabledByUser), "Invalid contrast skip reason")
        require(["heic", "jpeg", "png", "other"].contains(r.image.original.format), "Invalid original format")
        require(["srgb", "display_p3", "untagged", "other"].contains(r.image.original.colorSpace), "Invalid original color space")
        require((1...8).contains(r.image.original.exifOrientation), "Invalid EXIF orientation")
        require(r.image.original.width > 0 && r.image.original.height > 0, "Invalid original dimensions")
        require(r.image.workingCopy.orientationApplied && r.image.workingCopy.resizeMethod == "area_average_gamma_encoded"
                && r.image.workingCopy.gamutMapping == "clip", "Invalid working-copy provenance")
        if !r.image.stored {
            require(r.steps.contrast.reason == .imageUnavailable, "Unstored image requires contrast image_unavailable")
            require(r.steps.palette.result?.labelMapFile == nil, "Unstored image must have null label_map_file")
        }
        let allowedPaletteFailures: [ReasonCode] = [.noEligiblePixels, .paletteExtractionFailed]
        if r.steps.palette.status == .failed {
            require(allowedPaletteFailures.contains(r.steps.palette.reason ?? .notRequested), "Invalid palette failure reason")
        }
        if let p = r.steps.palette.result {
            require(["kmeans_pp", "median_cut"].contains(r.steps.palette.method?.name ?? ""), "Unknown palette method")
            require(r.steps.palette.method?.version == 1, "Unsupported palette method version")
            require(p.eligiblePixelCount > 0, "No eligible pixels")
            require(!p.maskApplied || r.steps.anonymization.status == .completed, "Mask applied without completed anonymization")
            require((1...8).contains(p.colors.count), "Invalid color count")
            require(p.droppedShare.isFinite && (0...1).contains(p.droppedShare), "Invalid dropped share")
            require(abs(p.colors.reduce(0) { $0 + $1.share } + p.droppedShare - 1) <= 1e-9, "Share total differs from 1")
            require(p.colors.reduce(0) { $0 + $1.pixelCount } <= p.eligiblePixelCount, "Too many assigned pixels")
            var previous = Double.infinity
            for (i, c) in p.colors.enumerated() {
                require(c.id == "c\(i + 1)" && c.rank == i + 1, "Invalid rank or ID")
                require(c.share.isFinite && c.share >= 0 && c.share <= previous, "Shares not sorted")
                previous = c.share
                require(c.pixelCount > 0 && abs(c.share - Double(c.pixelCount) / Double(p.eligiblePixelCount)) <= 1e-12,
                        "Share disagrees with pixel count")
                require(c.srgb8.count == 3, "Invalid RGB array")
                if c.srgb8.count == 3 {
                    require(c.hex == String(format: "#%02X%02X%02X", Int(c.srgb8[0]), Int(c.srgb8[1]), Int(c.srgb8[2])), "Hex disagrees with sRGB")
                }
                let numbers = [c.oklab.l, c.oklab.a, c.oklab.b, c.oklch.l, c.oklch.c, c.cielab.l, c.cielab.a, c.cielab.b]
                require(numbers.allSatisfy { $0.isFinite }, "Nonfinite color")
                require((0...1).contains(c.oklch.l) && c.oklch.c >= 0, "Invalid OKLCh")
                require((c.oklch.h == nil) == (c.oklch.c < 0.002), "Invalid achromatic hue")
                if let hue = c.oklch.h { require(hue.isFinite && (0..<360).contains(hue), "Invalid hue") }
            }
        }
        require(Set(r.findings.map(\.id)).count == r.findings.count, "Duplicate finding IDs")
        require(r.findings.contains { $0.templateId == "limitation.photo_not_room" }, "Missing photo limitation")
        if r.steps.anonymization.status != .completed {
            require(r.findings.contains { $0.templateId == "limitation.people_not_masked" }, "Missing privacy limitation")
        }
        let data = try AssessmentJSON.encoder().encode(r)
        let object = try JSONSerialization.jsonObject(with: data)
        for f in r.findings {
            require(!Findings.containsBannedTerm(f.text), "Banned finding wording")
            require(f.kind == .limitation || !f.sources.isEmpty, "Finding lacks measurement source")
            if r.steps.palette.status != .completed {
                require(f.kind == .quality || f.kind == .limitation, "Finding describes unavailable palette")
            }
            for pointer in f.sources { require(resolves(pointer, in: object), "Unresolved finding source: \(pointer)") }
        }
        if !errors.isEmpty { throw SafeSpaceError.validation(errors) }
    }
    private static func resolves(_ pointer: String, in root: Any) -> Bool {
        if pointer.isEmpty { return true }
        guard pointer.hasPrefix("/") else { return false }
        var value: Any = root
        for part in pointer.dropFirst().components(separatedBy: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = value as? [String: Any], let child = object[key] { value = child }
            else if let array = value as? [Any], let i = Int(key), array.indices.contains(i) { value = array[i] }
            else { return false }
        }
        return true
    }
}

// Rejects unknown AND missing keys in the supported early-build wire shape,
// including required nulls. Full later-step decoding belongs to the shared models PR.
enum EarlyBuildWireCheck {
    static func validate(_ data: Data) throws {
        let root = try JSONSerialization.jsonObject(with: data)
        func object(_ value: Any?, _ keys: String) throws -> [String: Any] {
            let expected = Set(keys.split(separator: " ").map(String.init))
            guard let o = value as? [String: Any], Set(o.keys) == expected else {
                throw SafeSpaceError.validation(["Unknown or missing JSON keys; expected: \(keys)"])
            }
            return o
        }
        let r = try object(root, "schema_version assessment_id room_id created_at updated_at producer image steps findings")
        _ = try object(r["producer"], "kind app_version core_version device os")
        let image = try object(r["image"], "source original working_copy stored stored_file")
        _ = try object(image["original"], "format color_space width height exif_orientation retained")
        _ = try object(image["working_copy"], "color_space width height max_long_side resize_method orientation_applied gamut_mapping")
        let steps = try object(r["steps"], "quality anonymization palette contrast")
        for key in ["quality", "anonymization", "palette", "contrast"] {
            let step = try object(steps[key], "status reason duration_ms method result")
            if key != "palette", !(step["result"] is NSNull) {
                throw SafeSpaceError.validation(["This early-build reader does not support completed \(key) results"])
            }
            if let method = step["method"] as? [String: Any] {
                _ = try object(method, "name version params")
                if key == "palette" {
                    _ = try object(method["params"], "space k_initial seed max_iterations merge_delta_e_ok min_share sample_stride")
                }
            }
            if key == "palette", let result = step["result"] as? [String: Any] {
                _ = try object(result, "mask_applied eligible_pixel_count dropped_share colors label_map_file")
                guard let colors = result["colors"] as? [Any] else { throw SafeSpaceError.validation(["colors must be an array"]) }
                for color in colors {
                    let c = try object(color, "id rank share pixel_count hex srgb8 oklab oklch cielab")
                    _ = try object(c["oklab"], "l a b"); _ = try object(c["oklch"], "l c h")
                    _ = try object(c["cielab"], "l a b")
                }
            }
        }
        guard let findings = r["findings"] as? [Any] else { throw SafeSpaceError.validation(["findings must be an array"]) }
        for finding in findings { _ = try object(finding, "id kind template_id template_version text sources") }
    }
}
