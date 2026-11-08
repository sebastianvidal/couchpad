import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# App Store screenshots at the 6.9" size: 1320x2868. Gradient background, caption on top,
# the real screenshot below with rounded corners and a soft shadow.
SHOTS = sys.argv[1]
OUT = sys.argv[2]
# Canvas size: "large" = 6.9" iPhone (1320x2868), "medium" = 6.3" iPhone (1206x2622).
SIZE = sys.argv[3] if len(sys.argv) > 3 else "large"
W, H = {"large": (1320, 2868), "medium": (1206, 2622)}[SIZE]
S = W / 1320  # scale factor for type and spacing, designed at the large size
os.makedirs(OUT, exist_ok=True)

# Raw captures expected in <raw dir>: 1-controller.png (the pad under the Mac's picture),
# 2-main.png (trackpad, key row, bar), 3-picture.png (the picture on the trackpad, pad off),
# 4-pairing.png, 5-setup.png, 6-settings.png. A missing raw is skipped, so a set can leave
# one out (the 6.9" set has no 3-picture.png: that simulator isn't paired).
captions = [
    ("1-controller.png", "01-controller.png", "Your iPhone is\nthe controller",           "A stick, A B X Y and seven keys you bind."),
    ("2-main.png",       "02-trackpad.png",   "Your iPhone is the\ntrackpad and keyboard", "With esc, tab, fn, the modifiers and F1–F12."),
    ("3-picture.png",    "03-picture.png",    "The Mac's screen,\non your iPhone",        "The trackpad keeps working on top of it."),
    ("4-pairing.png",    "04-pairing.png",    "Pair once, with a\ncode or a QR",           "Only a paired iPhone can send input."),
    ("5-setup.png",      "05-setup.png",      "Set up in three steps",                      "Free companion app for Mac and Windows."),
    ("6-settings.png",   "06-settings.png",   "Tune it to your couch",                      "Pointer speed, gestures, controller bindings."),
]

def font(size, bold=False):
    for path in (["/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold else ["/System/Library/Fonts/Supplemental/Arial.ttf"]):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()

def gradient():
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (28, 30, 44), (14, 15, 20)
    accent = (82, 72, 220)
    for y in range(H):
        t = y / H
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(W):
            px[x, y] = (r, g, b)
    # A soft accent glow behind the caption.
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-200, int(-500 * S), W + 200, int(700 * S)), fill=accent)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    return Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: min(255, v * 2))), 0.35)

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out

for src, dst, headline, sub in captions:
    path = os.path.join(SHOTS, src)
    if not os.path.exists(path):
        print("missing", src); continue
    canvas = gradient().convert("RGBA")
    d = ImageDraw.Draw(canvas)
    y = int(170 * S)
    for line in headline.split("\n"):
        f = font(int(92 * S), bold=True)
        w = d.textlength(line, font=f)
        d.text(((W - w) / 2, y), line, font=f, fill=(245, 245, 250))
        y += int(108 * S)
    f = font(int(44 * S))
    w = d.textlength(sub, font=f)
    d.text(((W - w) / 2, y + int(14 * S)), sub, font=f, fill=(170, 172, 190))

    shot = Image.open(path).convert("RGB")
    target_w = int(W * 0.78)
    scale = target_w / shot.width
    shot = shot.resize((target_w, int(shot.height * scale)), Image.LANCZOS)
    shot = rounded(shot, int(110 * S))
    x = (W - shot.width) // 2
    top = y + int(150 * S)
    # Shadow.
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((x + 10, top + 40, x + shot.width - 10, top + shot.height + 40), radius=int(110 * S), fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(50))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(shot, (x, top))
    # Crop at the bottom edge: the phone runs off the canvas, a common App Store look.
    canvas = canvas.crop((0, 0, W, H)).convert("RGB")
    canvas.save(os.path.join(OUT, dst), "PNG", optimize=True)
    print("wrote", dst, canvas.size)
