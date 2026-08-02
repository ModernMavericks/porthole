"""Drive a CDP resize sweep on one page and record per-step layer data."""
import json
import sys
import urllib.request


def ws_url(http_base):
    # Chromium 148 splits browser vs page targets: /json/version yields the
    # BROWSER endpoint, which rejects Page/LayerTree/Emulation. Prefer a page
    # target from /json/list; fall back to the browser endpoint if none.
    with urllib.request.urlopen(http_base + "/json/list", timeout=5) as r:
        targets = json.load(r)
    pages = [t for t in targets if t.get("type") == "page"
             and t.get("webSocketDebuggerUrl")]
    if pages:
        return pages[0]["webSocketDebuggerUrl"]
    with urllib.request.urlopen(http_base + "/json/version", timeout=5) as r:
        return json.load(r)["webSocketDebuggerUrl"]


def layers_by_id(layers):
    return {l["layerId"]: l for l in layers}


def run(http_base, page_url, out_path,
        start_w=900, end_w=1400, height=900, steps=20):
    import cdp
    conn = cdp.CDP(ws_url(http_base))
    try:
        conn.send("Page.enable")
        conn.send("DOM.enable")
        conn.send("LayerTree.enable")
        conn.send("Page.navigate", {"url": page_url})
        conn.pump(2.0)  # let it load + first compositing pass settle

        recorded = []
        prev = {}
        step_px = (end_w - start_w) / max(1, steps - 1)
        for i in range(steps):
            w = int(round(start_w + i * step_px))
            conn.drain_events()  # clear anything from before this step
            conn.send("Emulation.setDeviceMetricsOverride", {
                "width": w, "height": height,
                "deviceScaleFactor": 1, "mobile": False})
            conn.pump(0.12)  # let relayout/raster + LayerTree events land

            painted = {p.get("layerId") for (_m, p) in
                       conn.drain_events("LayerTree.layerPainted")}
            changes = conn.drain_events("LayerTree.layerTreeDidChange")
            layers = changes[-1][1].get("layers", []) if changes else \
                list(prev.values())

            recorded.append({
                "step": i, "width": w, "height": height,
                "window_area": w * height,
                "layers": layers,
                "prev": prev,
                "painted_ids": sorted(x for x in painted if x),
            })
            prev = layers_by_id(layers)

        # Prove pixel extractability once, on the largest drawing layer.
        pixel_ok = False
        big = None
        for rec in reversed(recorded):
            drawing = [l for l in rec["layers"] if l.get("drawsContent")]
            if drawing:
                big = max(drawing, key=lambda l: (l.get("width", 0) *
                                                  l.get("height", 0)))
                break
        if big:
            try:
                snap = conn.send("LayerTree.makeSnapshot",
                                 {"layerId": big["layerId"]})
                data = conn.send("LayerTree.replaySnapshot",
                                 {"snapshotId": snap["snapshotId"]})
                pixel_ok = bool(data.get("dataURL"))
            except Exception as e:
                print(f"pixel extraction failed: {e}", file=sys.stderr)

        with open(out_path, "w") as f:
            json.dump({"page": page_url, "pixel_extraction_ok": pixel_ok,
                       "steps": recorded}, f)
        print(f"wrote {out_path} ({len(recorded)} steps, "
              f"pixel_extraction_ok={pixel_ok})")
    finally:
        conn.close()


if __name__ == "__main__":
    # argv: <http_base> <page_url> <out_path>
    run(sys.argv[1], sys.argv[2], sys.argv[3])
