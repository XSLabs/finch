#!/usr/bin/env python3
"""Draw the Finch mascot and its turnaround model sheet.

The mascot is a finch in a red devil hood holding a trident. Writes:

    branding/svg/mascot.svg             the 3/4 view, 1024 grid
    branding/svg/mascot-<view>.svg      front, side, back
    branding/svg/mascot-modelsheet.svg  all four views on one sheet
    branding/mascot.png                 1024², transparent
    branding/mascot-modelsheet.png      2400 px wide

Every shape is a smooth closed curve through a handful of points (Catmull-Rom,
converted to cubic Béziers), drawn flat in the classic cel style: solid fills,
one ink outline, no shading and no gradients. The sheet's lettering comes from
mkbrand.py, so no font is involved.

Needs: rsvg-convert (librsvg).
"""

import math
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkbrand  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG_DIR = os.path.join(ROOT, 'branding', 'svg')

INK = '#16181B'
HOOD = '#E8262E'        # the mascot's red; mascot only
ROSE = '#E0604F'        # the finch's breast and cheeks
CREAM = '#F8EBD2'       # belly, wing bars, rump
FEATHER = '#2B2D31'     # face, wings, tail
LEG = '#55585E'
SEED = '#E9A23B'        # the beak, as in the logo
MOUTH = '#8E2328'
TONGUE = '#F4919A'
WHITE = '#FFFFFF'

LINE = 8                # outer outline
FINE = 5                # inner detail lines
CX = 512                # centre line of the front and back views


def f(v):
    return f'{v:.1f}'.rstrip('0').rstrip('.')


def smooth(pts, closed=True):
    """Path data for a Catmull-Rom curve through pts.

    A point written as ('c', x, y) is a corner: the curve meets it without
    smoothing.
    """
    corner = [len(p) == 3 for p in pts]
    P = [(p[1], p[2]) if len(p) == 3 else p for p in pts]
    n = len(P)
    d = [f'M{f(P[0][0])},{f(P[0][1])}']
    for i in range(n if closed else n - 1):
        p1, p2 = P[i], P[(i + 1) % n]
        p0 = P[(i - 1) % n] if (closed or i > 0) else p1
        p3 = P[(i + 2) % n] if (closed or i + 2 < n) else p2
        if corner[i]:
            p0 = p1
        if corner[(i + 1) % n]:
            p3 = p2
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d.append(f'C{f(c1[0])},{f(c1[1])} {f(c2[0])},{f(c2[1])} {f(p2[0])},{f(p2[1])}')
    if closed:
        d.append('Z')
    return ''.join(d)


def mirror(pts, cx=CX):
    return [(p[0], 2 * cx - p[1], p[2]) if len(p) == 3 else (2 * cx - p[0], p[1])
            for p in pts]


def sym(half, cx=CX):
    """A symmetric closed outline from its right half.

    half runs clockwise from a point on the centre line to another point on
    the centre line; the left half is its mirror image, walked back.
    """
    return half + mirror(half[1:-1], cx)[::-1]


def shift(pts, dx, dy=0):
    return [(p[0], p[1] + dx, p[2] + dy) if len(p) == 3 else (p[0] + dx, p[1] + dy)
            for p in pts]


def shape(pts, fill, width=LINE):
    return (f'<path d="{smooth(pts)}" fill="{fill}" stroke="{INK}" '
            f'stroke-width="{width}" stroke-linejoin="round"/>')


def outline(pts, width=LINE):
    return (f'<path d="{smooth(pts)}" fill="none" stroke="{INK}" '
            f'stroke-width="{width}" stroke-linejoin="round"/>')


def line(pts, width=FINE, color=INK):
    return (f'<path d="{smooth(pts, closed=False)}" fill="none" stroke="{color}" '
            f'stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>')


def tubes(paths, width, color):
    """Stroked paths with an ink outline: all the ink first, then the colour,
    so tubes that meet merge into one shape."""
    ink = ''.join(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="{width + 2 * LINE}" '
                  f'stroke-linecap="round" stroke-linejoin="round"/>' for d in paths)
    top = ''.join(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}" '
                  f'stroke-linecap="round" stroke-linejoin="round"/>' for d in paths)
    return ink + top


_clips = [0]


