#!/usr/bin/env python3
"""
Estrae le mappe texture da un GLB texturizzato in PNG separati, pronti da
collegare a mano in UE5.

Hunyuan3D-2.1 produce:
  - Base Color (albedo)
  - una mappa impaccata metallic+roughness (standard glTF: canale G = roughness,
    canale B = metallic)

Output in <outdir>:
  model_albedo.png       base color
  model_roughness.png    (dal canale G della mappa MR)
  model_metallic.png     (dal canale B della mappa MR)
  model_orm.png          la mappa impaccata cosi' com'e' (se ti serve intera)

    blender --background --python extract_textures.py -- <model.glb> <outdir>
"""
import bpy
import sys
import os


def argv_after_dashes():
    a = sys.argv
    return a[a.index("--") + 1:] if "--" in a else []


def save_image(img, path):
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()


def main():
    args = argv_after_dashes()
    if len(args) < 2:
        print("uso: extract_textures.py -- <model.glb> <outdir>", file=sys.stderr)
        sys.exit(1)
    glb, outdir = args[0], args[1]
    os.makedirs(outdir, exist_ok=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)

    # trovo albedo (input Base Color) e la mappa MR (l'altra)
    albedo = None
    mr = None
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        nt = mat.node_tree
        for link in nt.links:
            if link.to_socket.name == "Base Color" and link.from_node.type == "TEX_IMAGE":
                albedo = link.from_node.image
        for n in nt.nodes:
            if n.type == "TEX_IMAGE" and n.image and n.image is not albedo:
                mr = n.image

    if albedo is None:
        print("[tex] nessuna base color trovata", file=sys.stderr)
    else:
        p = os.path.join(outdir, "model_albedo.png")
        save_image(albedo, p)
        print(f"[tex] albedo    -> {os.path.basename(p)}  {tuple(albedo.size)}")

        # --- variante PS2 (opzionale): texture piccola + palette ridotta ------
        # PS2_TEXTURE=1 -> crea model_albedo_ps2.png ridimensionata a
        # PS2_TEXTURE_SIZE (default 256) con filtro nearest, e (se PS2_POSTERIZE>0)
        # riduce i livelli di colore per il look retro. Non tocca model_albedo.png.
        if os.environ.get("PS2_TEXTURE", "0") == "1":
            try:
                from PIL import Image, ImageOps
                size = int(os.environ.get("PS2_TEXTURE_SIZE", "256") or 256)
                post = int(os.environ.get("PS2_POSTERIZE", "0") or 0)
                im = Image.open(p).convert("RGB")
                im = im.resize((size, size), Image.NEAREST)
                if post > 0:
                    bits = max(1, min(8, post))
                    im = ImageOps.posterize(im, bits)
                pp = os.path.join(outdir, "model_albedo_ps2.png")
                im.save(pp)
                extra = f" + posterize {post}bit" if post > 0 else ""
                print(f"[tex] PS2       -> {os.path.basename(pp)}  {size}x{size} nearest{extra}")
            except Exception as e:
                print(f"[tex] variante PS2 fallita ({e})", file=sys.stderr)

    if mr is not None:
        # salvo la mappa impaccata intera
        p_orm = os.path.join(outdir, "model_orm.png")
        save_image(mr, p_orm)
        print(f"[tex] orm(packed)-> {os.path.basename(p_orm)}  {tuple(mr.size)}")
        # splitto i canali: G=roughness, B=metallic (standard glTF)
        try:
            w, h = mr.size
            px = list(mr.pixels)  # RGBA float, riga per riga
            rough = bpy.data.images.new("rough", w, h, alpha=False)
            metal = bpy.data.images.new("metal", w, h, alpha=False)
            rpx = [0.0] * (w * h * 4)
            mpx = [0.0] * (w * h * 4)
            for i in range(w * h):
                g = px[i * 4 + 1]
                b = px[i * 4 + 2]
                rpx[i * 4:i * 4 + 4] = [g, g, g, 1.0]
                mpx[i * 4:i * 4 + 4] = [b, b, b, 1.0]
            rough.pixels = rpx
            metal.pixels = mpx
            pr = os.path.join(outdir, "model_roughness.png")
            pm = os.path.join(outdir, "model_metallic.png")
            save_image(rough, pr)
            save_image(metal, pm)
            print(f"[tex] roughness -> {os.path.basename(pr)}  (canale G)")
            print(f"[tex] metallic  -> {os.path.basename(pm)}  (canale B)")
        except Exception as e:
            print(f"[tex] split metallic/roughness fallito ({e}); resta model_orm.png", file=sys.stderr)
    else:
        print("[tex] nessuna mappa metallic/roughness trovata", file=sys.stderr)


if __name__ == "__main__":
    main()
