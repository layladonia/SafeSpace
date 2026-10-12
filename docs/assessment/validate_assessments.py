import copy
import json
import sys
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / "assessment.schema.json").read_text())
Draft202012Validator.check_schema(SCHEMA)
VALIDATOR = Draft202012Validator(SCHEMA, format_checker=FormatChecker())


def validate(data):
    VALIDATOR.validate(data)
    steps = data["steps"]
    anon = steps["anonymization"]
    if anon["status"] == "completed":
        result = anon["result"]
        if result["applied"] != (result["regions_modified"] > 0):
            raise ValueError("Anonymization applied/count mismatch")
    palette = steps["palette"]
    contrast = steps["contrast"]
    if palette["status"] != "completed":
        expected = "dependency_failed" if palette["status"] == "failed" else "dependency_skipped"
        if contrast["status"] != "skipped" or contrast["reason"] != expected:
            raise ValueError("Unavailable palette must skip contrast with the dependency reason")
        return
    ids = [color["id"] for color in palette["result"]["colors"]]
    if len(ids) != len(set(ids)):
        raise ValueError("Palette color IDs must be unique")
    if contrast["status"] == "completed":
        seen = set()
        for pair in contrast["result"]["pairs"]:
            a, b = pair["color_a_id"], pair["color_b_id"]
            if a not in ids or b not in ids or a == b:
                raise ValueError("Contrast pair must reference two different palette IDs")
            key = tuple(sorted((a, b)))
            if key in seen:
                raise ValueError("Duplicate unordered contrast pair")
            seen.add(key)


def self_tests():
    base = json.loads((ROOT / "examples/assessment-completed.json").read_text())
    cases = []
    def add(name, mutate):
        data = copy.deepcopy(base)
        mutate(data)
        cases.append((name, data))
    add("missing step", lambda d: d["steps"].pop("quality"))
    add("invalid status", lambda d: d["steps"]["quality"].update(status="processing"))
    add("completed without result", lambda d: d["steps"]["quality"].update(result=None))
    add("unknown field", lambda d: d.update(unexpected=True))
    add("invalid timestamp", lambda d: d.update(created_at="yesterday"))
    add("unknown color reference", lambda d: d["steps"]["contrast"]["result"]["pairs"][0].update(color_a_id="missing"))
    add("duplicate color IDs", lambda d: d["steps"]["palette"]["result"]["colors"][1].update(id="color-1"))
    add("ratio out of range", lambda d: d["steps"]["contrast"]["result"]["pairs"][0].update(ratio=22))
    add("anonymization mismatch", lambda d: d["steps"]["anonymization"]["result"].update(applied=True))
    add("skipped with result", lambda d: d["steps"]["quality"].update(status="skipped", reason="not_implemented"))
    add("duplicate pair", lambda d: d["steps"]["contrast"]["result"]["pairs"].append(copy.deepcopy(d["steps"]["contrast"]["result"]["pairs"][0])))
    add("completed contrast with failed palette", lambda d: d["steps"].update(palette={"status":"failed","reason":"palette_extraction_failed","result":None}))
    for name, data in cases:
        try:
            validate(data)
        except (ValueError, __import__("jsonschema").ValidationError):
            continue
        raise AssertionError("Invalid record accepted: " + name)
    print(f"PASS: {len(cases)} invalid-record self-tests rejected")


def main():
    files = [Path(p) for p in sys.argv[1:]] or sorted((ROOT / "examples").glob("*.json"))
    for path in files:
        validate(json.loads(path.read_text()))
        print(f"PASS: {path.name}")
    self_tests()
    print("All checks passed.")


if __name__ == "__main__":
    main()
