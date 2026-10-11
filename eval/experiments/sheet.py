import sys
from PIL import Image, ImageDraw
d0 = sys.argv[1]; names = sys.argv[2].split(","); labels = sys.argv[3].split(","); out = sys.argv[4]
ims = [Image.open(f"{d0}/{n}.png") for n in names]
W, H = ims[0].size; sheet = Image.new("RGB", (W * 2, H * 2), "white")
for i, im in enumerate(ims): sheet.paste(im, ((i % 2) * W, (i // 2) * H))
d = ImageDraw.Draw(sheet)
for i, t in enumerate(labels): d.text(((i % 2) * W + 10, (i // 2) * H + 10), t, fill=(0, 0, 0))
sheet.save(out)
