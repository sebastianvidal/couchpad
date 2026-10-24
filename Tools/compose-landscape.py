import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# Landscape renders (2868x1320, the 6.9" iPhone landscape size): the app screenshot inside a
# stylised handheld-controller shell — grips either side with a stick, d-pad and face
# buttons — on the same gradient as the portrait set. Raw captures are simctl screenshots
# taken while the simulator was rotated, so they arrive portrait-oriented and get rotated.
W, H = 2868, 1320
SHOTS, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)

captions = [
    ("a-main.png",  "01-landscape.png",       "Sideways, with a controller",    "Trackpad on one side, keys and mouse buttons on the other."),
    ("b-fkeys.png", "02-landscape-fkeys.png", "F1–F12 one tap away",             "The key block never moves when the keyboard comes up."),
    ("c-right.png", "03-landscape-right.png", "Trackpad left or right",          "Pick the side that suits your thumb."),
]

def font(size, bold=False):
    path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf"
    return ImageFont.truetype(path, size) if os.path.exists(path) else ImageFont.load_default()

def gradient():
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (28, 30, 44), (14, 15, 20)
    for y in range(H):
        t = y / H
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(W):
            px[x, y] = c
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse((W * 0.2, -600, W * 0.8, 500), fill=(82, 72, 220))
    glow = glow.filter(ImageFilter.GaussianBlur(200))
    return Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: min(255, v * 2))), 0.35)

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out

def controller_shell(phone_box):
    """Grips and controls around the phone rectangle, drawn as flat shapes."""
    x0, y0, x1, y1 = phone_box
    shell = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(shell)
    grip_w, overlap = 330, 40
    body = (36, 37, 46, 255); edge = (58, 60, 74, 255); face = (70, 72, 88, 255); light = (120, 124, 150, 255)
    for side in ("L", "R"):
        if side == "L":
            gx0, gx1 = x0 - grip_w, x0 + overlap
        else:
            gx0, gx1 = x1 - overlap, x1 + grip_w
        gy0, gy1 = y0 - 30, y1 + 30
        d.rounded_rectangle((gx0, gy0, gx1, gy1), radius=150, fill=body, outline=edge, width=4)
        cx = gx0 + grip_w * 0.5 if side == "L" else gx1 - grip_w * 0.5
        if side == "L":
            # Stick on top, d-pad below.
            d.ellipse((cx - 85, y0 + 150, cx + 85, y0 + 320), fill=face, outline=edge, width=4)
            d.ellipse((cx - 55, y0 + 180, cx + 55, y0 + 290), fill=light)
            dy = y1 - 300
            d.rounded_rectangle((cx - 28, dy - 95, cx + 28, dy + 95), radius=12, fill=face)
            d.rounded_rectangle((cx - 95, dy - 28, cx + 95, dy + 28), radius=12, fill=face)
        else:
            # Face buttons on top (diamond), stick below.
            by = y0 + 240
            for (ox, oy) in ((0, -85), (85, 0), (0, 85), (-85, 0)):
                d.ellipse((cx + ox - 38, by + oy - 38, cx + ox + 38, by + oy + 38), fill=face, outline=edge, width=3)
            sy = y1 - 300
            d.ellipse((cx - 85, sy - 85, cx + 85, sy + 85), fill=face, outline=edge, width=4)
            d.ellipse((cx - 55, sy - 55, cx + 55, sy + 55), fill=light)
    return shell

for src, dst, headline, sub in captions:
    path = os.path.join(SHOTS, src)
    if not os.path.exists(path):
        print("missing", src); continue
    shot = Image.open(path).convert("RGB")
    if shot.height > shot.width:
        shot = shot.rotate(90, expand=True)  # the simulator captures the framebuffer upright
    canvas = gradient().convert("RGBA")
    d = ImageDraw.Draw(canvas)
    f = font(64, bold=True)
    w = d.textlength(headline, font=f)
    d.text(((W - w) / 2, 70), headline, font=f, fill=(245, 245, 250))
    f2 = font(34)
    w = d.textlength(sub, font=f2)
    d.text(((W - w) / 2, 150), sub, font=f2, fill=(170, 172, 190))

    target_w = int(W * 0.60)
    scale = target_w / shot.width
    shot = shot.resize((target_w, int(shot.height * scale)), Image.LANCZOS)
    x = (W - shot.width) // 2
    top = 230
    box = (x, top, x + shot.width, top + shot.height)
    shell = controller_shell(box)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((box[0] - 330, box[1] - 20, box[2] + 330, box[3] + 60), radius=150, fill=(0, 0, 0, 160))
    shadow = shadow.filter(ImageFilter.GaussianBlur(45))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, shell)
    canvas.alpha_composite(rounded(shot, 70), (x, top))
    canvas.convert("RGB").save(os.path.join(OUT, dst), "PNG", optimize=True)
    print("wrote", dst)
