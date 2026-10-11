"""Regression checks for geometry defects observed in native SketchUp."""
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / 'artifacts'
NS = {'c': 'http://www.collada.org/2005/11/COLLADASchema'}


class ArtifactGeometryTests(unittest.TestCase):
    def data(self, model):
        path = ROOT / model / 'cache/model-primitives.json'
        if not path.exists():
            self.skipTest('Generate artifact geometry first')
        return json.loads(path.read_text())

    def test_hatch_glass_and_handle_move_together_and_project_forward(self):
        for model in ('washing-machine', 'dryer'):
            data = self.data(model)
            door = [shape for shape in data['shapes'] if shape['group'] == 'Door']
            self.assertEqual(len(door), 4, model)
            self.assertEqual(sum(shape['material'] == 'glass' for shape in door), 1, model)
            ring = next(shape for shape in door if shape['type'] == 'ring')
            handles = [shape for shape in door if shape['type'] == 'box']
            self.assertTrue(all(shape['origin'][1] < ring['center'][1] for shape in handles))
            self.assertEqual(data['body_bounds_mm'], [600, 613, 850])
            self.assertEqual(data['doors'][0]['group'], 'Door')

    def test_dae_annular_meshes_have_outward_winding(self):
        for model, filename in [('washing-machine', 'washing-machine-yellow.dae'), ('dryer', 'dryer-yellow.dae')]:
            self.data(model)
            root = ET.parse(ROOT / model / 'cache' / filename).getroot()
            for mesh in root.findall('c:library_geometries/c:geometry', NS):
                if not any(word in mesh.get('name', '') for word in ('обод', 'Уплотнитель', 'Большой круглый люк')):
                    continue
                values = list(map(float, mesh.find('.//c:float_array', NS).text.split()))
                vertices = [values[i:i+3] for i in range(0, len(values), 3)]
                indices = list(map(int, mesh.find('.//c:triangles/c:p', NS).text.split()))
                volume = 0
                for i in range(0, len(indices), 3):
                    a, b, c = [vertices[j] for j in indices[i:i+3]]
                    cross = [b[1]*c[2]-b[2]*c[1], b[2]*c[0]-b[0]*c[2], b[0]*c[1]-b[1]*c[0]]
                    volume += sum(a[k]*cross[k] for k in range(3)) / 6
                self.assertGreater(volume, 0, (model, mesh.get('name')))

    def test_tower_clearance_planes_do_not_overlap_panel_surfaces(self):
        shapes = self.data('laundry-tower')['shapes']
        panels = [s for s in shapes if s['type'] == 'box']
        for plane in (s for s in shapes if s['type'] == 'rectangle'):
            points = plane['vertices']
            axis = next(k for k in range(3) if len({p[k] for p in points}) == 1)
            value = points[0][axis]
            for panel in panels:
                lo = panel['origin']
                hi = [lo[k] + panel['size'][k] for k in range(3)]
                overlap = all(min(max(p[k] for p in points), hi[k]) > max(min(p[k] for p in points), lo[k]) for k in range(3) if k != axis)
                if overlap:
                    self.assertNotIn(value, [lo[axis], hi[axis]], (plane['name'], panel['name']))