def clipped(clip_pts, *inner):
    """Draw inner clipped to clip_pts, then clip_pts' own outline on top."""
    _clips[0] += 1
    cid = f'k{_clips[0]}'
    return (f'<clipPath id="{cid}"><path d="{smooth(clip_pts)}"/></clipPath>'
            f'<g clip-path="url(#{cid})">{"".join(inner)}</g>' + outline(clip_pts))


# --- Shared parts ------------------------------------------------------------

def horn(bx, by, angle, length, width, bend):
    """A devil's horn: a curved cone from a base centre, with a rounded tip.

    bend > 0 curls the tip clockwise of the horn's direction.
    """
    a = math.radians(angle)
    ux, uy = math.cos(a), math.sin(a)
    nx, ny = -uy, ux
    left, right = [], []
    for i in range(5):
        t = i / 4
        off = bend * t * t
        cx, cy = bx + ux * length * t + nx * off, by + uy * length * t + ny * off
        w = width / 2 * (1 - t) ** 0.85 + 7
        left.append((cx + nx * w, cy + ny * w))
        right.append((cx - nx * w, cy - ny * w))
    tip = (bx + ux * (length + 10) + nx * bend * 1.1, by + uy * (length + 10) + ny * bend * 1.1)
    return [('c',) + right[0]] + right[1:] + [tip] + left[::-1][:-1] + [('c',) + left[0]]


def eye(cx, cy, rx, ry, look=(0.4, 0.15), pupil=0.45):
    """A white eye with a pupil pushed toward look (fractions of the radii)."""
    prx, pry = rx * pupil, ry * pupil
    px, py = cx + look[0] * (rx - prx), cy + look[1] * (ry - pry)
    return (f'<ellipse cx="{f(cx)}" cy="{f(cy)}" rx="{f(rx)}" ry="{f(ry)}" fill="{WHITE}" '
            f'stroke="{INK}" stroke-width="{LINE}"/>'
            f'<ellipse cx="{f(px)}" cy="{f(py)}" rx="{f(prx)}" ry="{f(pry)}" fill="{INK}"/>'
            f'<circle cx="{f(px + prx * 0.35)}" cy="{f(py - pry * 0.45)}" r="{f(prx * 0.32)}" '
            f'fill="{WHITE}"/>')


def beak_profile(dx=0, dy=0):
    """The open, smiling seed-cracker seen from the side, pointing left."""
    upper = [(452, 360), (400, 372), (340, 396), ('c', 318, 410), (370, 418),
             (430, 420), ('c', 462, 418)]
    lower = [(456, 440), (414, 456), ('c', 370, 470), (396, 492), (446, 494),
             ('c', 478, 474)]
    mouth = [(466, 404), (400, 414), (360, 432), (380, 472), (436, 480), (474, 456)]
    tongue = [(458, 440), (420, 442), (390, 458), (414, 472), (456, 466)]
    return ''.join(shape(shift(p, dx, dy), c, w) for p, c, w in
                   ((mouth, MOUTH, LINE), (tongue, TONGUE, FINE),
                    (lower, SEED, LINE), (upper, SEED, LINE)))


def beak_front():
    """The same beak seen head-on: a stout cone over a wide-open smile."""
    mouth = sym([(CX, 408), (556, 410), (572, 440), (548, 476), (CX, 486)])
    tongue = sym([(CX, 450), (536, 452), (540, 470), (CX, 480)])
    lower = sym([(CX, 474), (548, 466), ('c', 572, 456), (552, 490), (CX, 504)])
    upper = sym([(CX, 364), (548, 370), ('c', 576, 392), (546, 416), (CX, 444)])
    return (shape(mouth, MOUTH) + shape(tongue, TONGUE, FINE)
            + shape(lower, SEED) + shape(upper, SEED))


def trident(x, y, lean):
    """Shaft bottom at (x, y), built upright and then leaned by lean degrees."""
    fork_y, top = -640, -810
    paths = [f'M0,0 L0,{fork_y}',
             f'M-92,{top + 40} L-92,{fork_y - 70} Q-92,{fork_y} 0,{fork_y} '
             f'Q92,{fork_y} 92,{fork_y - 70} L92,{top + 40}',
             f'M0,{fork_y} L0,{top - 10}']
    heads = ''.join(
        f'<path d="M{hx},{hy - 64} L{hx + 36},{hy + 6} L{hx},{hy - 10} L{hx - 36},{hy + 6} Z" '
        f'fill="{HOOD}" stroke="{INK}" stroke-width="{LINE}" stroke-linejoin="round"/>'
        for hx, hy in ((-92, top + 40), (92, top + 40), (0, top - 10)))
    return (f'<g transform="translate({x} {y}) rotate({lean})">'
            + tubes(paths, 22, HOOD) + heads + '</g>')


