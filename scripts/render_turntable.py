#!/usr/bin/env python3
"""
Render turntable di un .glb: un giro di 360 gradi, per vedere il modello senza
aprire nulla. Usa Blender headless (import GLB e PBR nativi).

    blender --background --python render_turntable.py -- <input.glb> <out.mp4|out.gif> [--frames N]
"""
import os
import sys

import bpy

argv = sys.argv
argv = argv[argv.index("--") + 1:] if "--" in argv else argv[1:]
if len(argv) < 2:
    print("uso: ... -- input.glb output.mp4 [--frames N]", file=sys.stderr)
    sys.exit(1)

in_glb, out_path = argv[0], argv[1]
frames = 48
if "--frames" in argv:
    try:
        frames = int(argv[argv.index("--frames") + 1])
    except (ValueError, IndexError):
        pass

bpy.ops.wm.read_factory_settings(use_empty=True)

# import del modello
bpy.ops.import_scene.gltf(filepath=in_glb)
objs = [o for o in bpy.data.objects if o.type == "MESH"]
if not objs:
    print("[render] nessuna mesh nel GLB", file=sys.stderr)
    sys.exit(1)

# centra e scala la scena in una sfera unitaria attorno all'origine
import mathutils
mins = mathutils.Vector((1e9, 1e9, 1e9))
maxs = mathutils.Vector((-1e9, -1e9, -1e9))
for o in objs:
    for corner in o.bound_box:
        w = o.matrix_world @ mathutils.Vector(corner)
        mins = mathutils.Vector((min(mins[i], w[i]) for i in range(3)))
        maxs = mathutils.Vector((max(maxs[i], w[i]) for i in range(3)))
center = (mins + maxs) / 2
size = max((maxs - mins)) or 1.0

# empty al centro: ci parento tutto e lo facciamo ruotare
pivot = bpy.data.objects.new("pivot", None)
bpy.context.collection.objects.link(pivot)
pivot.location = center
for o in objs:
    o.parent = pivot

# luce + camera
world = bpy.data.worlds.new("w"); bpy.context.scene.world = world
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[1].default_value = 1.0  # ambient

sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
bpy.context.collection.objects.link(sun)
sun.data.energy = 3.0
sun.rotation_euler = (0.6, 0.2, 0.3)

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
bpy.context.collection.objects.link(cam)
bpy.context.scene.camera = cam
d = size * 2.2
cam.location = center + mathutils.Vector((0, -d, d * 0.35))
# punta al centro
look = center - cam.location
cam.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()

# animazione: pivot ruota di 360 su Z
scene = bpy.context.scene
scene.frame_start = 1
scene.frame_end = frames
pivot.rotation_euler = (0, 0, 0)
pivot.keyframe_insert("rotation_euler", frame=1)
import math
pivot.rotation_euler = (0, 0, 2 * math.pi)
pivot.keyframe_insert("rotation_euler", frame=frames)
for fc in pivot.animation_data.action.fcurves:
    for kp in fc.keyframe_points:
        kp.interpolation = "LINEAR"

# render settings: EEVEE, veloce e con PBR
scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in \
    [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] else "BLENDER_EEVEE"
scene.render.resolution_x = 640
scene.render.resolution_y = 640
scene.render.fps = 24
scene.render.film_transparent = False

if out_path.lower().endswith(".gif"):
    # blender non scrive gif: rendo PNG in /tmp e poi ffmpeg
    tmpdir = "/tmp/_tt"
    os.makedirs(tmpdir, exist_ok=True)
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = os.path.join(tmpdir, "f_")
    bpy.ops.render.render(animation=True)
    os.system(f'ffmpeg -y -framerate 24 -i "{tmpdir}/f_%04d.png" '
              f'-vf "scale=480:-1:flags=lanczos" "{out_path}" >/dev/null 2>&1')
else:
    scene.render.image_settings.file_format = "FFMPEG"
    scene.render.ffmpeg.format = "MPEG4"
    scene.render.ffmpeg.codec = "H264"
    scene.render.filepath = out_path
    bpy.ops.render.render(animation=True)

print(f"[render] OK -> {out_path}")
