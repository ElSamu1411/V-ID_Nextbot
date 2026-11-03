#!/usr/bin/env python3
"""
Compilador reproducible de recursos multimedia para VØID (npc_void).
- Conserva intactos todos los originales en Imagenes/ y Sonidos/.
- Recorta digitalmente el fondo negro exterior de face_1_VOID.jpg y face_2_VOID.jpg,
  preservando las sombras internas profundas (cuencas oculares y cavidad bucal) y
  centrando proporcionalmente ambos rostros en un lienzo 1024x1024 RGBA de 32 bits.
- Compila face_1_VOID.vtf y face_2_VOID.vtf en formato VTF v7.2 (RGBA8888 sin pérdida)
  con banderas Clamp S, Clamp T, No Mipmap, No LOD y EightBitAlpha.
- Genera el icono del Spawnmenu materials/entities/npc_void.png (256x256).
- Transcodifica los 11 archivos de audio a MP3 44100 Hz, CBR 192 kbps, Estéreo,
  eliminando metadatos ID3/Xing problemáticos y normalizando nombres ASCII.
"""

import os
import struct
import subprocess
import sys
import numpy as np
from PIL import Image
from scipy import ndimage
import imageio_ffmpeg

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG_SRC_DIR = os.path.join(ROOT_DIR, "Imagenes")
SND_SRC_DIR = os.path.join(ROOT_DIR, "Sonidos")

ADDON_DIR = os.path.join(ROOT_DIR, "void_nextbot")
MAT_ENT_DIR = os.path.join(ADDON_DIR, "materials", "entities")
MAT_VOID_DIR = os.path.join(MAT_ENT_DIR, "npc_void")
SND_VOID_DIR = os.path.join(ADDON_DIR, "sound", "npc_void")
BUILD_PREVIEW_DIR = os.path.join(ROOT_DIR, "tools", "preview_png")

# Valve VTF v7.2 constants
TEXTUREFLAGS_CLAMPS = 0x00000004
TEXTUREFLAGS_CLAMPT = 0x00000008
TEXTUREFLAGS_NOMIP = 0x00000100
TEXTUREFLAGS_NOLOD = 0x00000200
TEXTUREFLAGS_EIGHTBITALPHA = 0x00002000

IMAGE_FORMAT_RGBA8888 = 0
IMAGE_FORMAT_DXT1 = 13


def make_ellipse_struct(rx: int, ry: int) -> np.ndarray:
    y, x = np.ogrid[-ry : ry + 1, -rx : rx + 1]
    return ((x / max(rx, 1)) ** 2 + (y / max(ry, 1)) ** 2) <= 1.0