def legs(feet):
    """feet: (x, y, toes) with toes as (dx, dy) offsets from the ankle."""
    paths = []
    for x, y, toes in feet:
        paths.append(f'M{x},{y - 84} L{x},{y}')
        paths += [f'M{x},{y} l{dx},{dy}' for dx, dy in toes]
    return tubes(paths, 16, LEG)


TOES_LEFT = [(-58, 10), (-48, 34), (-14, 40), (34, 12)]     # facing left
TOES_FRONT = [(-34, 30), (0, 38), (34, 30)]                  # facing the viewer
TOES_BACK = [(-30, 12), (0, 24), (30, 12)]                   # from behind: the hind toe


def feather_line(pts):
    return line(pts, FINE, CREAM)


def svg(body, w=1024, h=1024, title='Finch mascot'):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}"><title>{title}</title>{body}</svg>\n')


# --- 3/4 view ----------------------------------------------------------------

def view_three_quarter():
    body = [(548, 212), (636, 230), (700, 300), (722, 410), (742, 520), (772, 640),
            (752, 770), (668, 862), (552, 886), (446, 846), (392, 742), (388, 626),
            (414, 528), (408, 470), (392, 400), (408, 300), (464, 232)]
    rose = [('c', 370, 380), (560, 380), (700, 470), ('c', 720, 610),
            (680, 640), ('c', 640, 626), (606, 668), ('c', 566, 650),
            (520, 690), ('c', 478, 664), (440, 700), ('c', 370, 690)]
    face = [(380, 290), (560, 250), (660, 320), (650, 384), (604, 400), (548, 392),
            (494, 412), (462, 470), (420, 500), (380, 480)]
    hood = [(400, 330), (424, 252), (488, 196), (578, 172), (670, 190),
            (742, 246), (782, 330), (792, 430), (780, 520), (752, 572),
            (712, 566), (690, 506), (676, 420), (650, 330), (596, 284),
            (520, 270), (446, 296)]
    hood_lines = [[(456, 264), (540, 236), (620, 250), (672, 300)],
                  [(730, 380), (744, 460), (738, 530)]]
    far_wing = [(668, 470), (744, 500), (786, 590), (790, 700), (762, 800), (720, 862),
                (690, 812), (672, 700), (650, 580)]
    far_bar = [(660, 560), (720, 548), (800, 600), (800, 640), (740, 600), (660, 610)]
    tail = [(690, 790), (780, 830), (880, 920), ('c', 930, 980), ('c', 880, 960),
            ('c', 862, 984), (790, 930), (680, 860)]
    arm = [(468, 520), (432, 600), (392, 652), (338, 676), (290, 662), (272, 618),
           (296, 584), (344, 576), (396, 560), (432, 512)]
    arm_bar = [(480, 548), (430, 600), (400, 622), (392, 596), (436, 560), (470, 524)]
    return ''.join([
        shape(tail, FEATHER),
        feather_line([(760, 860), (860, 940)]),
        legs([(548, 952, TOES_LEFT), (662, 948, TOES_LEFT)]),
        clipped(body, shape(body, CREAM, 0), shape(rose, ROSE, FINE), shape(face, FEATHER, FINE)),
        clipped(far_wing, shape(far_wing, FEATHER, 0), shape(far_bar, CREAM, FINE),
                feather_line([(712, 700), (734, 780), (722, 840)]),
                feather_line([(742, 690), (756, 760)])),
        shape(horn(560, 200, -94, 90, 98, 30), HOOD),
        shape(horn(756, 274, -24, 88, 98, -30), HOOD),
        shape(hood, HOOD),
        *(line(l) for l in hood_lines),
        eye(504, 322, 32, 47),
        eye(576, 318, 41, 56),
        beak_profile(),
        trident(318, 958, -4),
        clipped(arm, shape(arm, FEATHER, 0), shape(arm_bar, CREAM, FINE),
                feather_line([(332, 640), (300, 648)]), feather_line([(336, 612), (300, 614)])),
    ])


