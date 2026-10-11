import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
import sys

spec = importlib.util.spec_from_file_location('artifact_render', Path(__file__).resolve().parents[1]/'scripts/render_artifacts.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class ArtifactRenderTest(unittest.TestCase):
    def test_nested_collada_matrix_order(self):
        import xml.etree.ElementTree as ET
        node = ET.fromstring('''<node xmlns="http://www.collada.org/2005/11/COLLADASchema">
          <translate>10 20 30</translate><node><matrix>0 1 0 0 -1 0 0 0 0 0 1 0 0 0 0 1</matrix></node>
        </node>''')
        child, world = list(renderer.node_transforms(node))[-1]
        point = [renderer.dot(row,[2,0,0,1]) for row in world[:3]]
        self.assertEqual(point,[10,22,30])

    def test_png_contains_rendered_geometry_and_valid_chunks(self):
        meshes = [([(0,0,0),(100,0,0),(0,0,100)], [1,0,0], 1)]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'image.png'
            renderer.render(meshes,output,64,64,(30,30))
            data = output.read_bytes()
        self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
        offset = 8
        compressed = b''
        while offset < len(data):
            length = struct.unpack('!I',data[offset:offset+4])[0]
            tag = data[offset+4:offset+8]
            payload = data[offset+8:offset+8+length]
            crc = struct.unpack('!I',data[offset+8+length:offset+12+length])[0]
            self.assertEqual(crc,zlib.crc32(tag+payload)&0xffffffff)
            if tag == b'IDAT':
                compressed += payload
            offset += 12+length
        raw = zlib.decompress(compressed)
        self.assertEqual(len(raw),64*(1+64*3))
        background = b'\0'+bytes((246,245,240))*64
        self.assertNotEqual(raw,background*64)

    def test_open_sink_uses_distinct_mesh_coordinates(self):
        # Optional integration check when project artifacts have been generated.
        directory = Path(__file__).resolve().parents[1]/'artifacts/laundry-sink/cache'
        if not (directory/'laundry-sink-open.dae').exists():
            self.skipTest('Run scripts/generate_artifacts.py --geometry-only first')
        closed = renderer.load_meshes(directory/'laundry-sink-closed.dae',False)
        opened = renderer.load_meshes(directory/'laundry-sink-open.dae',False)
        self.assertEqual(len(closed),len(opened))
        self.assertNotEqual(closed,opened)

    def test_high_quality_shared_edges_are_filled_once(self):
        try:
            import numpy as np
        except ImportError:
            self.skipTest('NumPy is optional for draft rendering')
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
        import render_quality
        triangles = np.array([[[-8,-8,0],[8,-8,0],[8,8,0]],
                              [[-8,-8,0],[8,8,0],[-8,8,0]]],dtype=float)
        masks = [render_quality.raster(triangles[i:i+1],np.eye(3),[0,0],1,32,32)[1]>=0 for i in (0,1)]
        self.assertEqual(int((masks[0]&masks[1]).sum()),0)
        self.assertEqual(int((masks[0]|masks[1]).sum()),16*16)

    def test_high_quality_png_has_requested_dimensions(self):
        try:
            import numpy
        except ImportError:
            self.skipTest('NumPy is optional for draft rendering')
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
        import render_quality
        meshes = [([(0,0,0),(100,0,0),(0,0,100)],[1,.9,0],1)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'technical.png'
            render_quality.render(meshes,path,80,64,(30,30),samples=2)
            png = path.read_bytes()
        self.assertEqual(struct.unpack('!II',png[16:24]),(80,64))

    def test_collada_instancing_units_axes_and_transparency(self):
        dae='''<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema">
        <asset><unit meter="0.01"/><up_axis>Y_UP</up_axis></asset>
        <library_effects><effect id="fx"><profile_COMMON><technique sid="common"><phong>
          <diffuse><color>1 0.9 0 1</color></diffuse><transparent opaque="A_ZERO"><color>1 1 1 0.2</color></transparent>
          <transparency><float>0.5</float></transparency></phong></technique></profile_COMMON></effect></library_effects>
        <library_materials><material id="paint"><instance_effect url="#fx"/></material></library_materials>
        <library_geometries><geometry id="mesh"><mesh><source id="position"><float_array id="array">0 0 0 1 0 0 0 1 0</float_array>
          <technique_common><accessor source="#array" count="3" stride="3"/></technique_common></source>
          <vertices id="verts"><input semantic="POSITION" source="#position"/></vertices>
          <triangles count="1" material="color"><input semantic="VERTEX" source="#verts" offset="0"/><p>0 1 2</p></triangles>
        </mesh></geometry></library_geometries>
        <library_nodes><node id="part"><instance_geometry url="#mesh"><bind_material><technique_common>
          <instance_material symbol="color" target="#paint"/></technique_common></bind_material></instance_geometry></node></library_nodes>
        <library_visual_scenes><visual_scene id="scene"><node><translate>2 3 4</translate><instance_node url="#part"/></node>
          <node><translate>5 6 7</translate><instance_node url="#part"/></node></visual_scene></library_visual_scenes>
        <scene><instance_visual_scene url="#scene"/></scene></COLLADA>'''
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'sketchup.dae'
            path.write_text(dae)
            meshes=renderer.load_meshes(path,True)
            self.assertEqual(len(meshes),2)
            self.assertEqual(meshes[0][0],[[20,-40,30],[30,-40,30],[20,-40,40]])
            self.assertEqual(meshes[1][0][0],[50,-70,60])
            self.assertAlmostEqual(meshes[0][2],0.9)
            path.write_text(dae.replace('<instance_node url="#part"/>','<instance_node url="#part"/><instance_node url="#part"/>',1))
            self.assertEqual(len(renderer.load_meshes(path,True)),3)
            path.write_text(dae.replace('<node id="part">','<node id="part"><instance_node url="#part"/>'))
            with self.assertRaisesRegex(ValueError,'Cyclic'):
                renderer.load_meshes(path,True)
            path.write_text(dae.replace('<diffuse><color>1 0.9 0 1</color></diffuse>','<diffuse><texture texture="sampler" texcoord="UV"/></diffuse>'))
            with self.assertRaisesRegex(ValueError,'render_compatible'):
                renderer.load_meshes(path,True)


if __name__ == '__main__':
    unittest.main()
