# img23d

Turn a **2D image** into a **textured 3D model** — and, if you want, a **rigged model ready for Unreal Engine**. Everything runs in Docker, with a client to drive it comfortably from **Windows, Linux, or Mac**.

- **Geometry + PBR texture** via [Hunyuan3D-2.1](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1) (Tencent) — real textures (albedo, metallic, roughness), not vertex colors.
- **Automatic rigging** (optional) via [UniRig](https://github.com/VAST-AI-Research/UniRig) (VAST / Tsinghua) — skeleton + skin weights.
- **Unreal-ready finishing**: bones renamed to the **UE Mannequin** convention + IK bones + correct scale (~1.8 m) → UE's **Auto-Generate Retargeter** picks it up.
- **Texture export** as separate PNGs (albedo / roughness / metallic) to plug into UE.
- **Turntable preview** of every model.
- **PS2-style toggles** (low-poly + small texture) for a retro look.

Drop in an image, run one command from your PC, and get back a folder with a textured `model.glb` and — with rigging — a `<name>.fbx` ready for UE.

---

## How it works (architecture)

```
   PC (Windows/Linux/Mac)                Server with NVIDIA GPU
   client/img23d.*          --ssh-->     Docker (Hunyuan3D-2.1 + UniRig + Blender)
   uploads the image,                    image -> mesh+texture -> rig -> preview
   downloads the results    <--scp--     output/NNN/
```

The heavy lifting (GPU) happens on the **server**. From your **PC** you only use the client, which uploads the image, starts the generation, and brings the files back.

---

## 1) SERVER setup (once)

**Server requirements:**

| | |
|---|---|
| GPU | NVIDIA with ≥ 29 GB VRAM. Blackwell (RTX 50xx / PRO 6000) supported (CUDA 12.8 / PyTorch 2.8, `sm_120` kernels) |
| Disk | ~55 GB (~25 Docker image + ~30 weights) |
| Software | Docker + NVIDIA Container Toolkit |

```bash
git clone <this-repo> imageTo3D
cd imageTo3D
# build image + download weights (~30 GB). With rigging:
RIG=1 nohup bash setup.sh > setup.log 2>&1 &
tail -f setup.log
```

`setup.sh` is idempotent: it builds the Docker image, downloads the weights, and prints a summary. The build **compiles CUDA extensions** (the slowest / most fragile part — see *Troubleshooting*).

---

## 2) CLIENT setup (on your PC)

You only need an SSH client (`ssh` + `scp`):

- **Windows 10/11**: Settings → Apps → Optional Features → install **OpenSSH Client**.
- **Mac/Linux**: already available.

The client files live in [`client/`](client/). Copy that folder wherever you like on your PC.

### SSH key (recommended — no password every time)

```bash
# Mac/Linux
ssh-keygen -t ed25519           # press enter through all prompts
ssh-copy-id user@host           # enter the password once
```
```powershell
# Windows (PowerShell)
ssh-keygen -t ed25519
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh user@host "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### First run

On the first run, if `img23d.config` is missing, the client asks for the **server** and the **remote folder** and saves them into `img23d.config` (which you can edit later by hand; see `img23d.config.example`).

**Windows:**
```
cd client
.\img23d.cmd ..\images\photo.png -Rig
```

**Mac / Linux:**
```
cd client
chmod +x img23d.sh        # first time only
./img23d.sh ../images/photo.png --rig
```

---

## Usage

**Windows**
```
img23d photo.png
img23d photo.png -Rig
img23d photo.png -Rig -Octree 512 -Texture 2048
```

**Mac / Linux**
```
./img23d.sh photo.png
./img23d.sh photo.png --rig
./img23d.sh photo.png --rig --octree 512 --texture 2048
```

The client uploads the image, generates on the server, and downloads **only the new folder** into `client/output/NNN/`.

### What you get in `output/NNN/`

| File | What it is |
|---|---|
| `model.glb` | mesh + embedded PBR texture |
| `model_albedo.png` / `_roughness.png` / `_metallic.png` | separate maps, to plug into UE |
| `<name>.fbx` | **the file for Unreal**: skeleton with UE Mannequin bone names + IK bones, correct scale |
| `model_rigged.fbx` | raw rig (`bone_N` names) — you'll usually use the one above |
| `preview.mp4` | 360° turntable |

---

## Parameters

They live in [`config.env`](config.env) **on the server** (edit them there), or pass them on the fly from the client (`-Rig`, `-Octree`, `-Texture`, `-ShapeSteps`).

| Variable | Default | What it does |
|---|---|---|
| `SHAPE_STEPS` | 50 | geometry diffusion steps |
| `OCTREE_RESOLUTION` | 384 | polygon density: 256 / 384 / 512 (higher = more detail, also on the face) |
| `TEXTURE_STEPS` | 30 | texture diffusion steps |
| `TEXTURE_RESOLUTION` | 2048 | 1024 or 2048 |
| `REMOVE_BACKGROUND` | 1 | cut out the background before generating |
| `RIG` | 0 | `1` = also generate the rigged FBX |
| `RIG_FLIP_LR` | 0 | `1` if animations come out mirrored in UE (swaps L/R) |
| `EXPORT_TEXTURES` | 1 | export texture maps as separate PNGs |
| `POST_DECIMATE_FACES` | 0 | >0 = low-poly version at N faces (`model_light.glb`) |

### PS2 style (optional)

Generate at normal quality, then apply a **deliberate, uniform** downgrade (this is how PS2 assets were actually made):

```env
POST_DECIMATE_FACES=6000    # low-poly mesh
PS2_TEXTURE=1               # creates model_albedo_ps2.png
PS2_TEXTURE_SIZE=256        # 128 / 256 / 512
PS2_POSTERIZE=5             # reduced palette (0=off)
```

It doesn't touch the normal files: it adds the PS2 versions alongside.

---

## In Unreal Engine

1. Import **`<name>.fbx`** as a Skeletal Mesh (it comes in at ~1.8 m, character-sized).
2. Plug the textures manually: `model_albedo` → Base Color, `model_roughness` → Roughness, `model_metallic` → Metallic.
3. **IK Retargeter** → Auto-Generate picks up the skeleton from the UE bone names.

Honest notes:
- **Fingers** are 4 per hand (UE expects 5): the body and limbs retarget perfectly, fingers only partially.
- The **face** is the usual weak point of image-to-3D: to improve it, raise `OCTREE_RESOLUTION=512` and start from an image with a clear, front-facing face.
- If animations come out mirrored: `RIG_FLIP_LR=1`.

---

## Project layout

```
setup.sh              build image + weights (server)
generate.sh           the command that runs on the server
config.env            all parameters
Dockerfile            single image: Hunyuan3D-2.1 + UniRig + Blender
scripts/              the in-container pipeline (gen_3d, rig, rig_finalize, ...)
client/               the launcher for your PC
  img23d.ps1 / .cmd   Windows
  img23d.sh           Linux / Mac
  img23d.config       server + folder (created on first run)
```

---

## Troubleshooting

- **`remote folder not found`** from the client → `REMOTE_DIR` in `img23d.config` doesn't match the folder on the server.
- **Build fails** (`custom_rasterizer` / `flash_attn`) → that's the CUDA compilation, the most fragile step; re-check `TORCH_CUDA_ARCH_LIST` and the logs.
- **`no kernel image is available`** on first run → GPU newer than the torch kernels; the `[gpu-check]` at startup flags it.
- **Out of memory** → `TEXTURE_RESOLUTION=1024` or `OCTREE_RESOLUTION=256`.
- **Character giant/tiny in UE** → fixed: the final FBX declares centimeters like the UE Mannequin (comes in at ~1.8 m).

## Credits and licenses

- [Hunyuan3D-2.1](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1) — Tencent (community license, read their LICENSE).
- [UniRig](https://github.com/VAST-AI-Research/UniRig) — VAST-AI / Tsinghua.

The code in this repo is freely reusable; the models have their own licenses.