# --- Front view --------------------------------------------------------------

def view_front():
    body = sym([(CX, 212), (604, 226), (664, 290), (680, 380), (664, 470), (676, 540),
                (712, 640), (700, 764), (640, 852), (CX, 886)])
    rose = sym([('c', CX, 370), (700, 370), ('c', 720, 620), (676, 640), ('c', 640, 616),
                (604, 664), ('c', 562, 642), ('c', CX, 690)])
    face = sym([(CX, 240), (620, 256), (668, 330), (650, 396), (600, 420), (570, 470),
                (540, 520), (CX, 528)])
    hood = sym([(CX, 170), (616, 182), (696, 236), (734, 330), (738, 440), (726, 550),
                (688, 568), (668, 500), (664, 410), (648, 330), (600, 286), (CX, 276)])
    wing_r = [(668, 480), (720, 530), (746, 640), (736, 760), (704, 812), (684, 760),
              (670, 640)]
    bar_r = [(660, 590), (720, 570), (760, 600), (750, 640), (700, 630), (660, 650)]
    # Character's right wing (viewer's left) grips the trident.
    arm = [(372, 500), (380, 590), (340, 650), (280, 680), (222, 668), (206, 624),
           (232, 588), (290, 576), (340, 520)]
    arm_bar = [(372, 560), (340, 606), (300, 626), (294, 600), (334, 570), (366, 530)]
    hood_lines = [mirror([(470, 256), (420, 270), (378, 310)]),
                  [(470, 256), (420, 270), (378, 310)]]
    return ''.join([
        legs([(472, 950, TOES_FRONT), (552, 950, TOES_FRONT)]),
        clipped(body, shape(body, CREAM, 0), shape(rose, ROSE, FINE), shape(face, FEATHER, FINE)),
        clipped(wing_r, shape(wing_r, FEATHER, 0), shape(bar_r, CREAM, FINE),
                feather_line([(700, 700), (712, 780)])),
        shape(horn(424, 200, -122, 104, 96, 30), HOOD),
        shape(horn(600, 200, -58, 104, 96, -30), HOOD),
        shape(hood, HOOD),
        *(line(l) for l in hood_lines),
        eye(470, 324, 40, 56, look=(0.35, 0.2)),
        eye(554, 324, 40, 56, look=(0.35, 0.2)),
        beak_front(),
        trident(250, 958, -2),
        clipped(arm, shape(arm, FEATHER, 0), shape(arm_bar, CREAM, FINE),
                feather_line([(260, 646), (226, 650)]), feather_line([(262, 618), (226, 616)])),
    ])


# --- Side view (facing left) -------------------------------------------------

def view_side():
    body = [(536, 206), (624, 226), (680, 290), (690, 390), (712, 490), (748, 600),
            (738, 740), (668, 850), (566, 884), (470, 852), (420, 760), (412, 640),
            (428, 540), (410, 470), (388, 400), (398, 300), (452, 228)]
    rose = [('c', 360, 370), (500, 380), (560, 440), ('c', 580, 600), (548, 626),
            ('c', 520, 606), (488, 660), ('c', 452, 640), (420, 700), ('c', 360, 700)]
    face = [(360, 290), (520, 248), (604, 300), (596, 370), (546, 392), (492, 400),
            (462, 450), (430, 500), (370, 490)]
    hood = [(398, 322), (420, 246), (486, 192), (576, 172), (668, 196), (738, 262),
            (772, 362), (778, 470), (762, 560), (722, 566), (696, 490), (678, 390),
            (646, 312), (584, 278), (504, 270), (440, 290)]
    hood_lines = [[(452, 262), (534, 232), (616, 244), (676, 300)],
                  [(724, 372), (738, 460), (734, 530)]]
    wing = [(600, 470), (676, 486), (730, 580), (748, 700), (730, 800), (700, 860),
            (668, 800), (616, 700), (540, 664), (440, 676), (360, 680), (300, 664),
            (282, 622), (316, 590), (380, 600), (460, 600), (540, 560)]
    bar = [(560, 560), (660, 560), (750, 620), (744, 660), (660, 610), (580, 614)]
    tail = shift([(690, 790), (780, 830), (880, 920), ('c', 930, 980), ('c', 880, 960),
                  ('c', 862, 984), (790, 930), (680, 860)], 0)
    return ''.join([
        shape(tail, FEATHER),
        feather_line([(760, 860), (860, 940)]),
        legs([(528, 952, TOES_LEFT), (612, 948, TOES_LEFT)]),
        shape(horn(536, 206, -100, 88, 96, 28), HOOD),       # far horn
        clipped(body, shape(body, CREAM, 0), shape(rose, ROSE, FINE), shape(face, FEATHER, FINE)),
        shape(horn(646, 212, -58, 90, 98, 30), HOOD),        # near horn
        shape(hood, HOOD),
        *(line(l) for l in hood_lines),
        eye(510, 320, 36, 54, look=(-0.5, 0.15)),
        beak_profile(-24, 0),
        trident(318, 958, -2),
        clipped(wing, shape(wing, FEATHER, 0), shape(bar, CREAM, FINE),
                feather_line([(680, 690), (700, 780), (690, 830)]),
                feather_line([(712, 680), (726, 760)]),
                feather_line([(322, 650), (292, 650)]), feather_line([(328, 620), (296, 620)])),
    ])


