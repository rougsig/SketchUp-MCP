#!/usr/bin/env python3
"""Render color-material COLLADA meshes to orthographic PNG.

Supports triangles, length units, X/Y/Z_UP, node transforms, local instances
and material colors. Unsupported features fail explicitly.
"""
import argparse
import math
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib

NS = {'c': 'http://www.collada.org/2005/11/COLLADASchema'}


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


IDENTITY = [[float(i == j) for j in range(4)] for i in range(4)]


def multiply(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def node_transforms(node, parent=IDENTITY, references=None, seen=()):
    local = IDENTITY
    for child in node:
        tag = child.tag.split('}')[-1]
        if tag not in ('matrix', 'translate', 'rotate', 'scale'):
            continue
        values = [float(v) for v in child.text.split()]
        if not all(math.isfinite(v) for v in values):
            raise ValueError('Non-finite node transform')
        m = [row[:] for row in IDENTITY]
        if tag == 'matrix':
            if len(values) != 16:
                raise ValueError('Invalid matrix')
            m = [[values[j*4+i] for j in range(4)] for i in range(4)]
        elif tag in ('translate', 'scale'):
            if len(values) != 3:
                raise ValueError('Invalid '+tag)
            for i in range(3):
                m[i][3 if tag == 'translate' else i] = values[i]
        else:
            if len(values) != 4:
                raise ValueError('Invalid rotation')
            length = math.sqrt(dot(values[:3],values[:3]))
            if length == 0:
                raise ValueError('Zero rotation axis')
            x,y,z = [v/length for v in values[:3]]
            c,s = math.cos(math.radians(values[3])),math.sin(math.radians(values[3]))
            t = 1-c
            m = [[t*x*x+c,t*x*y-s*z,t*x*z+s*y,0],
                 [t*x*y+s*z,t*y*y+c,t*y*z-s*x,0],
                 [t*x*z-s*y,t*y*z+s*x,t*z*z+c,0], [0,0,0,1]]
        local = multiply(local,m)
    world = multiply(parent,local)
    yield node,world
    for child in node.findall('c:node',NS):
        yield from node_transforms(child,world,references,seen)
    for instance in node.findall('c:instance_node',NS):
        url=instance.attrib['url']
        if not url.startswith('#') or references is None or url[1:] not in references:
            raise ValueError('Missing or external instance_node: '+url)
        if url in seen or len(seen)>=64:
            raise ValueError('Cyclic or excessive node instancing: '+url)
        yield from node_transforms(references[url[1:]],world,references,seen+(url,))


def load_meshes(path, zones):
    root = ET.parse(path).getroot()
    up_axis=root.findtext('c:asset/c:up_axis',default='Y_UP',namespaces=NS)
    if up_axis not in ('X_UP','Y_UP','Z_UP'):
        raise ValueError('Unsupported up_axis: '+up_axis)
    unit=root.find('c:asset/c:unit',NS)
    mm_per_unit=float(unit.attrib.get('meter','1'))*1000 if unit is not None else 1000
    if not math.isfinite(mm_per_unit) or mm_per_unit<=0:
        raise ValueError('Invalid COLLADA unit')
    effects = {}
    for effect in root.findall('c:library_effects/c:effect', NS):
        color = effect.find('.//c:diffuse/c:color', NS)
        if effect.find('.//c:diffuse/c:texture',NS) is not None:
            raise ValueError('Texture materials require native SketchUp rendering or export_scene with render_compatible:true')
        if color is None:
            color=effect.find('.//c:emission/c:color',NS)
        if color is None:
            raise ValueError('Only color materials are supported')
        rgb = [float(v) for v in color.text.split()[:3]]
        transparent = effect.find('.//c:transparent/c:color', NS)
        alpha=1.0
        if transparent is not None:
            values=[float(v) for v in transparent.text.split()]
            opaque=effect.find('.//c:transparent',NS).attrib.get('opaque','A_ONE')
            factor=float(effect.findtext('.//c:transparency/c:float',default='1',namespaces=NS))
            value=values[3] if opaque.startswith('A_') else sum(v*w for v,w in zip(values[:3],(.212671,.715160,.072169)))
            alpha=value*factor if opaque.endswith('ONE') else 1-value*factor
        if not all(math.isfinite(v) and 0<=v<=1 for v in rgb+[alpha]):
            raise ValueError('Invalid material color/opacity')
        effects[effect.attrib['id']] = (rgb, alpha)
    materials = {}
    for material in root.findall('c:library_materials/c:material', NS):
        url = material.find('c:instance_effect', NS).attrib['url'].lstrip('#')
        materials[material.attrib['id']] = effects[url]
    geometries = {g.attrib['id']: g for g in root.findall('c:library_geometries/c:geometry', NS)}
    scene_url = root.find('c:scene/c:instance_visual_scene', NS).attrib['url'].lstrip('#')
    scene = next(s for s in root.findall('c:library_visual_scenes/c:visual_scene', NS) if s.attrib['id'] == scene_url)
    result = []
    references={node.attrib['id']:node for node in root.iter('{'+NS['c']+'}node') if 'id' in node.attrib}
    for node,world in node_transforms(scene,references=references):
        for instance in node.findall('c:instance_geometry', NS):
            bindings = {b.attrib['symbol']: b.attrib['target'].lstrip('#') for b in instance.findall('.//c:instance_material', NS)}
            mesh = geometries[instance.attrib['url'].lstrip('#')].find('c:mesh', NS)
            if mesh is None or any(mesh.find('c:'+tag, NS) is not None for tag in ('polylist', 'polygons', 'trifans', 'tristrips', 'lines', 'linestrips')):
                raise ValueError('Only triangle meshes are supported')
            sources = {}
            for source in mesh.findall('c:source', NS):
                accessor = source.find('c:technique_common/c:accessor', NS)
                array = source.find('c:float_array', NS)
                if array is None or accessor is None:
                    continue
                numbers = [float(v) for v in array.text.split()]
                stride = int(accessor.attrib.get('stride', '1'))
                offset = int(accessor.attrib.get('offset', '0'))
                count = int(accessor.attrib['count'])
                sources[source.attrib['id']] = [numbers[offset+i*stride:offset+i*stride+3] for i in range(count)]
            vertices = {}
            for vertex in mesh.findall('c:vertices', NS):
                position = next(i for i in vertex.findall('c:input', NS) if i.attrib['semantic'] == 'POSITION')
                vertices[vertex.attrib['id']] = sources[position.attrib['source'].lstrip('#')]
            for triangles in mesh.findall('c:triangles', NS):
                symbol=triangles.attrib.get('material')
                rgb,alpha=materials[bindings[symbol]] if symbol else ([.8,.8,.8],1.0)
                if not zones and alpha < 1:
                    continue
                inputs = triangles.findall('c:input', NS)
                vertex = next(i for i in inputs if i.attrib['semantic'] == 'VERTEX')
                offset = int(vertex.attrib.get('offset', '0'))
                stride = max(int(i.attrib.get('offset', '0')) for i in inputs)+1
                points = vertices[vertex.attrib['source'].lstrip('#')]
                indexes = [int(v) for v in triangles.findtext('c:p', namespaces=NS).split()]
                if len(indexes) != int(triangles.attrib['count'])*3*stride:
                    raise ValueError('Invalid triangle index count')
                for start in range(0, len(indexes), 3*stride):
                    coords = [points[indexes[start+j*stride+offset]] for j in range(3)]
                    if any(len(p) != 3 or not all(math.isfinite(v) for v in p) for p in coords):
                        raise ValueError('Invalid POSITION source')
                    coords = [[dot(row,p+[1]) for row in world[:3]] for p in coords]
                    if up_axis=='Y_UP':
                        coords=[[x,-z,y] for x,y,z in coords]
                    elif up_axis=='X_UP':
                        coords=[[-z,y,x] for x,y,z in coords]
                    coords=[[v*mm_per_unit for v in p] for p in coords]
                    result.append((coords, rgb, alpha))
    if not result:
        raise ValueError('No renderable triangles')
    return result


def render(meshes, output, width, height, view):
    yaw, elevation = map(math.radians, view)
    u = (math.cos(yaw), math.sin(yaw), 0)
    v = (-math.sin(yaw)*math.sin(elevation), math.cos(yaw)*math.sin(elevation), math.cos(elevation))
    camera = (math.sin(yaw)*math.cos(elevation), -math.cos(yaw)*math.cos(elevation), math.sin(elevation))
    points = [p for triangle, _, _ in meshes for p in triangle]
    lo = [min(dot(p, axis) for p in points) for axis in (u, v)]
    hi = [max(dot(p, axis) for p in points) for axis in (u, v)]
    scale = min(width*.88/max(hi[0]-lo[0], 1e-9), height*.88/max(hi[1]-lo[1], 1e-9))
    def project(p):
        return (width/2+(dot(p,u)-(lo[0]+hi[0])/2)*scale,
                height/2-(dot(p,v)-(lo[1]+hi[1])/2)*scale, dot(p,camera))
    pixels = bytearray((246,245,240))*(width*height)
    depth = [-math.inf]*(width*height)
    opaque = [m for m in meshes if m[2] >= 1]
    transparent = sorted((m for m in meshes if m[2] < 1), key=lambda m: sum(dot(p,camera) for p in m[0])/3)
    for triangle, rgb, alpha in opaque+transparent:
        a,b,c = triangle
        ab = [b[i]-a[i] for i in range(3)]
        ac = [c[i]-a[i] for i in range(3)]
        normal = (ab[1]*ac[2]-ab[2]*ac[1], ab[2]*ac[0]-ab[0]*ac[2], ab[0]*ac[1]-ab[1]*ac[0])
        length = math.sqrt(dot(normal,normal))
        brightness = .72+.28*abs(dot(normal,(.3,-.6,.74))/length) if length else 1
        color = [round(max(0,min(255,value*255*brightness))) for value in rgb]
        A,B,C = map(project,triangle)
        determinant = (B[1]-C[1])*(A[0]-C[0])+(C[0]-B[0])*(A[1]-C[1])
        if abs(determinant) < 1e-8:
            continue
        for py in range(max(0,int(min(A[1],B[1],C[1]))), min(height-1,int(max(A[1],B[1],C[1])))+1):
            for px in range(max(0,int(min(A[0],B[0],C[0]))), min(width-1,int(max(A[0],B[0],C[0])))+1):
                x,y = px+.5,py+.5
                l1 = ((B[1]-C[1])*(x-C[0])+(C[0]-B[0])*(y-C[1]))/determinant
                l2 = ((C[1]-A[1])*(x-C[0])+(A[0]-C[0])*(y-C[1]))/determinant
                l3 = 1-l1-l2
                if min(l1,l2,l3) < 0:
                    continue
                # Top-left fill convention keeps shared transparent edges from blending twice.
                weights = (l1,l2,l3)
                edges = ((B,C),(C,A),(A,B))
                if any(abs(weight)<1e-10 and not ((q[1]-p[1])*(1 if determinant>0 else -1)>0 or (q[1]==p[1] and (q[0]-p[0])*(1 if determinant>0 else -1)<0)) for weight,(p,q) in zip(weights,edges)):
                    continue
                z = l1*A[2]+l2*B[2]+l3*C[2]
                index = py*width+px
                if z > depth[index]:
                    for channel in range(3):
                        at = index*3+channel
                        pixels[at] = round(pixels[at]*(1-alpha)+color[channel]*alpha)
                    if alpha >= 1:
                        depth[index] = z
    def chunk(tag,data):
        return struct.pack('!I',len(data))+tag+data+struct.pack('!I',zlib.crc32(tag+data)&0xffffffff)
    raw = b''.join(b'\0'+pixels[y*width*3:(y+1)*width*3] for y in range(height))
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(png)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='Color-material .dae file or directory (recursive)')
    parser.add_argument('--output', type=Path, help='PNG path for one input file')
    parser.add_argument('--width', type=int, default=1000)
    parser.add_argument('--height', type=int, default=1000)
    parser.add_argument('--yaw', type=float, default=30)
    parser.add_argument('--elevation', type=float, default=30)
    parser.add_argument('--hide-zones', action='store_true', help='Omit transparent clearance geometry')
    parser.add_argument('--quality', choices=('high', 'draft'), default='high', help='High uses NumPy, antialiasing and shadows; draft uses stdlib only')
    parser.add_argument('--samples', type=int, choices=(1,2,3), default=2, help='Supersampling per image dimension in high quality mode')
    parser.add_argument('--style', choices=('technical','studio'), default='technical', help='Technical: soft lighting, visible contours and clearance outlines')
    args = parser.parse_args()
    if not 64 <= args.width <= 2048 or not 64 <= args.height <= 2048:
        parser.error('Image dimensions must be 64..2048')
    if not all(math.isfinite(v) for v in (args.yaw,args.elevation)):
        parser.error('Camera angles must be finite')
    if args.input.is_dir() and args.output:
        parser.error('--output requires a single input file')
    paths = sorted(args.input.rglob('*.dae')) if args.input.is_dir() else [args.input]
    if not paths:
        parser.error('No .dae files found')
    for path in paths:
        directory = path.parent if path.parent.name == 'cache' else path.parent / 'cache'
        output = args.output or directory / (path.stem+'-render.png')
        meshes = load_meshes(path, not args.hide_zones)
        if args.quality == 'high':
            try:
                from render_quality import render as render_high
            except ImportError:
                parser.error('High quality needs NumPy: python3 -m pip install -r requirements-render.txt; or use --quality draft')
            render_high(meshes,output,args.width,args.height,(args.yaw,args.elevation),args.samples,args.style)
        else:
            render(meshes, output, args.width,args.height,(args.yaw,args.elevation))
        print(f'{output}: {len(meshes)} triangles, {args.width}x{args.height}')


if __name__ == '__main__':
    main()
