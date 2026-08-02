"""Reduce run-*.json files to per-page verdicts + control validation."""
import json
import sys
import metrics


def analyze(run_path):
    d = json.load(open(run_path))
    steps_out = []
    for s in d["steps"]:
        r = metrics.step_reraster(
            prev_by_id=s["prev"], cur_layers=s["layers"],
            painted_ids=set(s["painted_ids"]), window_area=s["window_area"])
        steps_out.append(r)
    return {
        "page": d["page"],
        "pixel_extraction_ok": d.get("pixel_extraction_ok"),
        "median_stable": metrics.median(
            [r["stable_area_frac"] for r in steps_out]),
        "median_reraster_area": metrics.median(
            [r["area_ratio"] for r in steps_out]),
        "median_geometry_only": metrics.median(
            [r["geometry_only_area_frac"] for r in steps_out]),
        "layer_count": (len(d["steps"][-1]["layers"]) if d["steps"] else 0),
        "verdict": metrics.page_verdict(steps_out),
        "_steps": steps_out,
    }


def main():
    runs = {p.split("run-")[1].split(".json")[0]: analyze(p)
            for p in sys.argv[1:]}
    for name, a in runs.items():
        print(f"[{name}] verdict={a['verdict']} "
              f"median_stable={a['median_stable']:.2f} "
              f"reraster_area={a['median_reraster_area']:.2f} "
              f"geometry_only={a['median_geometry_only']:.2f} "
              f"layers={a['layer_count']} pixels_ok={a['pixel_extraction_ok']}")

    if "control-worst" in runs and "control-best" in runs:
        ok = metrics.controls_ok(
            worst_steps=runs["control-worst"]["_steps"],
            best_steps=runs["control-best"]["_steps"])
        print(f"\ncontrols_ok={ok} "
              f"(worst stable={runs['control-worst']['median_stable']:.2f} "
              f"best stable={runs['control-best']['median_stable']:.2f})")
        if not ok:
            print("WARNING: controls did not bracket -- verdicts untrustworthy.")

    if "fixed-shell" in runs and "reflow" in runs:
        overall = metrics.overall_verdict(
            fixed=runs["fixed-shell"]["verdict"],
            reflow=runs["reflow"]["verdict"])
        print(f"\nOVERALL Chromium verdict: {overall}")


if __name__ == "__main__":
    main()
