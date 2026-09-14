# img23d — UN'immagine sola: immagine 2D -> mesh 3D + texture PBR (Hunyuan3D-2.1)
# -> rigging automatico opzionale (UniRig) -> preview turntable (Blender).
# I pesi NON stanno qui: si montano da ./ckpts a runtime.
#
#   docker build -t img23d:latest .
#
# CUDA 12.8 / PyTorch 2.8: le GPU Blackwell (RTX PRO 6000, sm_120) hanno bisogno
# dei kernel cu128; le build cu121 falliscono con "no kernel image is available".

FROM pytorch/pytorch:2.8.0-cuda12.8-cudnn9-devel

ARG DEBIAN_FRONTEND=noninteractive
# 12.0 = Blackwell sm_120. Serve a compilare le estensioni CUDA custom
# (rasterizzatore texture di Hunyuan3D, flash_attn/spconv di UniRig) per la GPU
# giusta.
ENV TORCH_CUDA_ARCH_LIST="12.0+PTX" \
    FORCE_CUDA=1 \
    PYTHONUNBUFFERED=1 \
    HF_HOME=/data/hf \
    HY3DGEN_MODELS=/opt/hunyuan/ckpts

# --- dipendenze di sistema ---
# blender: preview turntable. libgl/xvfb: rendering headless.
# build-essential/cmake/ninja: compilazione estensioni CUDA.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs wget curl ffmpeg build-essential cmake ninja-build \
      blender libgl1 libegl1 libglib2.0-0 libsm6 libxext6 libxrender1 xvfb \
    && git lfs install \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
#  torch cu128 PRIMA di tutto, cosi' ogni cosa compilata dopo lo trova gia' giusto
# ============================================================================
RUN pip install --no-cache-dir --force-reinstall \
      torch==2.8.0 torchvision==0.23.0 \
      --index-url https://download.pytorch.org/whl/cu128

RUN python3 -c "\
import torch, sys; \
f = (getattr(torch._C, '_cuda_getArchFlags', lambda: '')() or ''); \
print('[build-check] torch', torch.__version__, '| arch:', f or '(nessuna)'); \
sys.exit(0 if ('sm_120' in f or 'compute_12' in f) else 1)" \
 || (echo '[build-check] torch senza kernel sm_120' >&2 && exit 1)

# ============================================================================
#  Hunyuan3D-2.1  (immagine -> mesh + texture PBR)      in /opt/hunyuan
# ============================================================================
RUN git clone https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1.git /opt/hunyuan
WORKDIR /opt/hunyuan
# il requirements puo' provare a ripinnare torch cu121: lo lasciamo girare ma
# subito dopo NON reinstalliamo torch (resta il nostro cu128).
RUN pip install --no-cache-dir -r requirements.txt || true
# estensioni CUDA custom: il pezzo piu' fragile del build (vedi README).
RUN cd hy3dpaint/custom_rasterizer && pip install --no-cache-dir -e . \
 || (echo '[build] custom_rasterizer FALLITO (vedi README)' >&2; exit 1)
RUN cd hy3dpaint/DifferentiableRenderer && bash compile_mesh_painter.sh \
 || echo '[build] compile_mesh_painter non riuscito, la texture potrebbe non funzionare' >&2

# ============================================================================
#  UniRig  (mesh -> scheletro + skin, FBX riggato)      in /opt/unirig
# ============================================================================
RUN git clone https://github.com/VAST-AI-Research/UniRig.git /opt/unirig
WORKDIR /opt/unirig
# geometria: wheel per torch 2.8 cu128
RUN pip install --no-cache-dir torch_scatter torch_cluster \
      -f https://data.pyg.org/whl/torch-2.8.0+cu128.html \
 || pip install --no-cache-dir torch_scatter torch_cluster
RUN pip install --no-cache-dir spconv-cu126 || pip install --no-cache-dir spconv-cu120
# flash_attn: compilazione lenta e incline a fallire; se salta, UniRig gira
# comunque (piu' lento) o si disattiva con RIG=0.
RUN pip install --no-cache-dir --no-build-isolation flash_attn \
 || echo "[build] flash_attn FALLITO: rigging piu lento o assente" >&2
RUN pip install --no-cache-dir -r requirements.txt || true

