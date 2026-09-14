# img23d.ps1 — client Windows: manda un'IMMAGINE al server, genera il modello 3D,
# riporta giu' i risultati.
#
#   .\img23d.ps1 foto.png
#   .\img23d.ps1 foto.png -Rig
#   .\img23d.ps1 foto.png -Rig -Octree 512 -Texture 2048
#
# Al primo avvio, se manca img23d.config, te lo crea chiedendoti server e cartella.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Image,

    [switch] $Rig,
    [int]    $Octree,
    [int]    $Texture,
    [int]    $ShapeSteps,
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'

foreach ($exe in 'ssh', 'scp') {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        throw "$exe non trovato. Installa 'OpenSSH Client' da Impostazioni > App > Funzionalita' facoltative."
    }
}

# ---------------------------------------------------------------- CONFIG ---
$cfgFile = Join-Path $PSScriptRoot 'img23d.config'
$cfg = @{}

if (Test-Path $cfgFile) {
    Get-Content $cfgFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $k, $v = $line.Split('=', 2)
            $cfg[$k.Trim()] = $v.Trim()
        }
    }
}

# primo avvio: nessun config -> lo creo in modo interattivo
if (-not $cfg.ContainsKey('SERVER') -or -not $cfg['SERVER'] -or $cfg['SERVER'] -eq 'utente@host.esempio.com') {
    Write-Host ""
    Write-Host "  Primo avvio: configuriamo img23d." -ForegroundColor Cyan
    Write-Host "  (potrai modificare i valori in seguito nel file img23d.config)" -ForegroundColor DarkGray
    Write-Host ""
    $srv = Read-Host "  Server SSH (utente@host)"
    if (-not $srv) { throw "server obbligatorio" }
    $rem = Read-Host "  Cartella sul server [~/imageTo3D]"
    if (-not $rem) { $rem = '~/imageTo3D' }
    "SERVER=$srv", "REMOTE_DIR=$rem" | Set-Content -Path $cfgFile -Encoding ASCII
    $cfg['SERVER'] = $srv
    $cfg['REMOTE_DIR'] = $rem
    Write-Host ""
    Write-Host "  Salvato in img23d.config" -ForegroundColor Green
}

$Server    = $cfg['SERVER']
$RemoteDir = if ($cfg.ContainsKey('REMOTE_DIR') -and $cfg['REMOTE_DIR']) { $cfg['REMOTE_DIR'] } else { '~/imageTo3D' }
$LocalDir  = Join-Path $PSScriptRoot 'output'
$RemoteSh  = ($RemoteDir -replace '^~/', '$HOME/') -replace '^~$', '$HOME'
# ---------------------------------------------------------------------------

if (-not (Test-Path $Image)) { throw "immagine non trovata: $Image" }
$imgItem = Get-Item $Image
$ext = $imgItem.Extension.ToLower()
if ($ext -notin '.png', '.jpg', '.jpeg', '.webp') { throw "formato non supportato: $ext (png/jpg/jpeg/webp)" }
$remoteName = ($imgItem.BaseName -replace '[^A-Za-z0-9_\-]', '') + $ext
if (-not $remoteName) { $remoteName = "input$ext" }

# variabili passate a generate.sh
$envPairs = @()
if ($Rig)                                         { $envPairs += 'RIG=1' }
if ($PSBoundParameters.ContainsKey('Octree'))     { $envPairs += "OCTREE_RESOLUTION=$Octree" }
if ($PSBoundParameters.ContainsKey('Texture'))    { $envPairs += "TEXTURE_RESOLUTION=$Texture" }
if ($PSBoundParameters.ContainsKey('ShapeSteps')) { $envPairs += "SHAPE_STEPS=$ShapeSteps" }
$envStr = ($envPairs -join ' ')
$keepStr = if ($Keep) { '1' } else { '0' }

Write-Host ""
Write-Host "  server   : $Server"      -ForegroundColor DarkGray
Write-Host "  immagine : $($imgItem.Name) -> images/$remoteName" -ForegroundColor DarkGray
if ($envStr) { Write-Host "  extra    : $envStr" -ForegroundColor DarkGray }
Write-Host ""

# --- 1. carico l'immagine sul server ---------------------------------------
$prep = @(
    "cd `"$RemoteSh`" 2>/dev/null || { echo '[img23d] cartella remota non trovata: $RemoteSh' >&2; exit 2; }"
    'mkdir -p images output'
    "[ `"$keepStr`" = `"1`" ] || rm -f images/*.png images/*.jpg images/*.jpeg images/*.webp"
) -join '; '
& ssh $Server $prep
if ($LASTEXITCODE -ne 0) { throw "preparazione remota fallita (exit $LASTEXITCODE). Controlla SERVER/REMOTE_DIR in img23d.config" }
& scp "$($imgItem.FullName)" "${Server}:${RemoteDir}/images/$remoteName"
if ($LASTEXITCODE -ne 0) { throw "upload dell'immagine fallito" }

# --- 2. genero -------------------------------------------------------------
$run = @(
    "cd `"$RemoteSh`""
    'ls -1 output 2>/dev/null | grep -E "^[0-9]{3}$" | sort > /tmp/img23d_before.txt || true'
    "$envStr bash generate.sh >&2"
    'ls -1 output 2>/dev/null | grep -E "^[0-9]{3}$" | sort > /tmp/img23d_after.txt'
    'comm -13 /tmp/img23d_before.txt /tmp/img23d_after.txt | sed "s/^/IMG23D_NEW=/"'
) -join '; '
$created = & ssh $Server $run
if ($LASTEXITCODE -ne 0) { throw "la generazione sul server e' fallita (exit $LASTEXITCODE)" }

$folders = @(
    $created |
    ForEach-Object { ($_ -replace '\r', '').Trim() } |
    Where-Object { $_ -match '^IMG23D_NEW=(\d{3})$' } |
    ForEach-Object { $Matches[1] }
)
if ($folders.Count -eq 0) { throw "il server non ha prodotto nessuna cartella nuova. Guarda il log qui sopra." }

# --- 3. scarico solo le cartelle nuove -------------------------------------
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
Write-Host ""
Write-Host "  scarico: $($folders -join ', ')" -ForegroundColor Cyan
foreach ($f in $folders) {
    & scp -r "${Server}:${RemoteDir}/output/$f" $LocalDir
    if ($LASTEXITCODE -ne 0) { Write-Warning "copia di $f incompleta" }
}

Write-Host ""
foreach ($f in $folders) {
    $dest = Join-Path $LocalDir $f
    Write-Host "  $dest" -ForegroundColor Green
    Get-ChildItem $dest -File | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor DarkGray }
}
Write-Host ""
$prev = @(Get-ChildItem -Path (Join-Path $LocalDir $folders[0]) -Filter preview.* -ErrorAction SilentlyContinue)
if ($prev.Count -gt 0) {
    Start-Process explorer.exe "/select,`"$($prev[0].FullName)`""
} else {
    Start-Process explorer.exe (Join-Path $LocalDir $folders[0])
}