# --- Back view ---------------------------------------------------------------

def view_back():
    body = sym([(CX, 212), (604, 226), (664, 290), (680, 380), (664, 470), (676, 540),
                (712, 640), (700, 764), (640, 852), (CX, 886)])
    back = sym([(CX, 430), (650, 446), (700, 560), (690, 680), (620, 740), (CX, 752)])
    wing_r = [(668, 480), (720, 530), (746, 640), (736, 760), (704, 812), (684, 760),
              (670, 640)]
    bar_r = [(660, 590), (720, 570), (760, 600), (750, 640), (700, 630), (660, 650)]
    arm = [(372, 500), (380, 590), (340, 650), (280, 680), (222, 668), (206, 624),
           (232, 588), (290, 576), (340, 520)]
    arm_bar = [(372, 560), (340, 606), (300, 626), (294, 600), (334, 570), (366, 530)]
    tail = sym([(CX, 760), (556, 776), (572, 900), ('c', 566, 992), ('c', 536, 968),
                ('c', CX, 994)])
    hood = sym([(CX, 170), (616, 182), (696, 236), (734, 330), (738, 440), (726, 540),
                (680, 540), (620, 510), (CX, 516)])
    hood_lines = [[(CX, 196), (CX, 360), (CX, 506)],
                  [(700, 400), (712, 470), (708, 530)],
                  mirror([(700, 400), (712, 470), (708, 530)])]
    return ''.join([
        legs([(472, 950, TOES_BACK), (552, 950, TOES_BACK)]),
        clipped(body, shape(body, CREAM, 0), shape(back, FEATHER, FINE)),
        shape(tail, FEATHER),
        line([(CX, 800), (CX, 960)], FINE, CREAM),
        clipped(mirror(wing_r), shape(mirror(wing_r), FEATHER, 0),
                shape(mirror(bar_r), CREAM, FINE), feather_line(mirror([(700, 700), (712, 780)]))),
        shape(horn(424, 200, -122, 104, 96, 30), HOOD),
        shape(horn(600, 200, -58, 104, 96, -30), HOOD),
        shape(hood, HOOD),
        *(line(l) for l in hood_lines),
        trident(774, 958, 2),
        clipped(mirror(arm), shape(mirror(arm), FEATHER, 0), shape(mirror(arm_bar), CREAM, FINE)),
    ])


VIEWS = [('back', view_back), ('front', view_front), ('side', view_side),
         ('three-quarter', view_three_quarter)]


# --- Model sheet ---------------------------------------------------------------

mkbrand.CAPS.setdefault('H', ('M0 0 V100 M0 50 H64 M64 0 V100', 64))
mkbrand.CAPS.setdefault('3', ('M4 8 A30 24 0 1 1 30 48 A32 26 0 1 1 2 90', 62))
mkbrand.CAPS.setdefault('/', ('M44 0 L0 100', 44))
mkbrand.CAPS.setdefault('4', ('M46 100 V0 L0 70 H66', 66))