# torch 2.6+ carica i checkpoint con weights_only=True di default; il checkpoint
# skin di UniRig contiene la classe box.box.Box, non allowlistata -> UnpicklingError
# ("Weights only load failed"). I checkpoint UniRig sono ufficiali e fidati: forzo
# weights_only=False all'inizio di run.py (override anche se il chiamante, es.
# Lightning, passa weights_only=True esplicito -> serve un wrapper, non un partial).
RUN python3 - <<'PY'
p = "/opt/unirig/run.py"
src = open(p).read()
patch = (
    "import torch as _t, functools as _f\n"
    "_orig_load = _t.load\n"
    "def _patched_load(*a, **k):\n"
    "    k['weights_only'] = False\n"
    "    return _orig_load(*a, **k)\n"
    "_t.load = _patched_load\n"
)
if "_patched_load" not in src:
    open(p, "w").write(patch + src)
    print("[build] run.py di UniRig patchato: weights_only=False")
else:
    print("[build] run.py gia' patchato")
PY

# UniRig FORZA os.environ['PYOPENGL_PLATFORM']='egl' in vertex_group.py: su questa
# macchina l'EGL della GPU non parte ("failed to create dri2 screen" /
# eglInitialize) neppure con NVIDIA_DRIVER_CAPABILITIES=all. Lo dirotto su OSMesa
# (rendering CPU via libosmesa6): lento sulla voxelizzazione ma indipendente dal
# driver, quindi il rigging arriva in fondo. NON basta un env var: lo sovrascrive
# il modulo all'import, quindi patcho il sorgente.
RUN python3 - <<'PY'
p = "/opt/unirig/src/data/vertex_group.py"
s = open(p).read()
s2 = (s.replace("'PYOPENGL_PLATFORM'] = 'egl'", "'PYOPENGL_PLATFORM'] = 'osmesa'")
       .replace('"PYOPENGL_PLATFORM"] = "egl"', '"PYOPENGL_PLATFORM"] = "osmesa"'))
if s != s2:
    open(p, "w").write(s2)
    print("[build] vertex_group.py: PYOPENGL_PLATFORM egl -> osmesa")
else:
    print("[build] ATTENZIONE: riga PYOPENGL_PLATFORM='egl' non trovata in vertex_group.py", flush=True)
PY

# ============================================================================
#  utility della pipeline + dipendenze core di Hunyuan3D
# ============================================================================
# libOpenGL per i plugin di pymeshlab (il remesh pre-texture di Hunyuan li usa;
# senza, "libOpenGL.so.0: cannot open shared object file"). Messo QUI, dopo le
# compilazioni CUDA, cosi' non invalida la loro cache nei rebuild.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libopengl0 libglu1-mesa libosmesa6 libosmesa6-dev \
    && rm -rf /var/lib/apt/lists/*
# Il requirements.txt di Hunyuan3D gira con "|| true": se salta a meta', queste
# librerie (diffusers su tutte) non entrano e gen_3d.py muore con
# "ModuleNotFoundError: No module named 'diffusers'". Le installo qui in modo
# ESPLICITO, DOPO le compilazioni CUDA lente cosi' restano in cache nei rebuild.
RUN pip install --no-cache-dir \
      diffusers transformers accelerate einops omegaconf \
      trimesh pymeshlab opencv-python scikit-image \
      xatlas pygltflib pybind11 \
      "huggingface_hub[cli]" rembg onnxruntime pillow

# mesh_inpaint_processor: e' l'inpaint C++ (meshVerticeInpaint) dell'ultimo passo
# del texture. compile_mesh_painter.sh nella sezione Hunyuan falliva perche' li'
# pybind11 non c'era ancora (requirements saltato dal "|| true") -> "InPaint
# Function CAN NOT BE Imported" e poi NameError a fine texture. Ora pybind11 c'e':
# ricompilo e VERIFICO che la .so esista (niente piu' fallimento silenzioso).
RUN cd /opt/hunyuan/hy3dpaint/DifferentiableRenderer \
 && bash compile_mesh_painter.sh \
 && ls -1 mesh_inpaint_processor*.so \
 && echo "[build] mesh_inpaint_processor compilato"

# realesrgan: e' l'upscaler della texture (imageSuperNet in hy3dpaint). Sta nel
# requirements.txt di Hunyuan ma il "|| true" lo saltava -> "No module named
# 'realesrgan'" e texture fallita. Tira dietro basicsr, che importa
# torchvision.transforms.functional_tensor, RIMOSSO in torchvision >= 0.17 -> va
# patchato in .functional (fix noto). Senza la patch, il primo import di basicsr
# crasherebbe.
RUN pip install --no-cache-dir realesrgan \
 && BSR="$(find /opt/conda/lib/python*/site-packages/basicsr -name degradations.py | head -1)" \
 && [ -n "$BSR" ] \
 && sed -i 's/from torchvision.transforms.functional_tensor import/from torchvision.transforms.functional import/' "$BSR" \
 && echo "[build] basicsr patchato: functional_tensor -> functional ($BSR)"

