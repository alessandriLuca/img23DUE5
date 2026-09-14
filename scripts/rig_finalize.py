#!/usr/bin/env python3
"""
Rifinitura del rig di UniRig per Unreal Engine 5.

UniRig produce uno scheletro umanoide corretto ma con nomi generici
(bone_0, bone_1, ...) e senza osso 'root': l'Auto Generate Retargeter di UE
non riesce ad agganciarlo. Questo script:

  1. riconosce la struttura umanoide dalla TOPOLOGIA (non da indici fissi):
     bacino, colonna, collo/testa, 2 braccia con mani, 2 gambe;
  2. rinomina le ossa coi nomi dello UE Mannequin (pelvis, spine_01, upperarm_l,
     thigh_r, ...);
  3. aggiunge un osso 'root' all'origine, a terra, e ci appende il pelvis;
  4. porta i piedi a Z=0 (in piedi sull'origine);
  5. esporta un FBX pronto per UE.

    blender --background --python rig_finalize.py -- <input_rigged.fbx> <output_ue.fbx> [--flip-lr]

--flip-lr scambia sinistra/destra se le animazioni retargetate escono specchiate.
"""
import bpy
import sys
import math
import os


def argv_after_dashes():
    a = sys.argv
    return a[a.index("--") + 1:] if "--" in a else []


def real_children(bone):
    """Figli 'veri' (esclude le punte _end che UniRig aggiunge come foglie)."""
    return [c for c in bone.children if not c.name.endswith("_end")]


def subtree_size(bone):
    n = 1
    for c in bone.children:
        n += subtree_size(c)
    return n


def chain_from(bone):
    """Segue una catena a figlio-singolo finche' non ramifica o finisce."""
    chain = [bone]
    cur = bone
    while True:
        ch = real_children(cur)
        if len(ch) != 1:
            break
        cur = ch[0]
        chain.append(cur)
    return chain


def map_humanoid(arm):
    """Ritorna dict {nome_bone_originale: nome_UE} o None se non riconosciuto."""
    bones = arm.data.bones
    roots = [b for b in bones if b.parent is None]
    if not roots:
        return None
    pelvis = max(roots, key=subtree_size)

    pc = real_children(pelvis)
    if len(pc) < 3:
        return None  # ci aspettiamo colonna + 2 gambe

    # gambe = figli che vanno in GIU' (Z minore del pelvis); colonna = va in su
    pz = pelvis.head_local.z
    legs = sorted([b for b in pc if b.head_local.z < pz], key=lambda b: b.head_local.x)
    ups = [b for b in pc if b.head_local.z >= pz]
    if len(legs) < 2 or not ups:
        return None
    spine_start = max(ups, key=subtree_size)

    mapping = {}

    # --- colonna: dal primo osso su fino al 'petto' (bone con >=3 figli) ---
    spine_chain = []
    cur = spine_start
    guard = 0
    while cur is not None and guard < 100:
        guard += 1
        spine_chain.append(cur)
        ch = real_children(cur)
        if len(ch) >= 3:
            break  # questo e' il petto (collo + 2 braccia)
        cur = ch[0] if len(ch) == 1 else (ch[0] if ch else None)
    chest = spine_chain[-1]

    # nomi colonna: spine_01, spine_02, ... l'ultimo (petto) e' l'ultimo spine
    for i, b in enumerate(spine_chain, start=1):
        mapping[b.name] = f"spine_{i:02d}"

    # --- dal petto: collo/testa + 2 braccia ---
    chest_children = real_children(chest)
    # braccia = i due piu' lateralni (|x| grande); collo = quello centrale che va su
    arms = sorted(chest_children, key=lambda b: -abs(b.head_local.x))[:2]
    neck_cand = [b for b in chest_children if b not in arms]
    if neck_cand:
        neck_start = max(neck_cand, key=lambda b: b.head_local.z)
        neck_chain = chain_from(neck_start)
        # neck_01 (+ eventuale neck_02) e poi head all'ultimo
        if len(neck_chain) == 1:
            mapping[neck_chain[0].name] = "neck_01"
        else:
            mapping[neck_chain[0].name] = "neck_01"
            for b in neck_chain[1:-1]:
                mapping[b.name] = "neck_02"
            mapping[neck_chain[-1].name] = "head"

    # --- braccia: clavicle -> upperarm -> lowerarm -> hand -> (dita) ---
    def side_suffix(x, flip):
        left = x >= 0
        if flip:
            left = not left
        return "l" if left else "r"

    flip = "--flip-lr" in argv_after_dashes()
    for arm_root in arms:
        s = side_suffix(arm_root.head_local.x, flip)
        # catena fino alla mano (dove ramificano le dita, >=3 figli) o 4 ossa
        chain = [arm_root]
        cur = arm_root
        guard = 0
        while guard < 100:
            guard += 1
            ch = real_children(cur)
            if len(ch) >= 3:      # la mano: da qui partono le dita
                break
            if len(ch) == 0:
                break
            cur = ch[0]
            chain.append(cur)
        # chain: [clavicle, upperarm, lowerarm, hand]  (se piu' corta, adatto)
        names = ["clavicle", "upperarm", "lowerarm", "hand"]
        if len(chain) >= 4:
            mapping[chain[0].name] = f"clavicle_{s}"
            mapping[chain[1].name] = f"upperarm_{s}"
            mapping[chain[2].name] = f"lowerarm_{s}"
            mapping[chain[3].name] = f"hand_{s}"
            hand = chain[3]
        else:
            # senza clavicola: upperarm/lowerarm/hand
            for b, nm in zip(chain, ["upperarm", "lowerarm", "hand"]):
                mapping[b.name] = f"{nm}_{s}"
            hand = chain[-1]
        # dita (best-effort): le catene figlie della mano
        fingers = real_children(hand)
        fnames = ["thumb", "index", "middle", "ring", "pinky"]
        # ordino le dita per posizione cosi' e' stabile
        fingers = sorted(fingers, key=lambda b: (b.head_local.z, b.head_local.y))
        for fi, fbone in enumerate(fingers[:5]):
            fchain = chain_from(fbone)
            for seg, fb in enumerate(fchain[:3], start=1):
                mapping[fb.name] = f"{fnames[fi]}_{seg:02d}_{s}"

    # --- gambe: thigh -> calf -> foot -> ball ---
    for leg_root in legs:
        s = side_suffix(leg_root.head_local.x, flip)
        chain = chain_from(leg_root)
        names = ["thigh", "calf", "foot", "ball"]
        for b, nm in zip(chain, names):
            mapping[b.name] = f"{nm}_{s}"

    mapping[pelvis.name] = "pelvis"
    return mapping