def build_rgba_face(
    src_path: str,
    target_face_height: int,
    close_rx: int,
    close_ry: int,
    feather_sigma: float = 7.0,
) -> Image.Image:
    """
    Carga el JPG original, recorta la caja del rostro con margen seguro, escala de forma
    estrictamente uniforme (1:1 en X e Y, cero deformación) para lograr una altura
    coherente en el lienzo 1024x1024, y construye el canal alfa combinando:
      - Nitidez íntegra de los rasgos blancos originales (sin difuminar bordes internos).
      - Silueta craneal orgánica opaca en el interior (ojos y boca negros opacos) y
        transparente (alpha=0) en todo el fondo exterior.
    """
    src_img = Image.open(src_path).convert("RGB")
    arr = np.asarray(src_img, dtype=np.float32)
    lum = 0.299 * arr[:, :, 0] + 0.587 * arr[:, :, 1] + 0.114 * arr[:, :, 2]

    # Detectar bounding box real de los rasgos faciales (luminancia > 20)
    ys, xs = np.where(lum > 20.0)
    min_x, max_x = int(xs.min()), int(xs.max())
    min_y, max_y = int(ys.min()), int(ys.max())
    face_w = max_x - min_x + 1
    face_h = max_y - min_y + 1

    # Escala uniforme (sin estirar jamás proporciones)
    scale = target_face_height / float(face_h)
    new_w = int(round(src_img.width * scale))
    new_h = int(round(src_img.height * scale))
    resized = src_img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    res_arr = np.asarray(resized, dtype=np.float32)
    res_lum = (
        0.299 * res_arr[:, :, 0]
        + 0.587 * res_arr[:, :, 1]
        + 0.114 * res_arr[:, :, 2]
    )

    # Centrar el rostro escalado exactamente en (512, 512) dentro de 1024x1024
    rys, rxs = np.where(res_lum > 20.0)
    rcx = 0.5 * (float(rxs.min()) + float(rxs.max()))
    rcy = 0.5 * (float(rys.min()) + float(rys.max()))

    canvas_lum = np.zeros((1024, 1024), dtype=np.float32)
    offset_x = int(round(512.0 - rcx))
    offset_y = int(round(512.0 - rcy))

    src_x0 = max(0, -offset_x)
    src_y0 = max(0, -offset_y)
    dst_x0 = max(0, offset_x)
    dst_y0 = max(0, offset_y)
    copy_w = min(new_w - src_x0, 1024 - dst_x0)
    copy_h = min(new_h - src_y0, 1024 - dst_y0)

    canvas_lum[dst_y0 : dst_y0 + copy_h, dst_x0 : dst_x0 + copy_w] = res_lum[
        src_y0 : src_y0 + copy_h, src_x0 : src_x0 + copy_w
    ]

    # Limpieza de ruido de compresión JPEG en negros puros y blancos altos
    clean_lum = np.clip((canvas_lum - 10.0) * (255.0 / (242.0 - 10.0)), 0.0, 255.0)

    # Construcción de la silueta craneal orgánica (cierra cuencas oculares y boca,
    # dejando 100% transparente el exterior del lienzo 1024x1024)
    fg_mask = clean_lum > 18.0
    # Eliminar chispas aisladas de 1-2 px si existieran antes del cierre morfológico
    fg_clean = ndimage.binary_opening(fg_mask, structure=np.ones((2, 2), dtype=bool))
    struct_close = make_ellipse_struct(close_rx, close_ry)
    head_hull = ndimage.binary_closing(fg_clean, structure=struct_close)
    head_hull = ndimage.binary_fill_holes(head_hull)
    # Ligera dilatación perimetral suave para envolver los rasgos blancos con un halo oscuro natural
    head_hull = ndimage.binary_dilation(head_hull, structure=make_ellipse_struct(8, 8))

    # Suavizado Gaussiano en el borde exterior de la silueta para evitar dientes de sierra
    hull_float = ndimage.gaussian_filter(head_hull.astype(np.float32), sigma=feather_sigma)
    # Re-normalizar para que el interior sea 100% opaco (255) y decaiga a 0 afuera
    silhouette_alpha = np.clip((hull_float - 0.12) / 0.55, 0.0, 1.0) * 255.0
    # Asegurar cero absoluto lejos de la cabeza y en los 4 bordes del lienzo (Clamp S/T limpio)
    silhouette_alpha[silhouette_alpha < 3.0] = 0.0
    silhouette_alpha[:4, :] = 0.0
    silhouette_alpha[-4:, :] = 0.0
    silhouette_alpha[:, :4] = 0.0
    silhouette_alpha[:, -4:] = 0.0

    final_alpha = np.maximum(clean_lum, silhouette_alpha)
    final_alpha[:2, :] = 0.0
    final_alpha[-2:, :] = 0.0
    final_alpha[:, :2] = 0.0
    final_alpha[:, -2:] = 0.0

    rgba = np.zeros((1024, 1024, 4), dtype=np.uint8)
    rgb_u8 = np.clip(np.round(clean_lum), 0, 255).astype(np.uint8)
    rgba[:, :, 0] = rgb_u8
    rgba[:, :, 1] = rgb_u8
    rgba[:, :, 2] = rgb_u8
    rgba[:, :, 3] = np.clip(np.round(final_alpha), 0, 255).astype(np.uint8)

    return Image.fromarray(rgba, mode="RGBA")


