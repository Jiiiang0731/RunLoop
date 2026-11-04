# -*- coding: utf-8 -*-
"""从 icon/RunLoop.ico 生成 Android 全套启动图标（阶段 L 模块 0）。

原则（用户明确要求）：
- 唯一源文件 icon/RunLoop.ico（取 256×256 最高分辨率帧）；
- 不重新设计、不裁切图案、不拉伸变形、不加装饰；
- 等比缩放 + 居中；Adaptive 前景把图案本体放入 66/108 安全区，
  背景层为纯白（与原图白底无缝衔接，任何掩码形状下图案完整）。

产物：
- res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png         传统方形（全图缩放）
- res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher_round.png   传统圆形（内切圆裁切，图案在圆内已验证安全）
- res/drawable-{m,h,xh,xxh,xxxh}dpi/ic_launcher_foreground.png  Adaptive 前景（透明底，图案入安全区）
- res/drawable/ic_launcher_background.xml                 Adaptive 背景（纯白）
- res/mipmap-anydpi-v26/ic_launcher.xml / ic_launcher_round.xml

用法：python tools/gen_icons.py
"""
from PIL import Image, ImageDraw
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICO = os.path.join(ROOT, 'icon', 'RunLoop.ico')
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')

DENSITIES = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0}
LEGACY_DP = 48          # 传统图标 48dp
ADAPTIVE_DP = 108       # Adaptive 画布 108dp
SAFE_RATIO = 66 / 108   # Adaptive 安全区 66dp
ART_BBOX = (57, 57, 199, 199)  # 非白图案包围盒（像素分析实测，(57,57)-(198,198) 含界）


def load_source():
    im = Image.open(ICO)
    im.size = (256, 256)
    im.load()
    return im.convert('RGBA')


def circle_crop(img: Image.Image) -> Image.Image:
    """内切圆裁切（4x 超采样抗锯齿），圆外透明。"""
    s = img.size[0]
    mask = Image.new('L', (s * 4, s * 4), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((0, 0, s * 4, s * 4), fill=255)
    mask = mask.resize((s, s), Image.LANCZOS)
    out = img.copy()
    out.putalpha(mask)
    return out


def main():
    src = load_source()

    for name, scale in DENSITIES.items():
        # ---- 传统方形/圆形 ----
        legacy_size = round(LEGACY_DP * scale)
        legacy = src.resize((legacy_size, legacy_size), Image.LANCZOS)
        mdir = os.path.join(RES, 'mipmap-%s' % name)
        os.makedirs(mdir, exist_ok=True)
        legacy.save(os.path.join(mdir, 'ic_launcher.png'))
        circle_crop(legacy).save(os.path.join(mdir, 'ic_launcher_round.png'))

        # ---- Adaptive 前景 ----
        canvas = round(ADAPTIVE_DP * scale)
        art = src.crop(ART_BBOX)
        art_size = round(canvas * SAFE_RATIO)
        art = art.resize((art_size, art_size), Image.LANCZOS)
        fg = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
        off = (canvas - art_size) // 2
        fg.paste(art, (off, off), art)
        ddir = os.path.join(RES, 'drawable-%s' % name)
        os.makedirs(ddir, exist_ok=True)
        fg.save(os.path.join(ddir, 'ic_launcher_foreground.png'))
        print('%-8s legacy %dpx  round %dpx  foreground %dpx(art %dpx)'
              % (name, legacy_size, legacy_size, canvas, art_size))

    # ---- Adaptive 背景（纯白）与 anydpi XML ----
    ddir = os.path.join(RES, 'drawable')
    os.makedirs(ddir, exist_ok=True)
    with open(os.path.join(ddir, 'ic_launcher_background.xml'), 'w', encoding='utf-8') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n'
                '<shape xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    android:shape="rectangle">\n'
                '    <solid android:color="#FFFFFFFF" />\n'
                '</shape>\n')
    adir = os.path.join(RES, 'mipmap-anydpi-v26')
    os.makedirs(adir, exist_ok=True)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@drawable/ic_launcher_background" />\n'
           '    <foreground android:drawable="@drawable/ic_launcher_foreground" />\n'
           '</adaptive-icon>\n')
    for fname in ('ic_launcher.xml', 'ic_launcher_round.xml'):
        with open(os.path.join(adir, fname), 'w', encoding='utf-8') as f:
            f.write(xml)
    print('background.xml + anydpi-v26 XML written')


if __name__ == '__main__':
    main()
