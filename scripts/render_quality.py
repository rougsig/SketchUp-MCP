"""Vectorized technical renderer: supersampling, smooth normals and shadow maps."""
import math
import struct
import zlib
import numpy as np


def basis(yaw, elevation):
    yaw, elevation = np.radians([yaw, elevation])
    return np.array([[np.cos(yaw), np.sin(yaw), 0],
                     [-np.sin(yaw)*np.sin(elevation), np.cos(yaw)*np.sin(elevation), np.cos(elevation)],
                     [np.sin(yaw)*np.cos(elevation), -np.cos(yaw)*np.cos(elevation), np.sin(elevation)]])


def smooth_normals(triangles):
    cross = np.cross(triangles[:,1]-triangles[:,0], triangles[:,2]-triangles[:,0])
    lengths = np.linalg.norm(cross, axis=1)
    face = cross / np.maximum(lengths[:,None], 1e-12)
    # Only blend adjoining faces below 35 degrees; preserve cabinet corners.
    neighbours = {}
    for i, tri in enumerate(triangles):
        for p in tri:
            neighbours.setdefault(tuple(np.round(p,6)), []).append(i)
    normals = np.empty_like(triangles)
    for i, tri in enumerate(triangles):
        for j, p in enumerate(tri):
            ids = neighbours[tuple(np.round(p,6))]
            ids = [k for k in ids if np.dot(face[k], face[i]) > math.cos(math.radians(35))]
            n = cross[ids].sum(axis=0)
            normals[i,j] = n / max(np.linalg.norm(n), 1e-12)
    return normals


