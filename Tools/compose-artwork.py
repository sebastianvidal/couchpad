import sys, os
from PIL import Image, ImageCms, ImageDraw, ImageFilter

# App Store Connect creative assets (Product Page Information > Header and Search Results):
#   product page header  21:9, exactly 3840x1646
#   search results        3:2, 1920x1280 up to 3840x2560 (rendered at the maximum)
# PNG/JPEG, no alpha. Apple's spec page gives no pixel safe area (that lives in its design
# templates); its best practices say to keep the focal point in the centre so nothing is
# clipped, so the devices sit in the middle with wide margins. No text: it is optional, and
# the safe areas for it are only in Apple's design templates (see docs/app-store-copy.md).
#
#   python3 Tools/compose-artwork.py <raw dir> <out dir>
#
# Raw captures expected (simctl screenshots, status bar hidden by the app, Mac's picture on
# and the on-screen controller up): pro-pad-picture.png (6.3" iPhone, portrait, 1206x2622)
# and duo-open-land-pad-picture.png (iPhone Duo inner display, unfolded sideways, 2853x2007).
SHOTS, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
PHONE = "pro-pad-picture.png"
DUO = "duo-open-land-pad-picture.png"

def gradient(W, H):
    # Same navy gradient and indigo glow as the screenshot sets (compose-duo.py), built a row
    # at a time because these canvases are 10 megapixels.
    top, bottom = (28, 30, 44), (14, 15, 20)
    col = Image.new("RGB", (1, H))
    px = col.load()
    for y in range(H):
        t = y / H
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    img = col.resize((W, H))
    glow = Image.new("RGB", (W // 4, H // 4), (0, 0, 0))
    w, h = glow.size
    ImageDraw.Draw(glow).ellipse((w * 0.2, -h * 0.35, w * 0.8, h * 0.45), fill=(82, 72, 220))
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.16)).resize((W, H), Image.BICUBIC)
    return Image.blend(img, Image.composite(glow, img, glow.convert("L").point(lambda v: min(255, v * 2))), 0.35)

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius=radius, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out

def place(canvas, shot, height, cx, cy, radius_frac):
    """Scale `shot` to `height`, centre it on (cx, cy) with rounded corners, a hairline edge
    (the site's --border) and the soft drop shadow the screenshots use."""
    s = height / shot.height
    shot = shot.resize((round(shot.width * s), round(height)), Image.LANCZOS)
    r = round(min(shot.size) * radius_frac)
    x, y = round(cx - shot.width / 2), round(cy - shot.height / 2)
    u = height / 2000  # shadow and edge scale with the device
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x + 10 * u, y + 60 * u, x + shot.width - 10 * u, y + shot.height + 60 * u), radius=r, fill=(0, 0, 0, 175))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(80 * u)))
    edge = max(2, round(5 * u))
    rim = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((x - edge, y - edge, x + shot.width - 1 + edge, y + shot.height - 1 + edge),
                                          radius=r + edge, fill=(52, 55, 74, 255))
    canvas = Image.alpha_composite(canvas, rim)
    canvas.alpha_composite(rounded(shot, r), (x, y))
    return canvas

def render(W, H, row, gap, name, cy=0.5):
    """Lay `row` out left to right, each (raw, height as a share of H, corner radius as a share
    of its short side), `gap` (share of W) apart, the whole group centred on the canvas."""
    canvas = gradient(W, H).convert("RGBA")
    shots = [(Image.open(os.path.join(SHOTS, src)).convert("RGB"), h * H, r) for src, h, r in row]
    widths = [im.width * h / im.height for im, h, _ in shots]
    x = (W - sum(widths) - gap * W * (len(shots) - 1)) / 2
    for (im, h, r), w in zip(shots, widths):
        canvas = place(canvas, im, h, x + w / 2, cy * H, r)
        x += w + gap * W
    out = canvas.convert("RGB")  # no alpha channel allowed
    path = os.path.join(OUT, name)
    # The simulator captures are untagged sRGB; say so explicitly in the output.
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    out.save(path, "PNG", optimize=True, icc_profile=srgb)
    print("wrote", name, f"{W}x{H}", f"{os.path.getsize(path) / 1e6:.1f} MB")

# Corner radius as a share of the short side. The phone's matches the screenshot sets (110 px
# on a 1029 px wide shot). Heights keep the two displays at roughly their real relative size
# (the Duo's inner display is 2007 px tall sideways, the phone 2622 px upright, same density).
PHONE_R, DUO_R = 0.107, 0.045

# Header: the phone, then the unfolded Duo sideways, side by side as one centred group.
render(3840, 1646, [(PHONE, 0.78, PHONE_R), (DUO, 0.60, DUO_R)], 0.035, "app-store-header.png")

# Search results: the same pair; it is shown small, so the devices fill more of the canvas
# while keeping about a tenth of each side clear.
render(3840, 2560, [(PHONE, 0.72, PHONE_R), (DUO, 0.55, DUO_R)], 0.035, "app-store-search.png")