def main():
    args = argv_after_dashes()
    if len(args) < 2:
        print("uso: rig_finalize.py -- <input.fbx> <output.fbx> [--flip-lr]", file=sys.stderr)
        sys.exit(1)
    in_fbx, out_fbx = args[0], args[1]

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=in_fbx)

    arms = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not arms:
        print("[finalize] nessuna armature nell'FBX", file=sys.stderr)
        sys.exit(2)
    arm = arms[0]

    # nomino mesh e armature col nome del file di output (es. "yo") cosi' in UE
    # lo Skeletal Mesh e lo Skeleton prendono quel nome (yo, yo_Skeleton).
    base = os.path.splitext(os.path.basename(out_fbx))[0]
    for o in bpy.data.objects:
        if o.type == "MESH":
            o.name = base
            if o.data:
                o.data.name = base
    arm.name = base + "_rig"
    if arm.data:
        arm.data.name = base + "_rig"
    print(f"[finalize] rinominato come '{base}'")

    mapping = map_humanoid(arm)
    if not mapping:
        print("[finalize] ATTENZIONE: struttura non riconosciuta come umanoide; "
              "aggiungo solo il root, lascio i nomi originali", file=sys.stderr)
        mapping = {}

    # --- rinomino le ossa (in EDIT/OBJECT va bene sui data.bones) ---
    renamed = 0
    for old, new in mapping.items():
        b = arm.data.bones.get(old)
        if b:
            b.name = new
            renamed += 1
    print(f"[finalize] ossa rinominate: {renamed}")

    # --- piedi a Z=0 + osso 'root' a terra --------------------------------
    # L'FBX di UniRig importa con trasformazioni IDENTITA' (oggetto a 0,0,0,
    # scala 1): quindi coordinate locali == mondo. NON sposto l'oggetto (lasciava
    # un offset non applicato che in UE fa schizzare via il personaggio col
    # retarget): sposto i DATI, vertici e ossa INSIEME dello stesso dz, cosi'
    # restano allineati, l'oggetto resta a zero e il root cade esatto a terra.
    zmin = None
    for o in bpy.data.objects:
        if o.type == "MESH":
            for v in o.data.vertices:
                z = v.co.z
                zmin = z if zmin is None else min(zmin, z)
    dz = -zmin if zmin is not None else 0.0

    # sposto i vertici delle mesh
    for o in bpy.data.objects:
        if o.type == "MESH":
            for v in o.data.vertices:
                v.co.z += dz
            o.data.update()

    # sposto le ossa (edit) dello stesso dz, aggiungo root a terra + ossa IK
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    eb = arm.data.edit_bones
    # SCOLLEGO tutte le ossa prima di toccarle: con use_connect la testa del figlio
    # e' incollata alla coda del padre, e ogni spostamento si somma a cascata lungo
    # la catena (dz applicato due volte, ossa che esplodono). Scollegate, ogni
    # osso si sposta una volta sola.
    for b in eb:
        b.use_connect = False
    for b in eb:
        b.head = (b.head.x, b.head.y, b.head.z + dz)
        b.tail = (b.tail.x, b.tail.y, b.tail.z + dz)

    def bpos(name):
        b = eb.get(name)
        return (b.head.x, b.head.y, b.head.z) if b else None

    foot_l, foot_r = bpos("foot_l"), bpos("foot_r")
    hand_l, hand_r = bpos("hand_l"), bpos("hand_r")

    # NIENTE osso 'root'. Hans e Manny (che funzionano) NON ce l'hanno: hanno
    # pelvis + ik_foot_root + ik_hand_root come ossa TOP-LEVEL. Se metto un osso
    # chiamato 'root', UE lo usa come retarget-root statico e il moto del bacino
    # della sorgente ci finisce sopra sbagliato -> il personaggio viene scagliato
    # via (sparisce). Lascio quindi il pelvis come radice, come Hans.
    for b in eb:
        b.use_connect = False

    # ossa IK virtuali dello UE Mannequin: Manny e Hans le HANNO (top-level).
    # Senza, UE dice "Pin Bone ... non-existant bone ik_foot_root".
    def mkbone(name, head, parent):
        nb = eb.new(name)
        nb.head = head
        nb.tail = (head[0], head[1] + 0.15, head[2])
        p = eb.get(parent) if parent else None
        if p:
            nb.parent = p
        nb.use_connect = False

    mkbone("ik_foot_root", (0.0, 0.0, 0.0), None)   # top-level, come Hans
    if foot_l:
        mkbone("ik_foot_l", foot_l, "ik_foot_root")
    if foot_r:
        mkbone("ik_foot_r", foot_r, "ik_foot_root")
    mkbone("ik_hand_root", (0.0, 0.0, 0.0), None)   # top-level, come Hans
    mkbone("ik_hand_gun", hand_r if hand_r else (0.0, 0.0, 0.0), "ik_hand_root")
    if hand_r:
        mkbone("ik_hand_r", hand_r, "ik_hand_gun")
    if hand_l:
        mkbone("ik_hand_l", hand_l, "ik_hand_gun")

    bpy.ops.object.mode_set(mode="OBJECT")
    print(f"[finalize] piedi a Z=0 (shift {dz:.3f}) + ossa IK, pelvis radice (come Hans)")

    # --- SCALA: normalizzo l'altezza a 180 cm nei DATI GREZZI -----------------
    # REGOLA CONFERMATA: UE legge i numeri grezzi dei vertici come CENTIMETRI.
    # Hans ha dati grezzi ~171 -> 171 cm giusto. Se lascio i dati in metri (~1.7)
    # UE li legge come 1.7 cm = minuscolo. Quindi scalo i dati finche' l'altezza
    # e' ~180 (unita' = cm), poi esporto SENZA conversioni (apply_unit_scale=False,
    # FBX_SCALE_NONE) cosi' i grezzi restano 180 -> UE = 180 cm, come un personaggio
    # UE. Niente piu' gigante ne' minuscolo, e non dipende dall'unita' dichiarata.
    TARGET_CM = 180.0
    hmin = hmax = None
    for o in bpy.data.objects:
        if o.type == "MESH":
            for v in o.data.vertices:
                z = v.co.z
                hmin = z if hmin is None else min(hmin, z)
                hmax = z if hmax is None else max(hmax, z)
    height = (hmax - hmin) if (hmin is not None and hmax != hmin) else 1.0
    sf = TARGET_CM / height
    for o in bpy.data.objects:
        if o.type == "MESH":
            for v in o.data.vertices:
                v.co = (v.co.x * sf, v.co.y * sf, v.co.z * sf)
            o.data.update()
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for eb in arm.data.edit_bones:
        eb.use_connect = False
    for eb in arm.data.edit_bones:
        eb.head = (eb.head.x * sf, eb.head.y * sf, eb.head.z * sf)
        eb.tail = (eb.tail.x * sf, eb.tail.y * sf, eb.tail.z * sf)
    bpy.ops.object.mode_set(mode="OBJECT")
    print(f"[finalize] altezza normalizzata a {TARGET_CM:.0f} cm (fattore {sf:.1f})")

    # PEZZO CHIAVE: imposto l'unita' della scena su CENTIMETRI. Cosi' l'export
    # DICHIARA i cm nell'FBX (come Hans) e UE legge i dati 1:1 in cm. Senza questo,
    # il file dichiarava metri e UE moltiplicava x100 -> personaggio gigante.
    # Verificato: con questo il file ri-letto torna a ~1.8 m come Hans (1.71).
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 0.01

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.fbx(
        filepath=out_fbx,
        use_selection=False,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_NONE",
        global_scale=1.0,
        add_leaf_bones=False,
        bake_anim=False,
        mesh_smooth_type="FACE",
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        path_mode="COPY",
        embed_textures=False,
    )
    print(f"[finalize] esportato -> {out_fbx}")


if __name__ == "__main__":
    main()
