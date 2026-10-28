#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Export the Xiaomi Redmi 5A (riva) main board outline and test pads from the
vendor PCB assembly drawing (88505_1_17_*_pcb.pdf) to DXF, in millimetres.

Writes three files to OUTDIR:
  riva-mainboard-side1.dxf     outline + test pads of sheet 1 (SoC side)
  riva-mainboard-side2.dxf     outline + test pads of sheet 2 (other side),
                               as drawn on sheet 2 (mirror image of side 1)
  riva-mainboard-combined.dxf  side 1 view with both sides' pads on separate
                               layers (side 2 pads mirrored into that view)

Layers: BOARD_OUTLINE, TP_SIDE1, TP_SIDE2, TP_LABELS.
Pads are circles of their nominal diameter (from the schematic), centred on
the pad in the drawing; fiducials and mounting holes are not included.

Scale: the drawing has no scale note. It is calibrated from the test pads
(sheet 1 ~7.05 pt/mm, sheet 2 ~9.1 pt/mm), giving a board of ~45.6 x 35 mm.
Measure the board once and pass --width-mm to make it exact.

Requires: pymupdf, ezdxf  (pip install pymupdf ezdxf)
Usage:    export-board-outline.py PCB.pdf OUTDIR [--width-mm W]
"""
import argparse
import math
import os
import re
import sys

import ezdxf
import pymupdf

SHEETS = {
    1: {"edge_width": 0.51, "pt_per_mm": 7.05},
    2: {"edge_width": 0.65, "pt_per_mm": 9.10},
}

# nominal pad diameter (mm, from the schematic) and function
PADS = {
    "TP29": (0.8, "UART_TX"), "TP30": (0.8, "UART_RX"), "TP12": (0.8, "GND"),
    "TP7": (0.8, "FORCE_USB_BOOT"), "TP9": (0.8, "1V8_VIA_10K"),
    "TP105": (0.8, "WDOG_DISABLE"),
    "TP102": (0.5, "JTAG_RESOUT_N"), "TP103": (0.5, "JTAG_TMS"),
    "TP14": (0.5, "JTAG_TCK"), "TP15": (0.5, "JTAG_TDO"),
    "TP16": (0.5, "JTAG_TDI"), "TP17": (0.5, "JTAG_TRST_N"),
    "TP121": (0.5, "PON_1"), "TP122": (0.5, "PON_RESET_N"),
    "TP123": (0.5, "PS_HOLD"), "TP124": (0.5, "CBLPWR_N"),
    "TP1151": (0.5, "MSM_RESOUT_N"),
    "TP23": (1.0, "VOL_UP"), "TP24": (1.0, "VOL_DOWN"), "TP25": (1.0, "PWR_KEY"),
    "TP36": (1.0, "VBAT"), "TP32": (1.0, "BAT_ID"), "TP31": (1.0, "BAT_THERM"),
    "TP33": (1.0, "GND"), "TP34": (1.0, "GND"),
    "TP5": (1.0, "VBUS"), "TP4": (1.0, "USB_DP"), "TP3": (1.0, "USB_DM"),
    "TP6": (1.0, "USB_ID"), "TP1112": (0.8, "GND"),
    "TP2305": (0.8, "CTP_SCL"), "TP2304": (0.8, "CTP_SDA"),
    "TP2303": (0.8, "CTP_2V8"), "TP2302": (0.8, "CTP_INT_N"),
    "TP2301": (0.8, "CTP_RST_N"), "TP2306": (0.8, "GND"),
    # no size in the schematic: diameter measured on the drawing
    "TP1109": (None, "SD_DET_N"), "TP1203": (None, "GND"),
    "TP18": (0.5, "GRFC5_SEL"), "TP20": (0.5, "GRFC13_SEL"),
}


def flatten(items, steps=12):
    out = []
    for it in items:
        if it[0] == "l":
            out.append([(it[1].x, it[1].y), (it[2].x, it[2].y)])
        elif it[0] == "c":
            p0, p1, p2, p3 = it[1:5]
            pts = []
            for i in range(steps + 1):
                t = i / steps
                a, b, c, d = (1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3
                pts.append((a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                            a * p0.y + b * p1.y + c * p2.y + d * p3.y))
            out.append(pts)
        elif it[0] == "re":
            r = it[1]
            out.append([(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1), (r.x0, r.y0)])
    return out


def chain(segments, tol):
    segs = [list(s) for s in segments if len(s) >= 2]
    close = lambda a, b: math.hypot(a[0] - b[0], a[1] - b[1]) <= tol
    lines = []
    while segs:
        line = segs.pop()
        grown = True
        while grown:
            grown = False
            for i, s in enumerate(segs):
                if close(line[-1], s[0]):
                    line += s[1:]
                elif close(line[-1], s[-1]):
                    line += s[-2::-1]
                elif close(line[0], s[-1]):
                    line = s[:-1] + line
                elif close(line[0], s[0]):
                    line = s[:0:-1] + line
                else:
                    continue
                segs.pop(i)
                grown = True
                break
        lines.append(line)
    return lines


def bbox(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def read_sheet(page, cfg):
    """-> outline points (pt), bbox, {pad: (cx, cy, measured_diameter_pt)}"""
    paths = page.get_drawings()
    edge = [p for p in paths if round(p.get("width") or 0, 2) == cfg["edge_width"]]
    polys = chain([s for p in edge for s in flatten(p["items"])], tol=0.15)
    outline = max(polys, key=lambda pl: (lambda b: (b[2] - b[0]) * (b[3] - b[1]))(bbox(pl)))

    circles = []
    for p in paths:
        it, r = p["items"], p["rect"]
        if len(it) >= 4 and all(i[0] == "c" for i in it) and 1 < r.width < 12 \
                and abs(r.width - r.height) < 0.05 * r.width:
            circles.append(((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2, r.width))
    pads = {}
    for w in page.get_text("words"):
        name = w[4]
        if name not in PADS or name in pads:
            continue
        cx, cy = (w[0] + w[2]) / 2, (w[1] + w[3]) / 2
        c = min(circles, key=lambda c: math.hypot(c[0] - cx, c[1] - cy), default=None)
        if c and math.hypot(c[0] - cx, c[1] - cy) < 3:   # labels sit on their pad
            pads[name] = c
    return outline, bbox(outline), pads


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf")
    ap.add_argument("outdir")
    ap.add_argument("--width-mm", type=float, help="measured board width; fixes the scale")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)

    pdf = pymupdf.open(a.pdf)
    sheets = {}
    for n, cfg in SHEETS.items():
        outline, (x0, y0, x1, y1), pads = read_sheet(pdf[n - 1], cfg)
        ptmm = (x1 - x0) / a.width_mm if a.width_mm else cfg["pt_per_mm"]
        sheets[n] = dict(outline=outline, box=(x0, y0, x1, y1), pads=pads, ptmm=ptmm)

    def to_mm(n, x, y, mirror=False, frame=None):
        """sheet-n point -> mm, origin at the outline's lower-left, y up.
        frame: rescale/mirror into another sheet's outline (for combining)."""
        s = sheets[n]
        x0, y0, x1, y1 = s["box"]
        X, Y = (x - x0) / s["ptmm"], (y1 - y) / s["ptmm"]
        W, H = (x1 - x0) / s["ptmm"], (y1 - y0) / s["ptmm"]
        if mirror:
            X = W - X
        if frame is not None:
            f = sheets[frame]
            fx0, fy0, fx1, fy1 = f["box"]
            X *= ((fx1 - fx0) / f["ptmm"]) / W
            Y *= ((fy1 - fy0) / f["ptmm"]) / H
        return round(X, 4), round(Y, 4)

    def new_doc():
        d = ezdxf.new("R2010", setup=True)
        d.units = ezdxf.units.MM
        d.header["$INSUNITS"] = ezdxf.units.MM
        d.layers.add("BOARD_OUTLINE", color=7)
        d.layers.add("TP_SIDE1", color=1)
        d.layers.add("TP_SIDE2", color=5)
        d.layers.add("TP_LABELS", color=8)
        return d

    def add_pads(msp, n, layer, **kw):
        s = sheets[n]
        for name, (cx, cy, dpt) in sorted(s["pads"].items(), key=lambda kv: int(kv[0][2:])):
            dia = PADS[name][0] or round(dpt / s["ptmm"], 2)
            X, Y = to_mm(n, cx, cy, **kw)
            msp.add_circle((X, Y), dia / 2, dxfattribs={"layer": layer})
            msp.add_text(f"{name} {PADS[name][1]}", height=0.35,
                         dxfattribs={"layer": "TP_LABELS"}).set_placement((X + dia / 2 + 0.15, Y - 0.12))
        return len(s["pads"])

    report = []
    for n in (1, 2):
        d = new_doc()
        m = d.modelspace()
        m.add_lwpolyline([to_mm(n, x, y) for x, y in sheets[n]["outline"]], close=True,
                         dxfattribs={"layer": "BOARD_OUTLINE"})
        cnt = add_pads(m, n, f"TP_SIDE{n}")
        f = os.path.join(a.outdir, f"riva-mainboard-side{n}.dxf")
        d.saveas(f)
        x0, y0, x1, y1 = sheets[n]["box"]
        report.append(f"{f}: {(x1-x0)/sheets[n]['ptmm']:.2f} x {(y1-y0)/sheets[n]['ptmm']:.2f} mm, {cnt} test pads")

    d = new_doc()
    m = d.modelspace()
    m.add_lwpolyline([to_mm(1, x, y) for x, y in sheets[1]["outline"]], close=True,
                     dxfattribs={"layer": "BOARD_OUTLINE"})
    c1 = add_pads(m, 1, "TP_SIDE1")
    c2 = add_pads(m, 2, "TP_SIDE2", mirror=True, frame=1)
    f = os.path.join(a.outdir, "riva-mainboard-combined.dxf")
    d.saveas(f)
    report.append(f"{f}: side 1 view, {c1} side-1 pads + {c2} side-2 pads (mirrored)")

    missing = sorted(set(PADS) - set(sheets[1]["pads"]) - set(sheets[2]["pads"]), key=lambda s: int(s[2:]))
    print("\n".join(report))
    print("pads per side:", {n: sorted(s["pads"], key=lambda t: int(t[2:])) for n, s in sheets.items()})
    if missing:
        print("not found on either sheet:", missing)


if __name__ == "__main__":
    main()
