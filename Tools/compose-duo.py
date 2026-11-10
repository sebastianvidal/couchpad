import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# iPhone Duo App Store screenshots. Apple wants the outer display at 1398x2034 and the inner
# display at 2007x2853, each in both orientations. Raw captures come from
# `xcrun simctl io <duo> screenshot --display=<1 outer | 3 inner>` and are already at the
# display's native size, so each render shows the capture on the same gradient as the phone
# set, scaled to leave room for a caption.
#
#   python3 Tools/compose-duo.py <raw dir> <out dir>
#
# Raw files expected (on-screen controller and the Mac's picture on): outer-portrait.png,
# outer-landscape.png, inner-portrait.png, inner-landscape.png (all four fully open or
# closed), inner-half-open.png (Device Hub's "Partially Open": split at the hinge).
SHOTS, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)

renders = [
    # (raw, out, canvas (w, h), headline, sub)
    ("outer-portrait.png",  "duo-outer-01-portrait.png",  (1398, 2034), "The controller, folded",       "Picture, stick and keys on the cover display."),
    ("outer-landscape.png", "duo-outer-02-landscape.png", (2034, 1398), "Sideways, folded",             "The controller floats over the picture."),
    ("inner-portrait.png",  "duo-inner-01-portrait.png",  (2007, 2853), "Unfold for a\nbigger picture", "The controller takes the bottom half, like a console."),
    ("inner-landscape.png", "duo-inner-02-landscape.png", (2853, 2007), "Unfolded, sideways",           "Stick on the left, A B X Y on the right."),
    ("inner-half-open.png", "duo-inner-03-half-open.png", (2007, 2853), "Half open, a\nhand-held console", "The picture stands up; the controller lies flat."),
]

def font(size, bold=False):
    path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf"
    return ImageFont.truetype(path, size) if os.path.exists(path) else ImageFont.load_default()

def gradient(W, H):
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (28, 30, 44), (14, 15, 20)
    for y in range(H):
        t = y / H
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = c
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W * 0.2, -H * 0.3, W * 0.8, H * 0.3), fill=(82, 72, 220))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.12))
    return Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: min(255, v * 2))), 0.35)

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out

for src, dst, (W, H), headline, sub in renders:
    path = os.path.join(SHOTS, src)
    if not os.path.exists(path):
        print("missing", src); continue
    shot = Image.open(path).convert("RGB")
    landscape = W > H
    # Type scales with the short side so the two display sizes read alike.
    S = min(W, H) / 1398
    canvas = gradient(W, H).convert("RGBA")
    d = ImageDraw.Draw(canvas)
    f = font(int(74 * S), bold=True)
    y = int(90 * S)
    for line in headline.split("\n"):
        w = d.textlength(line, font=f)
        d.text(((W - w) / 2, y), line, font=f, fill=(245, 245, 250))
        y += int(84 * S)
    f2 = font(int(38 * S))
    w = d.textlength(sub, font=f2)
    d.text(((W - w) / 2, y + int(8 * S)), sub, font=f2, fill=(170, 172, 190))
    top = y + int(90 * S)

    # Fit the capture below the caption, keeping its aspect, with a margin.
    avail_w, avail_h = W - int(120 * S), H - top - int(90 * S)
    scale = min(avail_w / shot.width, avail_h / shot.height)
    shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
    x = (W - shot.width) // 2
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x - 10, top + 20, x + shot.width + 10, top + shot.height + 50), radius=int(70 * S), fill=(0, 0, 0, 170))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(45 * S)))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(rounded(shot, int(60 * S)), (x, top))
    canvas.convert("RGB").save(os.path.join(OUT, dst), "PNG", optimize=True)
    print("wrote", dst, f"{W}x{H}")
