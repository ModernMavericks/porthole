import metrics


def L(layer_id, w, h, draws=True, x=0, y=0, transform=None, paint_count=1):
    return {
        "layerId": str(layer_id), "width": w, "height": h,
        "drawsContent": draws, "offsetX": x, "offsetY": y,
        "transform": transform, "paintCount": paint_count,
    }


def test_layer_area_is_width_times_height():
    assert metrics.layer_area(L("a", 100, 50)) == 5000


def test_layer_area_clamps_negative_dims_to_zero():
    assert metrics.layer_area(L("a", -100, 50)) == 0


def test_step_reraster_all_painted_is_full_area():
    prev = {"a": L("a", 100, 100)}
    cur = [L("a", 100, 100, paint_count=2)]
    r = metrics.step_reraster(prev, cur, painted_ids={"a"}, window_area=10000)
    assert r["area_ratio"] == 1.0
    assert r["stable_area_frac"] == 0.0
    assert r["count_ratio"] == 1.0


def test_step_reraster_none_painted_is_fully_stable():
    prev = {"a": L("a", 100, 100)}
    cur = [L("a", 100, 100, paint_count=1)]
    r = metrics.step_reraster(prev, cur, painted_ids=set(), window_area=10000)
    assert r["area_ratio"] == 0.0
    assert r["stable_area_frac"] == 1.0


def test_step_reraster_area_ratio_capped_at_one():
    prev = {"a": L("a", 200, 200)}
    cur = [L("a", 200, 200, paint_count=2)]
    r = metrics.step_reraster(prev, cur, painted_ids={"a"}, window_area=10000)
    assert r["area_ratio"] == 1.0


def test_geometry_only_layer_moved_but_not_painted():
    prev = {"a": L("a", 100, 100, x=0)}
    cur = [L("a", 100, 100, x=40, paint_count=1)]
    r = metrics.step_reraster(prev, cur, painted_ids=set(), window_area=10000)
    assert "a" in r["geometry_only_ids"]


def test_non_drawing_layers_excluded_from_ratios():
    prev = {"a": L("a", 100, 100, draws=False)}
    cur = [L("a", 100, 100, draws=False, paint_count=2)]
    r = metrics.step_reraster(prev, cur, painted_ids={"a"}, window_area=10000)
    assert r["count_ratio"] == 0.0


def test_median_odd_and_even():
    assert metrics.median([0.4]) == 0.4
    assert metrics.median([0.2, 0.4, 0.9]) == 0.4
    assert metrics.median([0.2, 0.6]) == 0.4
    assert metrics.median([]) == 0.0


def test_page_verdict_green_when_stable_at_least_040():
    steps = [{"stable_area_frac": s} for s in (0.5, 0.45, 0.6)]
    assert metrics.page_verdict(steps) == "GREEN"


def test_page_verdict_red_when_mostly_repaints():
    steps = [{"stable_area_frac": s} for s in (0.05, 0.1, 0.08)]
    assert metrics.page_verdict(steps) == "RED"


def test_overall_verdict_amber_when_fixed_green_reflow_red():
    assert metrics.overall_verdict(fixed="GREEN", reflow="RED") == "AMBER"
    assert metrics.overall_verdict(fixed="GREEN", reflow="GREEN") == "GREEN"
    assert metrics.overall_verdict(fixed="RED", reflow="RED") == "RED"


def test_controls_bracket_validation():
    worst = [{"stable_area_frac": s} for s in (0.0, 0.02, 0.01)]
    best = [{"stable_area_frac": s} for s in (1.0, 0.99, 1.0)]
    assert metrics.controls_ok(worst_steps=worst, best_steps=best) is True
    bad_best = [{"stable_area_frac": s} for s in (0.3, 0.2, 0.1)]
    assert metrics.controls_ok(worst_steps=worst, best_steps=bad_best) is False
