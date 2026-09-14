#!/usr/bin/env python3
"""
Immagine -> mesh 3D con texture PBR, usando Hunyuan3D-2.1.
Gira DENTRO il container (WORKDIR /opt/hunyuan). Non lanciarlo a mano: usa generate.sh

    python3 /opt/scripts/gen_3d.py <immagine> <output.glb>

Variabili d'ambiente (impostate da entrypoint.sh dalla config):
    SHAPE_STEPS, SHAPE_GUIDANCE, TEXTURE_STEPS, TEXTURE_RESOLUTION,
    OCTREE_RESOLUTION, REMOVE_BACKGROUND
"""
import os
import sys

# i due sottomoduli del repo vanno nel path (come da README ufficiale)
sys.path.insert(0, "/opt/hunyuan/hy3dshape")
sys.path.insert(0, "/opt/hunyuan/hy3dpaint")


def env_int(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return default


def main():
    if len(sys.argv) < 3:
        print("uso: gen_3d.py <immagine> <output.glb>", file=sys.stderr)
        sys.exit(1)
    image_path, out_glb = sys.argv[1], sys.argv[2]
    if not os.path.isfile(image_path):
        print(f"[gen] immagine non trovata: {image_path}", file=sys.stderr)
        sys.exit(1)

    shape_steps = env_int("SHAPE_STEPS", 50)
    shape_guidance = env_float("SHAPE_GUIDANCE", 5.5)
    texture_steps = env_int("TEXTURE_STEPS", 30)
    texture_res = env_int("TEXTURE_RESOLUTION", 2048)
    octree_res = env_int("OCTREE_RESOLUTION", 384)
    remove_bg = os.environ.get("REMOVE_BACKGROUND", "1") == "1"

    from PIL import Image

    # --- 0. sfondo -----------------------------------------------------------
    work_img = image_path
    if remove_bg:
        try:
            from rembg import remove
            img = Image.open(image_path).convert("RGBA")
            cut = remove(img)
            work_img = "/tmp/_input_nobg.png"
            cut.save(work_img)
            print("[gen] sfondo rimosso")
        except Exception as e:
            print(f"[gen] rimozione sfondo fallita ({e}), uso l'immagine originale", file=sys.stderr)
            work_img = image_path

    # --- 1. geometria --------------------------------------------------------
    print(f"[gen] shape: {shape_steps} step, guidance {shape_guidance}, octree {octree_res}")
    from hy3dshape.pipelines import Hunyuan3DDiTFlowMatchingPipeline

    shape_pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2.1")
    mesh = shape_pipe(
        image=work_img,
        num_inference_steps=shape_steps,
        guidance_scale=shape_guidance,
        octree_resolution=octree_res,
    )[0]

    raw_mesh = "/tmp/_mesh_untextured.glb"
    mesh.export(raw_mesh)
    print(f"[gen] mesh grezza: {raw_mesh}")

    # --- 2. texture PBR ------------------------------------------------------
    print(f"[gen] paint: {texture_steps} step, texture {texture_res}px")
    try:
        from textureGenPipeline import Hunyuan3DPaintPipeline, Hunyuan3DPaintConfig

        cfg = Hunyuan3DPaintConfig(max_num_view=6, resolution=512)
        # alcuni parametri esistono a seconda della revision del repo: li setto
        # in modo difensivo senza far esplodere se un attributo non c'e'.
        for attr, val in (("num_inference_steps", texture_steps),
                          ("texture_resolution", texture_res)):
            if hasattr(cfg, attr):
                setattr(cfg, attr, val)

        paint_pipe = Hunyuan3DPaintPipeline(cfg)
        textured = paint_pipe(raw_mesh, image_path=work_img)

        # ATTENZIONE: paint_pipe restituisce il path dell'.OBJ, ma crea ANCHE il
        # .glb gemello (textured_mesh.glb) con la texture INCORPORATA. Se prendo
        # l'.obj e lo rinomino in .glb ottengo un finto-GLB (in realta' testo OBJ,
        # texture in un .mtl separato che va perso) -> tutto a valle si rompe.
        # Prendo il .glb gemello vero.
        if isinstance(textured, str):
            import shutil
            src = textured
            if src.lower().endswith(".obj"):
                glb_sib = src[:-4] + ".glb"
                if os.path.isfile(glb_sib):
                    src = glb_sib
                    print(f"[gen] uso il GLB texturizzato: {src}")
                else:
                    print(f"[gen] ATTENZIONE: manca il .glb gemello di {src}", file=sys.stderr)
            if os.path.abspath(src) != os.path.abspath(out_glb):
                shutil.move(src, out_glb)
        else:
            textured.export(out_glb)
        print(f"[gen] OK texturizzato -> {out_glb}")
    except Exception as e:
        # fallback: consegna comunque la mesh senza texture, meglio di niente
        import shutil
        import traceback
        shutil.move(raw_mesh, out_glb)
        print(f"[gen] TEXTURE FALLITA ({e})", file=sys.stderr)
        print("[gen] --- traceback completo (per capire quale passo salta) ---", file=sys.stderr)
        traceback.print_exc()
        print("[gen] --------------------------------------------------------", file=sys.stderr)
        print(f"[gen] consegno la mesh SENZA texture -> {out_glb}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