def encode_dxt1_16x16_thumbnail(img_rgba: Image.Image) -> bytes:
    """Genera miniatura DXT1 válida de 16x16 (128 bytes) para compatibilidad total VTF."""
    thumb = img_rgba.resize((16, 16), Image.Resampling.BILINEAR)
    arr = np.asarray(thumb, dtype=np.uint8)
    out = bytearray()
    for by in range(0, 16, 4):
        for bx in range(0, 16, 4):
            block = arr[by : by + 4, bx : bx + 4]
            # Componer sobre negro según alfa para miniatura opaca DXT1
            alpha = block[:, :, 3:4].astype(np.float32) / 255.0
            rgb = (block[:, :, :3].astype(np.float32) * alpha).astype(np.uint8)
            lum = (
                0.299 * rgb[:, :, 0] + 0.587 * rgb[:, :, 1] + 0.114 * rgb[:, :, 2]
            ).reshape(-1)
            min_idx = int(np.argmin(lum))
            max_idx = int(np.argmax(lum))
            flat_rgb = rgb.reshape(-1, 3)
            c_min = flat_rgb[min_idx]
            c_max = flat_rgb[max_idx]

            def to_rgb565(c):
                return (
                    ((int(c[0]) >> 3) << 11)
                    | ((int(c[1]) >> 2) << 5)
                    | (int(c[2]) >> 3)
                )

            c0 = to_rgb565(c_max)
            c1 = to_rgb565(c_min)
            if c0 < c1:
                c0, c1 = c1, c0
                c_max, c_min = c_min, c_max
            if c0 == c1:
                out.extend(struct.pack("<HHI", c0, c1, 0))
                continue

            p0 = c_max.astype(np.float32)
            p1 = c_min.astype(np.float32)
            palette = np.stack([p0, p1, (2 * p0 + p1) / 3.0, (p0 + 2 * p1) / 3.0], axis=0)
            px = flat_rgb.astype(np.float32)[:, None, :]
            dists = np.sum((px - palette[None, :, :]) ** 2, axis=2)
            indices = np.argmin(dists, axis=1)
            bits = 0
            for i in range(16):
                bits |= (int(indices[i]) & 0x3) << (2 * i)
            out.extend(struct.pack("<HHI", c0, c1, bits))
    return bytes(out)


def write_vtf_rgba8888(img_rgba: Image.Image, dst_vtf_path: str) -> None:
    """Escribe un archivo Valve Texture Format (.vtf) v7.2 RGBA8888 sin pérdida."""
    w, h = img_rgba.size
    assert (w, h) == (1024, 1024), "El lienzo debe ser estrictamente 1024x1024"

    flags = (
        TEXTUREFLAGS_CLAMPS
        | TEXTUREFLAGS_CLAMPT
        | TEXTUREFLAGS_NOMIP
        | TEXTUREFLAGS_NOLOD
        | TEXTUREFLAGS_EIGHTBITALPHA
    )

    arr = np.asarray(img_rgba, dtype=np.uint8)
    alpha_norm = arr[:, :, 3:4].astype(np.float32) / 255.0
    refl = np.mean((arr[:, :, :3].astype(np.float32) / 255.0) * alpha_norm, axis=(0, 1))

    header = struct.pack(
        "<4sIIIHHIHH4sfff4sfiBiBBH15s",
        b"VTF\x00",
        7,
        2,  # Versión 7.2
        80,  # Tamaño de cabecera = 80 bytes
        w,
        h,
        flags,
        1,  # frames = 1
        0,  # firstFrame = 0
        b"\x00" * 4,
        float(refl[0]),
        float(refl[1]),
        float(refl[2]),
        b"\x00" * 4,
        1.0,  # bumpmapScale
        IMAGE_FORMAT_RGBA8888,  # highResImageFormat = RGBA8888 (0)
        1,  # mipmapCount = 1 (No Mipmap)
        IMAGE_FORMAT_DXT1,  # lowResImageFormat = DXT1 (13)
        16,  # lowResWidth
        16,  # lowResHeight
        1,  # depth = 1
        b"\x00" * 15,
    )
    assert len(header) == 80, f"Tamaño de cabecera VTF inesperado: {len(header)}"

    thumb_bytes = encode_dxt1_16x16_thumbnail(img_rgba)
    assert len(thumb_bytes) == 128

    raw_rgba = arr.tobytes()
    assert len(raw_rgba) == 1024 * 1024 * 4

    os.makedirs(os.path.dirname(dst_vtf_path), exist_ok=True)
    with open(dst_vtf_path, "wb") as f:
        f.write(header)
        f.write(thumb_bytes)
        f.write(raw_rgba)


