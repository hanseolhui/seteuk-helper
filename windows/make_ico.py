# PNG 여러 크기를 담은 .ico 만들기 (표준 라이브러리만)
import struct, subprocess, sys, tempfile, os
src, out = sys.argv[1], sys.argv[2]
sizes = [16, 24, 32, 48, 64, 128, 256]
tmp = tempfile.mkdtemp()
blobs = []
for s in sizes:
    p = os.path.join(tmp, "%d.png" % s)
    subprocess.run(["sips", "-z", str(s), str(s), src, "--out", p], capture_output=True, check=True)
    blobs.append(open(p, "rb").read())
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, blobs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(out, "wb").write(header + entries + b"".join(blobs))
