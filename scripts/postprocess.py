#!/usr/bin/env python3
"""
Post-processing del modello, in Blender headless. Non tocca MAI il model.glb
originale: aggiunge file accanto, cosi' la versione texturizzata buona resta
sempre. Ogni stadio si accende/spegne da config.env.

    blender --background --python postprocess.py -- <model.glb> <out_dir>

Stadi (letti da variabili d'ambiente):
  POST_DECIMATE_FACES   >0  -> model_light.glb : mesh alleggerita per il realtime.
                              Conserva UV e texture originali. SICURO.
  POST_QUAD_REMESH      1   -> model_retopo.glb : topologia a QUAD pulita
                              (quadriflow) + UV nuove + ribake del base color.
                              E' il pezzo che fanno i siti a pagamento. Piu'
                              fragile: se il ribake fallisce esce comunque la
                              geometria pulita, ma con meno texture.
  POST_QUAD_FACES       target di facce per il quad remesh (default 20000)
  EXPORT_FORMATS        lista: glb,fbx,obj,usdc -> esporta il modello texturizzato
                              anche in questi formati (per la tua pipeline)
"""
import os
import sys

import bpy

argv = sys.argv
argv = argv[argv.index("--") + 1:] if "--" in argv else argv[1:]
if len(argv) < 2:
    print("uso: ... -- model.glb out_dir", file=sys.stderr)
    sys.exit(1)
in_glb, out_dir = argv[0], argv[1]

DECIMATE_FACES = int(os.environ.get("POST_DECIMATE_FACES", "0") or 0)
QUAD_REMESH = os.environ.get("POST_QUAD_REMESH", "0") == "1"
QUAD_FACES = int(os.environ.get("POST_QUAD_FACES", "20000") or 20000)
EXPORT_FORMATS = [f.strip().lower() for f in
                  os.environ.get("EXPORT_FORMATS", "glb").split(",") if f.strip()]


def fresh_import():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=in_glb)
    return [o for o in bpy.data.objects if o.type == "MESH"]


def join_meshes(objs):
    if len(objs) == 1:
        return objs[0]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def export(obj, path, fmt):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    if fmt == "glb":
        bpy.ops.export_scene.gltf(filepath=path, use_selection=True, export_format="GLB")
    elif fmt == "fbx":
        bpy.ops.export_scene.fbx(filepath=path, use_selection=True, path_mode="COPY", embed_textures=True)
    elif fmt == "obj":
        bpy.ops.wm.obj_export(filepath=path, export_selected_objects=True)
    elif fmt in ("usdc", "usd", "usdz"):
        bpy.ops.wm.usd_export(filepath=path, selected_objects_only=True)
    else:
        return False
    return True


def faces(obj):
    return len(obj.data.polygons)


# --------------------------------------------------------------- 1. decimate
if DECIMATE_FACES > 0:
    objs = fresh_import()
    if objs:
        obj = join_meshes(objs)
        before = faces(obj)
        if before > DECIMATE_FACES:
            m = obj.modifiers.new("dec", "DECIMATE")
            m.decimate_type = "COLLAPSE"
            m.ratio = max(0.01, min(1.0, DECIMATE_FACES / before))
            bpy.context.view_layer.objects.active = obj
            bpy.ops.object.modifier_apply(modifier=m.name)
        out = os.path.join(out_dir, "model_light.glb")
        export(obj, out, "glb")
        print(f"[post] model_light.glb : {before} -> {faces(obj)} facce (texture conservata)")

# ------------------------------------------------------------ 2. quad remesh
if QUAD_REMESH:
    objs = fresh_import()
    if objs:
        obj = join_meshes(objs)
        before = faces(obj)

        # tieni una copia texturizzata come sorgente per il ribake
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.duplicate()
        source = bpy.context.view_layer.objects.active
        source.name = "source_textured"

        # quad remesh sulla mesh principale
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        ok = False
        for attempt in ("target", "auto"):
            try:
                if attempt == "target":
                    bpy.ops.object.quadriflow_remesh(target_faces=max(200, QUAD_FACES))
                else:
                    # quadriflow a volte fallisce con un target: riprova in automatico
                    bpy.ops.object.quadriflow_remesh(mode="RATIO", ratio=0.5)
                ok = True
                print(f"[post] quad remesh ({attempt}): {before} tri -> {faces(obj)} quad")
                break
            except Exception as e:
                print(f"[post] quad remesh tentativo '{attempt}' fallito: {e}", file=sys.stderr)
        if not ok:
            print("[post] quad remesh non riuscito su questa mesh, salto il retopo", file=sys.stderr)
            obj = None

        if obj is not None:
            # UV nuove sulla mesh a quad
            bpy.ops.object.select_all(action="DESELECT")
            obj.select_set(True); bpy.context.view_layer.objects.active = obj
            bpy.ops.object.mode_set(mode="EDIT")
            bpy.ops.mesh.select_all(action="SELECT")
            try:
                bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.002)
            except Exception:
                bpy.ops.uv.smart_project()
            bpy.ops.object.mode_set(mode="OBJECT")

            # ribake del base color dalla sorgente texturizzata alla nuova UV
            baked = False
            try:
                scene = bpy.context.scene
                scene.render.engine = "CYCLES"
                try:
                    scene.cycles.device = "GPU"
                except Exception:
                    pass
                res = int(os.environ.get("TEXTURE_RESOLUTION", "2048") or 2048)
                img = bpy.data.images.new("baked", res, res)
                mat = bpy.data.materials.new("baked_mat"); mat.use_nodes = True
                node = mat.node_tree.nodes.new("ShaderNodeTexImage")
                node.image = img
                mat.node_tree.nodes.active = node
                obj.data.materials.clear(); obj.data.materials.append(mat)

                # selected-to-active: source (selezionata) -> obj (attiva)
                bpy.ops.object.select_all(action="DESELECT")
                source.select_set(True); obj.select_set(True)
                bpy.context.view_layer.objects.active = obj
                scene.render.bake.use_selected_to_active = True
                scene.render.bake.cage_extrusion = 0.05
                bpy.ops.object.bake(type="DIFFUSE",
                                    pass_filter={"COLOR"},
                                    use_clear=True)
                out_png = os.path.join(out_dir, "model_retopo_basecolor.png")
                img.filepath_raw = out_png
                img.file_format = "PNG"
                img.save()
                baked = True
                print(f"[post] ribake base color: {out_png}")
            except Exception as e:
                print(f"[post] ribake texture FALLITO ({e}): esco con la sola geometria pulita", file=sys.stderr)

            # via la sorgente, esporta solo la mesh retopo
            try:
                bpy.data.objects.remove(source, do_unlink=True)
            except Exception:
                pass
            out = os.path.join(out_dir, "model_retopo.glb")
            export(obj, out, "glb")
            note = "con base color ribakeato" if baked else "SOLO geometria (texture non ribakeata)"
            print(f"[post] model_retopo.glb : topologia a quad, {note}")

# --------------------------------------------------- 3. export multi-formato
extra = [f for f in EXPORT_FORMATS if f != "glb"]
if extra:
    objs = fresh_import()
    if objs:
        obj = join_meshes(objs)
        for fmt in extra:
            ext = "usdc" if fmt in ("usd", "usdc") else fmt
            out = os.path.join(out_dir, f"model.{ext}")
            try:
                if export(obj, out, fmt):
                    print(f"[post] esportato model.{ext}")
            except Exception as e:
                print(f"[post] export {fmt} fallito ({e})", file=sys.stderr)

print("[post] fatto.")
