# LayerTree premise probe

Answers: does Chromium re-raster only changed layers during resize? (the fact
approach A / client-side layer compositing depends on -- see
docs/superpowers/specs/2026-07-14-layer-remoting-premise-probe-design.md).

## Run
1. Ensure the `signal-gui` container is up (`docker ps`).
2. `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest`
3. `./launch-signal-cdp.sh`  # prints http://127.0.0.1:9222
4. For each page: `.venv/bin/python probe.py http://127.0.0.1:9222 \
   file:///tmp/probe-pages/<page>.html run-<page>.json`
5. `.venv/bin/python report.py run-*.json`
6. Unit tests: `.venv/bin/python -m pytest test_metrics.py -q`

## Verdict
GREEN median_stable >= 0.40 -> build approach A. RED -> pivot to approach C
(client-side smart-resize). See FINDINGS.md for the recorded result.
