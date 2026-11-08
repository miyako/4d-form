#!/usr/bin/env python3
"""Exercise the actual standalone binary, not an HTML-only proxy."""
import binascii
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parent.parent


def decode_png(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "Not a PNG"
    offset, compressed, dimensions, ended = 8, bytearray(), None, False
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        crc = struct.unpack(">I", data[offset + 8 + length:offset + 12 + length])[0]
        assert binascii.crc32(kind + payload) & 0xFFFFFFFF == crc, "PNG CRC mismatch"
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            assert depth == 8 and color == 6 and compression == filtering == interlace == 0
            dimensions = width, height
        if kind == b"IDAT":
            compressed.extend(payload)
        if kind == b"IEND":
            ended = True
        offset += length + 12
    assert ended and dimensions and offset == len(data)
    width, height = dimensions
    assert 1 <= width <= 4096 and 1 <= height <= 4096
    raw = zlib.decompress(compressed)
    stride = width * 4
    assert len(raw) == height * (stride + 1), "Incomplete PNG raster"
    rows, prior = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        method = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        assert method in range(5)
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            up = prior[x]
            corner = prior[x - 4] if x >= 4 else 0
            prediction = 0
            if method == 1:
                prediction = left
            elif method == 2:
                prediction = up
            elif method == 3:
                prediction = (left + up) // 2
            elif method == 4:
                p = left + up - corner
                distances = abs(p - left), abs(p - up), abs(p - corner)
                prediction = (left, up, corner)[distances.index(min(distances))]
            row[x] = (row[x] + prediction) & 255
        rows.append(row)
        prior = row
    return dimensions, rows


def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob("*") if p.is_file()}


def main():
    executable = Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "release.json").read_text())
    version = subprocess.check_output([str(executable), "--version"], text=True).strip()
    assert version == "fourdform " + manifest["version"]
    assert manifest["tag"] == "v" + manifest["version"]
    assert "--max-dimension" in subprocess.check_output([str(executable), "--help"], text=True)
    with tempfile.TemporaryDirectory(prefix="fourdform-smoke-") as name:
        work = Path(name)
        binary = work / "fourdform"
        shutil.copy2(executable, binary)
        shutil.copy2(ROOT / "Tests/FormImageTests/Fixtures/simple.4DForm", work / "simple.4DForm")
        environment = {**os.environ, "PATH": ""}

        def run(*args, status=0):
            result = subprocess.run([str(binary), *map(str, args)], cwd=work, env=environment,
                                    capture_output=True, text=True, timeout=45)
            assert result.returncode == status, (args, result.returncode, result.stderr)
            if status:
                assert "error:" in result.stderr
            return result

        before = hashes(work)
        run("simple.4DForm", "-o", "first.png")
        dimensions, rows = decode_png(work / "first.png")
        assert dimensions == (240, 160)
        assert rows[20][80:84] == bytes([255, 0, 0, 255]), "Paint origin/common-page geometry"
        run("simple.4DForm", "-o", "again.png")
        assert (work / "first.png").read_bytes() == (work / "again.png").read_bytes()
        run("simple.4DForm", "-o", "scaled.png", "--scale", 2)
        assert decode_png(work / "scaled.png")[0] == (480, 320)
        run("simple.4DForm", "-o", "bounded.png", "--scale", 4, "--max-dimension", 120)
        assert decode_png(work / "bounded.png")[0] == (120, 80)
        for theme in ("classic-light", "classic-dark", "liquid-glass-light", "liquid-glass-dark"):
            run("simple.4DForm", "--theme", theme, "-o", theme + ".png")
            assert decode_png(work / (theme + ".png"))[0] == (240, 160)
        assert (work / "classic-light.png").read_bytes() != (work / "classic-dark.png").read_bytes()
        run("simple.4DForm", "--page", 2, "-o", "page2.png")
        _, page2 = decode_png(work / "page2.png")
        assert page2[110][440:444] == bytes([0, 255, 0, 255]), "Selected page geometry"
        assert rows[110][440:444] != page2[110][440:444]
        clip_form = {"width": 80, "height": 80, "pages": [{"objects": {}}, {"objects": {
            "panel": {"type": "subform", "left": 20, "top": 30, "width": 30, "height": 20,
                      "detailForm": {"pages": [None, {"objects": {
                          "overflow": {"type": "rectangle", "left": -10, "top": 5,
                                       "width": 100, "height": 40, "fill": "#ff0000", "stroke": "#ff0000"}
                      }}]}}
        }}]}
        (work / "clip.4DForm").write_text(json.dumps(clip_form))
        run("clip.4DForm", "-o", "clip.png")
        _, clipped = decode_png(work / "clip.png")
        assert clipped[40][100:104] == bytes([255, 0, 0, 255]), "Subform-local paint"
        for x, y in ((15, 40), (55, 40), (25, 55)):
            assert clipped[y][x * 4:x * 4 + 4] != bytes([255, 0, 0, 255]), "Subform clip overflow"
        run("simple.4DForm", "--page", 99, "-o", "failed.png", status=1)
        assert not (work / "failed.png").exists()
        run("missing.4DForm", status=1)
        (work / "malformed.4DForm").write_text("{")
        run("malformed.4DForm", status=1)
        for args in (("--scale", "nan"), ("--scale", "5"), ("--max-dimension", "4097"),
                     ("--theme", "windows"), ("--page", "-1"), ("--output", "simple.4DForm")):
            run("simple.4DForm", *args, status=2)
        run("simple.4DForm", "-o", "missing-directory/out.png", status=1)
        (work / "forced.4DForm").write_text(json.dumps({"colorScheme": "dark", "pages": [{"objects": {}}, {"objects": {}}]}))
        run("forced.4DForm", "--theme", "classic-light", status=1)
        run("forced.4DForm", "--theme", "classic-dark", "-o", "forced.png")
        decode_png(work / "forced.png")
        assert before["simple.4DForm"] == hashlib.sha256((work / "simple.4DForm").read_bytes()).hexdigest()
        shared = ROOT / ".build/checkouts/4d-ql/Tests/FourDFileKitTests/Fixtures"
        assert shared.is_dir(), "Resolve pinned shared dependency before corpus smoke"
        for project in ("FormStaticProject", "FormBenchmarkProject"):
            shutil.copytree(shared / project, work / project)
            original = hashes(work / project)
            forms = sorted((work / project).glob("Project/Sources/Forms/*/form.4DForm"))
            for index, form in enumerate(forms):
                run(form, "--language", "fr", "-o", f"{project}-{index}.png")
                decode_png(work / f"{project}-{index}.png")
            assert hashes(work / project) == original, "Project source was modified"
        root = work / "FormStaticProject/Project/Sources/Forms/Root/form.4DForm"
        run(root, "--language", "en", "-o", "static-en.png")
        run(root, "--language", "fr", "-o", "static-fr.png")
        assert (work / "static-en.png").read_bytes() != (work / "static-fr.png").read_bytes()
        _, static = decode_png(work / "static-fr.png")
        assert static[100][175 * 4:175 * 4 + 4] == bytes([171, 205, 239, 255]), "Embedded passive picture"
        print("Standalone PNG smoke passed: decode, pixels, dimensions, repeatability, themes/pages, limits, errors and static corpus.")


if __name__ == "__main__":
    main()