def raster(triangles, axes, center, scale, width, height, normals=None):
    projected = triangles @ axes.T
    projected[:,:,0] = width/2+(projected[:,:,0]-center[0])*scale
    projected[:,:,1] = height/2-(projected[:,:,1]-center[1])*scale
    depth = np.full((height,width), -np.inf, dtype=np.float32)
    ids = np.full((height,width), -1, dtype=np.int32)
    world = np.zeros((height,width,3), dtype=np.float32) if normals is not None else None
    normal = np.zeros_like(world) if world is not None else None
    for i, tri in enumerate(projected):
        left,top = np.maximum(np.floor(tri[:,:2].min(axis=0)).astype(int),0)
        right,bottom = np.minimum(np.ceil(tri[:,:2].max(axis=0)).astype(int),[width-1,height-1])
        if left>right or top>bottom:
            continue
        a,b,c = tri
        det = (b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
        if abs(det)<1e-10:
            continue
        y,x = np.mgrid[top:bottom+1,left:right+1].astype(np.float32)
        x+=.5; y+=.5
        w1 = ((b[1]-c[1])*(x-c[0])+(c[0]-b[0])*(y-c[1]))/det
        w2 = ((c[1]-a[1])*(x-c[0])+(a[0]-c[0])*(y-c[1]))/det
        w3 = 1-w1-w2
        z = w1*a[2]+w2*b[2]+w3*c[2]
        region = np.s_[top:bottom+1,left:right+1]
        def filled(weight,p,q):
            sign = 1 if det>0 else -1
            inclusive = (q[1]-p[1])*sign>0 or (q[1]==p[1] and (q[0]-p[0])*sign<0)
            return (weight>1e-6) | ((np.abs(weight)<=1e-6) & inclusive)
        hit = filled(w1,b,c)&filled(w2,c,a)&filled(w3,a,b)&(z>depth[region])
        depth[region][hit] = z[hit]
        ids[region][hit] = i
        if world is not None:
            weights = np.stack([w1[hit],w2[hit],w3[hit]],axis=-1)
            world[region][hit] = weights @ triangles[i]
            normal[region][hit] = weights @ normals[i]
    return depth,ids,world,normal


def blur(values, radius):
    """Separable box blur with edge padding, no SciPy dependency."""
    if radius<1:
        return values
    result = values
    for axis in (0,1):
        padding = [(0,0)]*result.ndim
        padding[axis] = (radius,radius)
        padded = np.pad(result,padding,mode='edge')
        prefix = np.cumsum(padded,axis=axis,dtype=np.float32)
        shape = list(prefix.shape); shape[axis]=1
        prefix = np.concatenate([np.zeros(shape,dtype=np.float32),prefix],axis=axis)
        a = [slice(None)]*result.ndim; b = a.copy()
        a[axis]=slice(2*radius+1,None); b[axis]=slice(None,-(2*radius+1))
        result = (prefix[tuple(a)]-prefix[tuple(b)])/(2*radius+1)
    return result


def render(meshes, output, width, height, view, samples=2, style='technical'):
    triangles = np.array([m[0] for m in meshes],dtype=np.float64)
    colors = np.array([m[1] for m in meshes],dtype=np.float32)
    alpha = np.array([m[2] for m in meshes])
    opaque = alpha>=1
    if not opaque.any():
        raise ValueError('High quality rendering requires opaque geometry')
    body = triangles[opaque]
    axes = basis(*view)
    projected = triangles @ axes.T
    lo = projected[:,:,:2].min(axis=(0,1)); hi = projected[:,:,:2].max(axis=(0,1))
    center = (lo+hi)/2
    w,h = width*samples,height*samples
    scale = min(w*.78/max(hi[0]-lo[0],1e-9), h*.78/max(hi[1]-lo[1],1e-9))
    bounds_lo = body.min(axis=(0,1)); bounds_hi = body.max(axis=(0,1))
    extent = max(bounds_hi-bounds_lo)
    # Ground is display geometry only; never written back into the model.
    floor_z = bounds_lo[2]-extent*.001
    floor_center = (bounds_lo+bounds_hi)/2
    r = extent*6
    x,y = floor_center[:2]
    floor = np.array([[[x-r,y-r,floor_z],[x+r,y-r,floor_z],[x+r,y+r,floor_z]],
                      [[x-r,y-r,floor_z],[x+r,y+r,floor_z],[x-r,y+r,floor_z]]])
    normals = smooth_normals(body)
    geometry = np.concatenate([body,floor])
    normals = np.concatenate([normals,np.tile([0.,0.,1.],(2,3,1))])
    floor_color = [.97,.966,.95] if style == 'technical' else [.91,.92,.94]
    palette = np.concatenate([colors[opaque],np.tile(floor_color,(2,1))])
    depth,ids,world,normal = raster(geometry,axes,center,scale,w,h,normals)
    hit = ids>=0
    normal /= np.maximum(np.linalg.norm(normal,axis=-1,keepdims=True),1e-9)
    flip = np.sum(normal*axes[2],axis=-1)<0
    normal[flip]*=-1
    # Light-space depth map and percentage-closer filtering create actual cast shadows.
    light_axes = basis(-25,72) if style == 'technical' else basis(-35,58)
    lp = body @ light_axes.T
    light_lo = lp[:,:,:2].min(axis=(0,1)); light_hi = lp[:,:,:2].max(axis=(0,1))
    light_center = (light_lo+light_hi)/2
    shadow_size = min(2048,max(512,w,h))
    light_scale = shadow_size*.86/max(light_hi-light_lo)
    shadow,_,_,_ = raster(body,light_axes,light_center,light_scale,shadow_size,shadow_size)
    positions = world[hit] @ light_axes.T
    sx = shadow_size/2+(positions[:,0]-light_center[0])*light_scale
    sy = shadow_size/2-(positions[:,1]-light_center[1])*light_scale
    shade = np.zeros(len(positions),dtype=np.float32)
    for dy in (-2,0,2):
        for dx in (-2,0,2):
            ix = np.floor(sx+dx).astype(int); iy = np.floor(sy+dy).astype(int)
            inside = (ix>=0)&(ix<shadow_size)&(iy>=0)&(iy<shadow_size)
            blocked = np.zeros(len(positions),dtype=np.float32)
            blocked[inside] = shadow[iy[inside],ix[inside]]>positions[inside,2]+extent*.002
            shade+=blocked/9
    shadow_field = np.zeros((h,w),dtype=np.float32); shadow_field[hit]=shade
    shadow_field = blur(shadow_field,max(1,samples*(9 if style == 'technical' else 2)))
    lambert = np.maximum(0,np.sum(normal*light_axes[2],axis=-1))
    if style == 'technical':
        hemisphere = .65+.08*np.maximum(normal[:,:,2],0)
        illumination = hemisphere+.30*lambert*(1-.35*shadow_field)
        # Uniform paper ground with soft, restrained cast shadows.
        ground = ids>=len(body)
        illumination[ground] = 1-.14*shadow_field[ground]
    else:
        hemisphere = .28+.14*np.maximum(normal[:,:,2],0)
        illumination = hemisphere+.72*lambert*(1-.75*shadow_field)
    # Local depth occlusion improves legibility in seams and behind doors.
    occlusion = np.zeros((h,w),dtype=np.float32)
    finite_depth = np.where(hit,depth,-extent*100)
    for dx,dy in ((1,0),(-1,0),(0,1),(0,-1),(1,1),(-1,1),(1,-1),(-1,-1)):
        shift = samples*5
        neighbour = np.roll(finite_depth,(dy*shift,dx*shift),(0,1))
        delta = neighbour-finite_depth
        occlusion += ((delta>extent*.006)&(delta<extent*.12)).astype(np.float32)/8
    illumination *= 1-(.10 if style == 'technical' else .22)*blur(occlusion,samples*2)
    # Shade in linear light, then encode sRGB for readable color and smooth highlights.
    srgb = np.clip(palette[np.maximum(ids,0)],0,1)
    linear = np.where(srgb<=.04045,srgb/12.92,((srgb+.055)/1.055)**2.4)
    linear *= illumination[:,:,None]
    half_vector = light_axes[2]+axes[2]; half_vector/=np.linalg.norm(half_vector)
    specular = np.maximum(0,np.sum(normal*half_vector,axis=-1))**48
    linear += ((.012 if style == 'technical' else .035)*specular*(1-shadow_field))[:,:,None]
    image = np.where(linear<=.0031308,linear*12.92,1.055*np.maximum(linear,0)**(1/2.4)-.055)
    # A subtle studio gradient supplies a neutral background without changing materials.
    gradient = np.linspace(.97,.91,h,dtype=np.float32)[:,None,None]
    background = np.broadcast_to(gradient,(h,w,3))
    image = np.where(hit[:,:,None],image,background)
    if style == 'technical':
        # Draw visible silhouettes, creases and material boundaries, never triangulation.
        body_hit = (ids>=0)&(ids<len(body))
        edge = np.zeros((h,w),dtype=bool)
        for dy,dx in ((0,1),(0,-1),(1,0),(-1,0)):
            neighbour_body = np.roll(body_hit,(dy*samples,dx*samples),(0,1))
            neighbour_normal = np.roll(normal,(dy*samples,dx*samples),(0,1))
            neighbour_depth = np.roll(finite_depth,(dy*samples,dx*samples),(0,1))
            neighbour_color = np.roll(srgb,(dy*samples,dx*samples),(0,1))
            crease = np.sum(normal*neighbour_normal,axis=-1)<.78
            jump = np.abs(neighbour_depth-finite_depth)>extent*.025
            material = np.linalg.norm(neighbour_color-srgb,axis=-1)>.22
            edge |= body_hit & (~neighbour_body | crease | jump | material)
        ink = np.array([.28,.25,.10])
        image[edge] = image[edge]*.60+ink*.40
    # Transparent reference volumes use depth testing and an independent fill mask.
    for tri,color,opacity in sorted((m for m in meshes if m[2]<1),key=lambda m: np.mean(np.array(m[0])@axes[2])):
        z,tid,_,_ = raster(np.array([tri]),axes,center,scale,w,h)
        visible = (tid>=0)&(z>depth+extent*1e-7)
        opacity = min(opacity,.12) if style == 'technical' else opacity
        image[visible] = image[visible]*(1-opacity)+np.array(color)*opacity
    if style == 'technical':
        draw_zone_edges(meshes,image,depth,axes,center,scale,extent)
    image = np.clip(image,0,1)
    # Average in linear light to avoid dark outlines on antialiased edges.
    linear = np.where(image<=.04045,image/12.92,((image+.055)/1.055)**2.4)
    linear = linear.reshape(height,samples,width,samples,3).mean(axis=(1,3))
    image = np.where(linear<=.0031308,linear*12.92,1.055*linear**(1/2.4)-.055)
    pixels = np.round(np.clip(image,0,1)*255).astype(np.uint8)
    def chunk(tag,data):
        return struct.pack('!I',len(data))+tag+data+struct.pack('!I',zlib.crc32(tag+data)&0xffffffff)
    raw = b''.join(b'\0'+row.tobytes() for row in pixels)
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(png)


def draw_zone_edges(meshes,image,depth,axes,center,scale,extent):
    """Boundary lines of clearance planes, with their triangulation diagonals removed."""
    h,w = depth.shape
    edges = {}
    for triangle,color,alpha in meshes:
        if alpha>=1:
            continue
        for i in range(3):
            p,q = triangle[i],triangle[(i+1)%3]
            key = tuple(sorted((tuple(np.round(p,6)),tuple(np.round(q,6)))))
            edges.setdefault(key,[]).append(color)
    for (p,q),colors in edges.items():
        if len(colors)!=1:
            continue
        a,b = np.array([p,q]) @ axes.T
        a[:2] = [w/2+(a[0]-center[0])*scale,h/2-(a[1]-center[1])*scale]
        b[:2] = [w/2+(b[0]-center[0])*scale,h/2-(b[1]-center[1])*scale]
        count = max(2,int(np.max(np.abs(b[:2]-a[:2])))*2)
        line = np.linspace(a,b,count)
        x,y = np.floor(line[:,:2]).astype(int).T
        inside = (x>=0)&(x<w)&(y>=0)&(y<h)
        x,y,z = x[inside],y[inside],line[inside,2]
        visible = z>depth[y,x]-extent*.001
        x,y = x[visible],y[visible]
        image[y,x] = image[y,x]*.25+np.array(colors[0])*.75


def render_preview(namespace):
    """Use generator mesh records directly, including preview-only moving parts."""
    from pathlib import Path
    meshes = []
    colors = namespace['COLORS']
    for _,vertices,faces,material,_ in namespace['records']:
        alpha = .18 if material == 'red' else 1
        for face in faces:
            for i in range(1,len(face)-1):
                meshes.append(([vertices[j] for j in (face[0],face[i],face[i+1])],
                               [c/255 for c in colors[material]],alpha))
    directory = namespace['OUTPUT_DIR']
    variant = namespace.get('VARIANT')
    filename = 'preview-'+variant+'.png' if variant else 'preview-open.png' if namespace.get('OPEN_VIEW') else 'preview.png'
    width,height = namespace['W'],namespace['H']
    ratio = min(1,1200/max(width,height))
    output = directory/filename
    render(meshes,output,round(width*ratio),round(height*ratio),(30,30),style='technical')
    print(f'Rendered technical illustration: {output}')
