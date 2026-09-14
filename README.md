# img23d

Da una **immagine 2D** a un **modello 3D texturizzato** e, se vuoi, **riggato e pronto per Unreal Engine**. Tutto dentro Docker, con un client per lanciarlo comodo da **Windows, Linux o Mac**.

- **Geometria + texture PBR** con [Hunyuan3D-2.1](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1) (Tencent) — texture vere (albedo, metallic, roughness), non colore sui vertici.
- **Rigging automatico** opzionale con [UniRig](https://github.com/VAST-AI-Research/UniRig) (VAST / Tsinghua) — scheletro + skin weights.
- **Rifinitura per Unreal**: ossa rinominate come lo **UE Mannequin** + ossa IK + scala corretta (~1,8 m) → l'**Auto Generate Retargeter** di UE lo aggancia.
- **Export texture** in PNG separati (albedo / roughness / metallic) da collegare in UE.
- **Preview turntable** di ogni modello.
- **Toggle stile PS2** (low-poly + texture piccola) per un look retro.

Metti un'immagine, lanci un comando dal tuo PC, e ti torna la cartella con `model.glb` texturizzato e — con il rigging — `<nome>.fbx` pronto per UE.

---

## Come funziona (architettura)

```
   PC (Windows/Linux/Mac)                Server con GPU NVIDIA
   client/img23d.*          --ssh-->     Docker (Hunyuan3D-2.1 + UniRig + Blender)
   carica l'immagine,                    immagine -> mesh+texture -> rig -> preview
   scarica i risultati      <--scp--     output/NNN/
```

Il grosso del lavoro (GPU) sta sul **server**. Dal tuo **PC** usi solo il client, che carica l'immagine, avvia la generazione e ti riporta giù i file.

---

## 1) Setup del SERVER (una volta)

**Requisiti server:**

| | |
|---|---|
| GPU | NVIDIA con ≥ 29 GB VRAM. Blackwell (RTX 50xx / PRO 6000) supportata (CUDA 12.8 / PyTorch 2.8, kernel `sm_120`) |
| Disco | ~55 GB (~25 immagine Docker + ~30 pesi) |
| Software | Docker + NVIDIA Container Toolkit |

```bash
git clone <questo-repo> imageTo3D
cd imageTo3D
# build immagine + download pesi (~30 GB). Con il rigging:
RIG=1 nohup bash setup.sh > setup.log 2>&1 &
tail -f setup.log
```

`setup.sh` è idempotente: build dell'immagine Docker, download dei pesi, riepilogo. Il build **compila estensioni CUDA** (il punto più lento/fragile — vedi *Troubleshooting*).

---

## 2) Setup del CLIENT (sul tuo PC)

Ti serve solo un client SSH (`ssh` + `scp`):

- **Windows 10/11**: Impostazioni → App → Funzionalità facoltative → installa **OpenSSH Client**.
- **Mac/Linux**: già presenti.

I file del client sono nella cartella [`client/`](client/). Copiala dove vuoi sul tuo PC.

### Chiave SSH (consigliato, niente password ogni volta)

```bash
# Mac/Linux
ssh-keygen -t ed25519           # invio a tutte le domande
ssh-copy-id utente@host          # inserisci la password una volta sola
```
```powershell
# Windows (PowerShell)
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh utente@host "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### Primo avvio

Alla prima esecuzione il client ti chiede **server** e **cartella remota** e li salva in `img23d.config` (che poi puoi modificare a mano; vedi `img23d.config.example`).

**Windows:**
```
cd client
.\img23d.cmd ..\images\foto.png -Rig
```

**Mac / Linux:**
```
cd client
chmod +x img23d.sh        # solo la prima volta
./img23d.sh ../images/foto.png --rig
```

---

## Uso

**Windows**
```
img23d foto.png
img23d foto.png -Rig
img23d foto.png -Rig -Octree 512 -Texture 2048
```

**Mac / Linux**
```
./img23d.sh foto.png
./img23d.sh foto.png --rig
./img23d.sh foto.png --rig --octree 512 --texture 2048
```

Il client carica l'immagine, genera sul server, e ti scarica **solo la cartella nuova** in `client/output/NNN/`.

### Cosa ottieni in `output/NNN/`

| File | Cos'è |
|---|---|
| `model.glb` | mesh + texture PBR incorporata |
| `model_albedo.png` / `_roughness.png` / `_metallic.png` | le mappe separate, da collegare in UE |
| `<nome>.fbx` | **il file per Unreal**: scheletro con nomi UE Mannequin + ossa IK, scala giusta |
| `model_rigged.fbx` | rig grezzo (nomi `bone_N`) — di solito usi quello sopra |
| `preview.mp4` | turntable a 360° |

---

## Parametri

Stanno in [`config.env`](config.env) **sul server** (li modifichi lì), oppure li passi al volo dal client (`-Rig`, `-Octree`, `-Texture`, `-ShapeSteps`).

| Variabile | Default | Cosa fa |
|---|---|---|
| `SHAPE_STEPS` | 50 | passi diffusion della geometria |
| `OCTREE_RESOLUTION` | 384 | densità poligoni: 256 / 384 / 512 (più alto = più dettaglio, anche sul volto) |
| `TEXTURE_STEPS` | 30 | passi diffusion texture |
| `TEXTURE_RESOLUTION` | 2048 | 1024 o 2048 |
| `REMOVE_BACKGROUND` | 1 | scontorna l'immagine prima di generare |
| `RIG` | 0 | `1` = genera anche l'FBX riggato |
| `RIG_FLIP_LR` | 0 | `1` se in UE le animazioni escono specchiate (scambia L/R) |
| `EXPORT_TEXTURES` | 1 | esporta le mappe texture in PNG separati |
| `POST_DECIMATE_FACES` | 0 | >0 = versione low-poly a N facce (`model_light.glb`) |

### Stile PS2 (opzionale)

Genera a qualità normale, poi applica un downgrade **uniforme e voluto** (è così che si faceva su PS2):

```env
POST_DECIMATE_FACES=6000    # mesh low-poly
PS2_TEXTURE=1               # crea model_albedo_ps2.png
PS2_TEXTURE_SIZE=256        # 128 / 256 / 512
PS2_POSTERIZE=5             # palette ridotta (0=off)
```

Non tocca i file normali: aggiunge le versioni PS2 accanto.

---

## In Unreal Engine

1. Importa **`<nome>.fbx`** come Skeletal Mesh (entra a ~1,8 m, dimensione da personaggio).
2. Collega a mano le texture: `model_albedo` → Base Color, `model_roughness` → Roughness, `model_metallic` → Metallic.
3. **IK Retargeter** → l'Auto-Generate aggancia lo scheletro dai nomi UE.

Note oneste:
- Le **dita** sono 4 per mano (UE ne prevede 5): corpo e arti si retargetano perfetti, le dita in parte.
- Il **volto** è il punto debole tipico dell'image-to-3D: per migliorarlo alza `OCTREE_RESOLUTION=512` e parti da un'immagine con la faccia frontale e nitida.
- Se le animazioni escono specchiate: `RIG_FLIP_LR=1`.

---

## Come è fatto

```
setup.sh              build immagine + pesi (server)
generate.sh           il comando che gira sul server
config.env            tutti i parametri
Dockerfile            un'immagine: Hunyuan3D-2.1 + UniRig + Blender
scripts/              la pipeline nel container (gen_3d, rig, rig_finalize, ...)
client/               il launcher per il tuo PC
  img23d.ps1 / .cmd   Windows
  img23d.sh           Linux / Mac
  img23d.config       server + cartella (creato al primo avvio)
```

---

## Troubleshooting

- **`cartella remota non trovata`** dal client → `REMOTE_DIR` in `img23d.config` non combacia con la cartella sul server.
- **Build fallisce** (`custom_rasterizer` / `flash_attn`) → è la compilazione CUDA, il punto più fragile; ricontrolla `TORCH_CUDA_ARCH_LIST` e i log.
- **`no kernel image is available`** al primo run → GPU più recente dei kernel torch; il `[gpu-check]` lo segnala.
- **Out of memory** → `TEXTURE_RESOLUTION=1024` o `OCTREE_RESOLUTION=256`.
- **Personaggio gigante/minuscolo in UE** → risolto: l'FBX finale dichiara i centimetri come lo UE Mannequin (entra a ~1,8 m).

## Crediti e licenze

- [Hunyuan3D-2.1](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1) — Tencent (licenza community, leggi la loro LICENSE).
- [UniRig](https://github.com/VAST-AI-Research/UniRig) — VAST-AI / Tsinghua.

Il codice di questo repo è liberamente riutilizzabile; i modelli hanno le loro licenze.