# Peso di Real-ESRGAN: imageSuperNet lo cerca in locale come "ckpt/RealESRGAN_x4plus.pth"
# (default della Hunyuan3DPaintConfig) e NON lo scarica da solo -> senza, il texture
# fallisce con file-not-found. Lo scarico e lo metto nei due path possibili (CWD e
# hy3dpaint), ~64MB.
RUN mkdir -p /opt/hunyuan/ckpt /opt/hunyuan/hy3dpaint/ckpt \
 && wget -q -O /opt/hunyuan/ckpt/RealESRGAN_x4plus.pth \
      https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth \
 && cp /opt/hunyuan/ckpt/RealESRGAN_x4plus.pth /opt/hunyuan/hy3dpaint/ckpt/RealESRGAN_x4plus.pth \
 && echo "[build] RealESRGAN_x4plus.pth scaricato"

# bpy-come-modulo SERVE per forza: sia Hunyuan (DifferentiableRenderer/mesh_utils.py)
# sia UniRig (src/data/extract.py, src/inference/merge.py) fanno "import bpy" senza
# fallback. Va PINNATO a 4.2.0 (LTS, wheel py3.11 verificata) perche' la 4.0 non
# esiste per py3.11 e le >=4.5/5.x davano problemi.
#   L'errore "undefined symbol: rtcIsSYCLDeviceSupported" NON e' un bpy rotto: e'
#   una COLLISIONE di SONAME. bpy porta la sua libembree4.so.4 (che HA il simbolo),
#   ma nel container un'altra libembree4.so.4 (senza SYCL) viene caricata prima e
#   soddisfa il DT_NEEDED al posto di quella di bpy -> simbolo mancante. Il fix e'
#   l'LD_PRELOAD in entrypoint.sh, che carica per prima quella giusta.
RUN pip install --no-cache-dir "bpy==4.2.0"

# OSMesa per il rigging: pyrender via OSMesa vuole OSMesaCreateContextAttribs,
# assente nel PyOpenGL vecchio ("cannot import name 'OSMesaCreateContextAttribs'").
# Lo aggiorno a una versione che lo espone.
RUN pip install --no-cache-dir --upgrade "PyOpenGL>=3.1.7"

# La custom pipeline di Hunyuan ("hunyuanpaintpbr") viene caricata con
# DiffusionPipeline.from_pretrained(custom_pipeline=...). La diffusers recente
# PRETENDE trust_remote_code=True per eseguire pipeline.py, ma il codice di
# Hunyuan (scritto per diffusers 0.30) non lo passa -> ValueError e texture
# fallita. Aggiungo l'argomento alla chiamata in multiview_utils.py.
RUN python3 - <<'PY'
p = "/opt/hunyuan/hy3dpaint/utils/multiview_utils.py"
s = open(p).read()
if "trust_remote_code" not in s:
    s2 = s.replace("custom_pipeline=custom_pipeline,",
                   "custom_pipeline=custom_pipeline, trust_remote_code=True,", 1)
    if s2 != s:
        open(p, "w").write(s2)
        print("[build] multiview_utils.py: aggiunto trust_remote_code=True")
    else:
        print("[build] ATTENZIONE: chiamata from_pretrained non trovata in multiview_utils.py", flush=True)
else:
    print("[build] multiview_utils.py: trust_remote_code gia' presente")
PY

# trimesh recente ha cambiato la firma di simplify_quadric_decimation: il primo
# argomento posizionale ora e' una PERCENTUALE (0-1), non il numero di facce.
# Hunyuan passa il conteggio (40000) -> "target_reduction must be between 0 and 1".
# Lo passo come keyword face_count=, che funziona su tutte le versioni.
RUN sed -i 's/simplify_quadric_decimation(target_count)/simplify_quadric_decimation(face_count=target_count)/' \
      /opt/hunyuan/hy3dpaint/utils/simplify_mesh_utils.py \
 && grep -q "face_count=target_count" /opt/hunyuan/hy3dpaint/utils/simplify_mesh_utils.py \
 && echo "[build] simplify_mesh_utils.py: simplify_quadric_decimation -> face_count="

# NON reinstallare torch dopo questo punto: qualunque requirements potrebbe
# averlo toccato. Rimettiamo il nostro cu128 come ultima parola.
RUN pip install --no-cache-dir --force-reinstall --no-deps \
      torch==2.8.0 torchvision==0.23.0 \
      --index-url https://download.pytorch.org/whl/cu128

RUN mkdir -p /opt/hunyuan/ckpts /opt/unirig/ckpts /data/input /data/output /data/hf
VOLUME ["/data/input", "/data/output"]

COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh 2>/dev/null || true

WORKDIR /opt/hunyuan
ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