def measure_mp3_exact_duration(mp3_path: str) -> tuple[float, set, set]:
    """Mide la duración exacta por conteo de muestras MPEG1 Layer III."""
    BITRATES_V1_L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    SRATES_V1 = [44100, 48000, 32000, 0]
    with open(mp3_path, "rb") as f:
        data = f.read()
    pos = 0
    if data[:3] == b"ID3":
        flags = data[5]
        sz = (
            ((data[6] & 0x7F) << 21)
            | ((data[7] & 0x7F) << 14)
            | ((data[8] & 0x7F) << 7)
            | (data[9] & 0x7F)
        )
        pos = 10 + sz + (10 if (flags & 0x10) else 0)
    end = len(data) - (128 if len(data) >= 128 and data[-128:-125] == b"TAG" else 0)
    total_samples = 0
    srates = set()
    bitrates = set()
    frames = 0
    while pos + 4 <= end:
        if data[pos] == 0xFF and (data[pos + 1] & 0xE0) == 0xE0:
            b1, b2 = data[pos + 1], data[pos + 2]
            ver = (b1 >> 3) & 0x03
            layer = (b1 >> 1) & 0x03
            br_idx = (b2 >> 4) & 0x0F
            sr_idx = (b2 >> 2) & 0x03
            pad = (b2 >> 1) & 0x01
            if ver == 3 and layer == 1 and 0 < br_idx < 15 and sr_idx < 3:
                sr = SRATES_V1[sr_idx]
                br = BITRATES_V1_L3[br_idx]
                flen = int((144 * br * 1000) // sr + pad)
                if flen > 0 and pos + flen <= len(data) + 4:
                    frame_slice = data[pos : pos + min(flen, 200)]
                    if frames == 0 and (b"Xing" in frame_slice or b"Info" in frame_slice):
                        pos += flen
                        continue
                    frames += 1
                    total_samples += 1152
                    srates.add(sr)
                    bitrates.add(br)
                    pos += flen
                    continue
        pos += 1
    sr_val = next(iter(srates)) if srates else 44100
    return total_samples / float(sr_val), srates, bitrates


def main() -> int:
    os.makedirs(MAT_VOID_DIR, exist_ok=True)
    os.makedirs(SND_VOID_DIR, exist_ok=True)
    os.makedirs(BUILD_PREVIEW_DIR, exist_ok=True)

    print("=== [1/2] Procesando texturas 1024x1024 RGBA y compilando VTF v7.2 ===")
    # face_1_VOID: rostro cauteloso
    face1_rgba = build_rgba_face(
        os.path.join(IMG_SRC_DIR, "face_1_VOID.jpg"),
        target_face_height=820,
        close_rx=68,
        close_ry=96,
        feather_sigma=6.5,
    )
    face1_png = os.path.join(BUILD_PREVIEW_DIR, "face_1_VOID_1024.png")
    face1_vtf = os.path.join(MAT_VOID_DIR, "face_1_VOID.vtf")
    face1_rgba.save(face1_png, "PNG")
    write_vtf_rgba8888(face1_rgba, face1_vtf)
    print(f"  OK -> {face1_vtf} ({os.path.getsize(face1_vtf)} bytes)")

    # face_2_VOID: rostro hiperagresivo (proporción idéntica sin estirar)
    face2_rgba = build_rgba_face(
        os.path.join(IMG_SRC_DIR, "face_2_VOID.jpg"),
        target_face_height=800,
        close_rx=72,
        close_ry=118,
        feather_sigma=6.5,
    )
    face2_png = os.path.join(BUILD_PREVIEW_DIR, "face_2_VOID_1024.png")
    face2_vtf = os.path.join(MAT_VOID_DIR, "face_2_VOID.vtf")
    face2_rgba.save(face2_png, "PNG")
    write_vtf_rgba8888(face2_rgba, face2_vtf)
    print(f"  OK -> {face2_vtf} ({os.path.getsize(face2_vtf)} bytes)")

    # Spawnmenu icon (256x256 con fondo oscuro atmosférico para el menú Q)
    icon_bg = Image.new("RGBA", (256, 256), (8, 8, 10, 255))
    icon_fg = face1_rgba.resize((240, 240), Image.Resampling.LANCZOS)
    icon_bg.alpha_composite(icon_fg, (8, 8))
    icon_path = os.path.join(MAT_ENT_DIR, "npc_void.png")
    icon_bg.save(icon_path, "PNG")
    print(f"  OK -> {icon_path} (Spawnicon 256x256)")

    print("\n=== [2/2] Masterizando y transcodificando audios a MP3 44100 Hz CBR 192 kbps ===")
    ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
    # (src_name, dst_name, gain_db, trim_both_ends_for_loop)
    audio_map = [
        ("sonido_fondo_VOID.mp3", "sonido_fondo_VOID.mp3", 5.0, True),
        ("sonido_persecución_VOID.mp3", "sonido_persecucion_VOID.mp3", 2.0, True),
        ("sonido_hiperagresividad_VOID.mp3", "sonido_hiperagresividad_VOID.mp3", 10.5, True),
        ("grito_hiperagresividad_VOID.mp3", "grito_hiperagresividad_VOID.mp3", 4.5, False),
        ("stalking_lento_sonido_VOID.mp3", "stalking_lento_sonido_VOID.mp3", 12.0, True),
        ("sonido_aleatorio_1__VOID.mp3", "sonido_aleatorio_1_VOID.mp3", 9.5, False),
        ("sonido_aleatorio_2__VOID.mp3", "sonido_aleatorio_2_VOID.mp3", 10.0, False),
        ("sonido_aleatorio_3__VOID.mp3", "sonido_aleatorio_3_VOID.mp3", 7.0, False),
        ("sonido_aleatorio_4__VOID.mp3", "sonido_aleatorio_4_VOID.mp3", 7.0, False),
        ("sonido_aleatorio_5__VOID.mp3", "sonido_aleatorio_5_VOID.mp3", 8.5, False),
        ("sonido_aleatorio_6__VOID.mp3", "sonido_aleatorio_6_VOID.mp3", 3.0, False),
    ]

    for src_name, dst_name, gain_db, trim_loop in audio_map:
        src_p = os.path.join(SND_SRC_DIR, src_name)
        dst_p = os.path.join(SND_VOID_DIR, dst_name)
        tmp_p = dst_p + ".tmp.mp3"
        if not os.path.exists(src_p):
            raise FileNotFoundError(f"No existe el audio original: {src_p}")

        if trim_loop:
            af_chain = (
                "silenceremove=start_periods=1:start_threshold=-42dB,"
                "areverse,silenceremove=start_periods=1:start_threshold=-42dB,areverse,"
                f"volume={gain_db}dB,"
                "alimiter=level_in=1:level_out=0.98:limit=0.98:attack=5:release=50:level=disabled"
            )
        else:
            af_chain = (
                "silenceremove=start_periods=1:start_threshold=-44dB,"
                f"volume={gain_db}dB,"
                "alimiter=level_in=1:level_out=0.98:limit=0.98:attack=5:release=50:level=disabled"
            )

        cmd = [
            ffmpeg_exe,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            src_p,
            "-vn",
            "-af",
            af_chain,
            "-ar",
            "44100",
            "-ac",
            "2",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "192k",
            "-write_xing",
            "0",
            "-id3v2_version",
            "0",
            tmp_p,
        ]
        subprocess.run(cmd, check=True)
        os.replace(tmp_p, dst_p)
        dur, srates, bitrates = measure_mp3_exact_duration(dst_p)
        print(
            f"  OK -> {dst_name:<35} | dur={dur:7.3f}s | gain=+{gain_db:<4.1f}dB | sr={srates} | br={bitrates}kbps"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())

