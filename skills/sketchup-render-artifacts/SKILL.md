---
name: sketchup-render-artifacts
description: Render and inspect technical PNG previews of generated SketchUp-MCP COLLADA artifacts or capture the native SketchUp view, preserving model geometry and clearance zones.
---

Work in the SketchUp-MCP repository. For an existing project-generated DAE, use the independent renderer:

```sh
python3 scripts/render_artifacts.py artifacts/laundry-sink/cache/laundry-sink-open.dae --output /tmp/sink-open.png --width 1200 --height 1000
python3 scripts/render_artifacts.py artifacts --width 600 --height 600
python3 scripts/render_artifacts.py artifacts/dryer/cache/dryer-yellow.dae --hide-zones --yaw 30 --elevation 30
```

Without `--output`, each result is named `<dae-stem>-render.png` in the input directory if it is already named `cache`, otherwise in its `cache/` subdirectory. Explicit `--output` is honored. Keep experimental outputs in `cache/` or `/tmp`, not beside source files. Angles are degrees. Default `--quality high --style technical` uses NumPy with supersampling, soft shadows, smooth curved surfaces and visible contours. Preserve the yellow model palette and translucent red clearance zones with boundary lines. Prefer calm, legible technical illustration over strong contrast or glossy materials. `--samples 2` is the default; `3` costs more memory. Dependencies: `python3 -m pip install -r requirements-render.txt`. `--style studio` selects stronger lighting. `--quality draft` uses the older standard-library renderer without these effects.

This is an orthographic technical renderer, not a photorealistic renderer. It supports triangle geometry, diffuse colors, COLLADA length units, X/Y/Z_UP, nested matrix/translate/rotate/scale transforms and local instance_node references. Missing/external/cyclic references and unsupported primitive types fail explicitly. Textured materials require native SketchUp rendering or a new DAE export with `export_scene`, `render_compatible:true`; this exports material colors without texture maps. To export only specific assemblies, provide root `paths: [[id]]`; UI selection is restored. Nested objects can be exported as SKP with `export_component`. Use a full COLLADA engine for unsupported features rather than silently dropping geometry.

When geometry needs rebuilding, use `scripts/generate_artifacts.py`; it now generates technical PNGs by default, using the same quality backend. `--quality draft` also provides the original annotated SVGs where supported. Sink and detergent open variants have separate DAE meshes. The tower's `open` PNG is a preview-only transformation: rendering its closed DAE cannot reproduce that open pose. Its generator passes the transformed mesh records directly to the quality backend.

Keep clearance/service zones visible for a placement review. `--hide-zones` omits transparent geometry, which in these generators denotes clearance zones; do not assume this filter is suitable for arbitrary transparent glass models. Use comparable camera angles and image dimensions when showing before/after variants.

Inspect generated PNGs with the available image viewer before reporting success. Check cropping, moving-part pose, holes, material colors and visibility of the intended zones. Call out renderer limitations that materially affect the requested result. Never replace a geometry-validation image with an AI illustration.

For a view of the actual open SketchUp model, use MCP `set_camera` followed by `get_view`; images come directly from SketchUp. Avoid changing the model solely to produce a local DAE preview. If native tools are unavailable, report that the output is a local mesh preview. For photorealistic output, first establish the requested engine and its availability; these scripts do not provide physical lighting or realistic material shaders.
