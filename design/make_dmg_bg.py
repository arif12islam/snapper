from PIL import Image, ImageDraw, ImageFont
S = 2
W, H = 660 * S, 400 * S
img = Image.new("RGB", (W, H))
px = img.load()
top, bot = (245, 246, 252), (226, 228, 244)
for y in range(H):
    t = y / (H - 1)
    c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
    for x in range(W):
        px[x, y] = c
d = ImageDraw.Draw(img)
navy = (27, 27, 77)
muted = (110, 112, 150)
def font(name, size):
    return ImageFont.truetype(f"/usr/share/fonts/opentype/inter/{name}", size * S)
f_title = font("Inter-SemiBold.otf", 20)
f_small = font("Inter-Regular.otf", 12)
def centered(text, y, f, fill):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y * S), text, font=f, fill=fill)
centered("Drag Snapper to Applications", 38, f_title, navy)
centered("Built by Bykorp", 356, f_small, muted)
# arrow between the two icons (icons sit at x=180 and x=480, y=190)
y = 185 * S
x0, x1 = 258 * S, 402 * S
d.line([(x0, y), (x1 - 14 * S, y)], fill=navy, width=4 * S)
d.polygon([(x1, y), (x1 - 22 * S, y - 13 * S), (x1 - 22 * S, y + 13 * S)], fill=navy)
img.save("design/dmg-background.png", dpi=(144, 144))
