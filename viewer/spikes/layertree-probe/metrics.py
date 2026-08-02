"""Pure analysis of CDP LayerTree resize data. No I/O, no browser."""


def layer_area(layer):
    """Device-pixel area a layer covers."""
    w = max(0, layer.get("width", 0) or 0)
    h = max(0, layer.get("height", 0) or 0)
    return w * h


def _draws(layer):
    return bool(layer.get("drawsContent"))


def _geom_key(layer):
    return (
        layer.get("offsetX"), layer.get("offsetY"),
        layer.get("width"), layer.get("height"),
        tuple(layer["transform"]) if layer.get("transform") else None,
    )


def step_reraster(prev_by_id, cur_layers, painted_ids, window_area):
    """One resize step's re-raster picture.

    prev_by_id: {layerId: layer} from the previous step.
    cur_layers: list of layer dicts this step.
    painted_ids: set of layerIds that fired layerPainted this step.
    window_area: device-pixel area of the window (for normalization).

    Returns dict with count_ratio, area_ratio, stable_area_frac,
    geometry_only_ids, geometry_only_area_frac.
    """
    draw_layers = [l for l in cur_layers if _draws(l)]
    total = len(draw_layers)

    painted = [l for l in draw_layers if l["layerId"] in painted_ids]
    count_ratio = (len(painted) / total) if total else 0.0

    painted_area = sum(layer_area(l) for l in painted)
    area_ratio = min(1.0, painted_area / window_area) if window_area else 0.0

    geometry_only_ids = []
    geometry_only_area = 0
    for l in draw_layers:
        lid = l["layerId"]
        if lid in painted_ids:
            continue
        prev = prev_by_id.get(lid)
        if prev is not None and _geom_key(prev) != _geom_key(l):
            geometry_only_ids.append(lid)
            geometry_only_area += layer_area(l)

    return {
        "count_ratio": count_ratio,
        "area_ratio": area_ratio,
        "stable_area_frac": 1.0 - area_ratio,
        "geometry_only_ids": geometry_only_ids,
        "geometry_only_area_frac": (
            min(1.0, geometry_only_area / window_area) if window_area else 0.0
        ),
    }


GREEN_STABLE_THRESHOLD = 0.40  # >= this median stable-area fraction -> A worth building


def median(values):
    vs = sorted(values)
    n = len(vs)
    if n == 0:
        return 0.0
    mid = n // 2
    if n % 2:
        return vs[mid]
    return (vs[mid - 1] + vs[mid]) / 2.0


def page_verdict(steps):
    """GREEN if the median step leaves >= 40% of window area not re-rastered."""
    m = median([s["stable_area_frac"] for s in steps])
    return "GREEN" if m >= GREEN_STABLE_THRESHOLD else "RED"


def overall_verdict(fixed, reflow):
    if fixed == "GREEN" and reflow == "GREEN":
        return "GREEN"
    if fixed == "RED" and reflow == "RED":
        return "RED"
    return "AMBER"


def controls_ok(worst_steps, best_steps):
    """Instrument is trustworthy iff worst control ~fully repaints and best
    control ~fully stable."""
    worst_stable = median([s["stable_area_frac"] for s in worst_steps])
    best_stable = median([s["stable_area_frac"] for s in best_steps])
    return worst_stable <= 0.10 and best_stable >= 0.90
