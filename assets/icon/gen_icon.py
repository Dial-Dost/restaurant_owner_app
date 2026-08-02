# Restaurant Dash app icon generator.
# Design: white hotel/service bell with speed dashes on a warm orange gradient
# rounded square (brand accent #ea580c). Drawn at 4x and downsampled for AA.
from PIL import Image, ImageDraw, ImageFilter
import os

SS = 4          # supersample factor
SIZE = 1024
S = SIZE * SS

OUT_DIR = r"C:\Users\mechi\Downloads\Restaurant Dash\restaurant_owner_app\assets\icon"
os.makedirs(OUT_DIR, exist_ok=True)

# ---- palette ----
GRAD_TOP = (251, 146, 60)    # #fb923c
GRAD_BOT = (194, 65, 12)     # #c2410c
WHITE = (255, 255, 255, 255)
DASH = (255, 255, 255, 235)
ARC = (255, 255, 255, 210)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_gradient_bg():
    """Vertical gradient masked to a rounded square."""
    grad = Image.new("RGB", (1, S))
    px = grad.load()
    for y in range(S):
        px[0, y] = lerp(GRAD_TOP, GRAD_BOT, y / (S - 1))
    grad = grad.resize((S, S))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=232 * SS, fill=255)
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bg.paste(grad, (0, 0), mask)
    return bg


def T(pts, scale=1.0, dx=0, dy=0):
    """Transform base-space (1024) coords: scale about center, offset, then SS."""
    out = []
    for i in range(0, len(pts), 2):
        x = (512 + (pts[i] - 512) * scale + dx) * SS
        y = (512 + (pts[i + 1] - 512) * scale + dy) * SS
        out += [x, y]
    return out


def draw_bell(img, scale=1.0, dx=0, dy=0, with_shadow=True):
    d = ImageDraw.Draw(img)
    if with_shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).ellipse(T([320, 700, 704, 752], scale, dx, dy), fill=(0, 0, 0, 42))
        sh = sh.filter(ImageFilter.GaussianBlur(14 * SS * scale))
        img.alpha_composite(sh)
        d = ImageDraw.Draw(img)
    # dome (upper half-disc)
    d.pieslice(T([276, 360, 748, 832], scale, dx, dy), 180, 360, fill=WHITE)
    # knob on top (overlaps dome apex so they connect)
    d.ellipse(T([470, 280, 554, 364], scale, dx, dy), fill=WHITE)
    # base tray
    d.rounded_rectangle(T([288, 622, 736, 670], scale, dx, dy), radius=24 * SS * scale, fill=WHITE)
    # speed dashes (left, staggered lengths)
    for box in ([128, 470, 252, 514], [156, 560, 252, 604], [184, 650, 252, 694]):
        d.rounded_rectangle(T(box, scale, dx, dy), radius=22 * SS * scale, fill=DASH)
    # ring arcs off the knob (up-right)
    d.arc(T([402, 212, 622, 432], scale, dx, dy), start=-70, end=-15, fill=ARC, width=int(16 * SS * scale))
    d.arc(T([352, 162, 672, 482], scale, dx, dy), start=-64, end=-21, fill=ARC, width=int(16 * SS * scale))


# ---- master icon (gradient bg + bell) ----
master = rounded_gradient_bg()
draw_bell(master, 1.0, 0, 0, with_shadow=True)
master = master.resize((SIZE, SIZE), Image.LANCZOS)
master.save(os.path.join(OUT_DIR, "app_icon.png"))

# ---- iOS variant: full-bleed square (iOS masks its own corners, no alpha allowed) ----
grad = Image.new("RGB", (1, S))
px = grad.load()
for y in range(S):
    px[0, y] = lerp(GRAD_TOP, GRAD_BOT, y / (S - 1))
ios = grad.resize((S, S)).convert("RGBA")
draw_bell(ios, 1.0, 0, 0, with_shadow=True)
ios = ios.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
ios.save(os.path.join(OUT_DIR, "app_icon_ios.png"))

# ---- Android adaptive foreground: bell only, scaled into the ~66% safe zone ----
fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
draw_bell(fg, 0.62, 0, 6, with_shadow=False)
fg = fg.resize((SIZE, SIZE), Image.LANCZOS)
fg.save(os.path.join(OUT_DIR, "app_icon_foreground.png"))

print("written:", os.listdir(OUT_DIR))
