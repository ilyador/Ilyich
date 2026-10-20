"""Triangulates Natural Earth land and lake polygons into small cells that follow the sphere,
and adds its major highways as polylines.

Output (raw DEFLATE): magic 'ILYE', u32 version 2, then per layer (land, lakes):
u32 vertexCount, u32 indexCount, vertexCount * (f32 lon, f32 lat) radians, indexCount * u32;
then roads: u32 lineCount, u32 pointCount, lineCount * u32 first point, pointCount * (f32 lon, f32 lat).
"""
import json, math, struct, sys, zlib
import numpy as np
import shapely
from shapely.geometry import shape, box, Polygon, MultiPolygon
from shapely.strtree import STRtree

def polygons(path, min_area=0.0, tolerance=0.0):
    data = json.load(open(path))
    result = []
    for feature in data['features']:
        geometry = shape(feature['geometry'])
        if tolerance > 0: geometry = geometry.simplify(tolerance, preserve_topology=True)
        parts = geometry.geoms if isinstance(geometry, MultiPolygon) else [geometry]
        for p in parts:
            if not p.is_valid: p = p.buffer(0)
            if p.is_empty: continue
            for q in (p.geoms if isinstance(p, MultiPolygon) else [p]):
                if q.area >= min_area: result.append(q)
    return result

def triangulate(polys, cell):
    vertices, index_of, indices = [], {}, []
    def vid(x, y):
        key = (round(x * 1e7), round(y * 1e7))
        i = index_of.get(key)
        if i is None:
            i = len(vertices); index_of[key] = i; vertices.append((math.radians(x), math.radians(y)))
        return i
    tree = STRtree(polys)
    full = 0
    for lat0 in np.arange(-90, 90, cell):
        for lon0 in np.arange(-180, 180, cell):
            c = box(lon0, lat0, lon0 + cell, lat0 + cell)
            hits = tree.query(c, predicate='intersects')
            if len(hits) == 0: continue
            area = c.area
            for h in hits:
                piece = polys[h].intersection(c)
                if piece.is_empty: continue
                if abs(piece.area - area) < 1e-9 * area and len(hits) == 1:
                    a, b, d, e = vid(lon0, lat0), vid(lon0 + cell, lat0), vid(lon0 + cell, lat0 + cell), vid(lon0, lat0 + cell)
                    indices += [a, b, d, a, d, e]; full += 1; continue
                tris = shapely.constrained_delaunay_triangles(piece)
                for t in getattr(tris, 'geoms', [tris]):
                    if t.is_empty or t.area <= 0: continue
                    (x0, y0), (x1, y1), (x2, y2) = list(t.exterior.coords)[:3]
                    # Counter-clockwise seen from outside the sphere (lon east, lat north).
                    if (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0) < 0: (x1, y1), (x2, y2) = (x2, y2), (x1, y1)
                    indices += [vid(x0, y0), vid(x1, y1), vid(x2, y2)]
    return vertices, indices, full

def roads(path, tolerance):
    from shapely.geometry import LineString, MultiLineString
    data = json.load(open(path))
    lines = []
    for feature in data['features']:
        kind = feature['properties'].get('type')
        if kind not in ('Major Highway', 'Beltway'):
            continue
        geometry = shape(feature['geometry'])
        if tolerance > 0:
            geometry = geometry.simplify(tolerance, preserve_topology=False)
        for line in (geometry.geoms if isinstance(geometry, MultiLineString) else [geometry]):
            coords = list(line.coords)
            if len(coords) >= 2:
                lines.append([(math.radians(x), math.radians(y)) for x, y in coords])
    return lines

def road_layer(lines):
    starts, points = [], []
    for line in lines:
        starts.append(len(points)); points += line
    return struct.pack('<II', len(lines), len(points)) + np.asarray(starts, dtype='<u4').tobytes() + np.asarray(points, dtype='<f4').tobytes()

def layer(vertices, indices):
    out = struct.pack('<II', len(vertices), len(indices))
    out += np.asarray(vertices, dtype='<f4').tobytes()
    out += np.asarray(indices, dtype='<u4').tobytes()
    return out

land_path, lakes_path, roads_path, cell, output = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
tolerance = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
lake_area = float(sys.argv[7]) if len(sys.argv) > 7 else 0.02
land = polygons(land_path, min_area=float(sys.argv[8]) if len(sys.argv) > 8 else 0.0005, tolerance=tolerance)
highways = roads(roads_path, float(sys.argv[9]) if len(sys.argv) > 9 else 0.01)
lakes = polygons(lakes_path, min_area=lake_area, tolerance=tolerance)
lv, li, lf = triangulate(land, cell)
kv, ki, kf = triangulate(lakes, cell)
raw = b'ILYE' + struct.pack('<I', 2) + layer(lv, li) + layer(kv, ki) + road_layer(highways)
packer = zlib.compressobj(9, zlib.DEFLATED, -15)
data = packer.compress(raw) + packer.flush()
open(output, 'wb').write(data)
print(f'roads {len(highways)} lines, {sum(len(l) for l in highways)} points; '
      f'land {len(land)} polygons -> {len(lv)} vertices, {len(li)//3} triangles ({lf} full cells); '
      f'lakes {len(lakes)} -> {len(kv)} vertices, {len(ki)//3} triangles; raw {len(raw)/1e6:.2f} MB, deflated {len(data)/1e6:.2f} MB')