STONE, LINE_GREY = '#686C71', '#C9C4B8'
BAND_A, BAND_B = '#F3D9D3', '#F7E9E4'


def modelsheet():
    W, H = 2400, 1440
    cell, top = 560, 290
    left = (W - 4 * cell) / 2
    s = 0.64
    out = [f'<rect width="{W}" height="{H}" fill="{WHITE}"/>',
           f'<rect x="28" y="28" width="{W - 56}" height="{H - 56}" fill="none" '
           f'stroke="{INK}" stroke-width="24"/>']
    # Height guides: three bands, as on a classic turnaround.
    y0, y1 = top + 160 * s, top + 990 * s
    band = (y1 - y0) / 3
    for i in range(3):
        out.append(f'<rect x="{left - 20}" y="{y0 + i * band:.1f}" width="{4 * cell + 40}" '
                   f'height="{band:.1f}" fill="{BAND_A if i % 2 == 0 else BAND_B}"/>')
    for i in range(4):
        out.append(f'<line x1="{left - 20}" x2="{left + 4 * cell + 20}" y1="{y0 + i * band:.1f}" '
                   f'y2="{y0 + i * band:.1f}" stroke="{LINE_GREY}" stroke-width="4"/>')
    for i, (name, fn) in enumerate(VIEWS):
        x = left + i * cell
        nudge = {'back': -50, 'front': 60}.get(name, 0)   # centre each pose's trident
        out.append(f'<g transform="translate({x + (cell - 1024 * s) / 2 + nudge:.1f} {top}) '
                   f'scale({s:.5f})">{fn()}</g>')
        label = {'three-quarter': '3/4'}.get(name, name).upper()
        out.append(mkbrand.caps_text(label, x + cell / 2, top + 1060 * s, 34, INK,
                                     weight=11, anchor='middle')[0])
    # Title block.
    title, _ = mkbrand.caps_text('THE FINCH MASCOT', W / 2, 120, 64, HOOD, weight=10,
                                  track=0.36, anchor='middle')
    out.append(title)
    out.append(mkbrand.caps_text('TURNAROUND MODEL SHEET', W / 2, 216, 30, STONE,
                                 weight=10, anchor='middle')[0])
    notes = ['THE WING TIP WRAPS THE SHAFT  NO FINGERS',
             'FLAT COLOUR  NO SHADING OR GRADIENTS',
             'THE BEAK IS SEED  THE HOOD AND TRIDENT ARE MASCOT RED']
    for i, n in enumerate(notes):
        out.append(mkbrand.caps_text(n, 120, H - 230 + i * 46, 22, STONE, weight=8)[0])
    sw = 70
    for i, (c, n) in enumerate([(HOOD, 'HOOD'), (ROSE, 'BREAST'), (CREAM, 'BELLY'),
                                (FEATHER, 'WINGS'), (SEED, 'BEAK'), (LEG, 'LEGS')]):
        x = W - 120 - (6 - i) * (sw + 70) + 70
        out.append(f'<rect x="{x}" y="{H - 240}" width="{sw}" height="{sw}" rx="10" fill="{c}" '
                   f'stroke="{INK}" stroke-width="4"/>')
        out.append(mkbrand.caps_text(n, x + sw / 2, H - 150, 16, STONE, weight=7,
                                     anchor='middle')[0])
    return svg(''.join(out), W, H, 'Finch mascot model sheet')


def raster(svg_path, png_path, width=None):
    cmd = ['rsvg-convert', svg_path, '-o', png_path]
    if width:
        cmd += ['-w', str(width)]
    subprocess.run(cmd, check=True)


def main():
    for name, fn in VIEWS:
        fname = 'mascot.svg' if name == 'three-quarter' else f'mascot-{name}.svg'
        with open(os.path.join(SVG_DIR, fname), 'w') as fh:
            fh.write(svg(fn()))
    with open(os.path.join(SVG_DIR, 'mascot-modelsheet.svg'), 'w') as fh:
        fh.write(modelsheet())
    raster(os.path.join(SVG_DIR, 'mascot.svg'), os.path.join(ROOT, 'branding', 'mascot.png'))
    raster(os.path.join(SVG_DIR, 'mascot-modelsheet.svg'),
           os.path.join(ROOT, 'branding', 'mascot-modelsheet.png'))


if __name__ == '__main__':
    main()
