import math, zlib, struct

w, h = 480, 560
cx, cy = 240.0, 240.0

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)

def mix(c1, c2, t):
    t = clamp(t, 0.0, 1.0)
    return tuple(c1[i] * (1.0 - t) + c2[i] * t for i in range(len(c1)))

def dist_seg(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    l2 = dx*dx + dy*dy
    if l2 == 0: return math.hypot(px - x1, py - y1)
    t = clamp(((px - x1)*dx + (py - y1)*dy) / l2, 0.0, 1.0)
    return math.hypot(px - (x1 + t*dx), py - (y1 + t*dy))

def point_in_tri(px, py, x1, y1, x2, y2, x3, y3):
    d1 = (px - x2)*(y1 - y2) - (x1 - x2)*(py - y2)
    d2 = (px - x3)*(y2 - y3) - (x2 - x3)*(py - y3)
    d3 = (px - x1)*(y3 - y1) - (x3 - x1)*(py - y1)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (has_neg and has_pos)

raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        # 1. Background: Romantic anime twilight gradient
        ty = y / float(h)
        bg = mix((32, 20, 54), (60, 32, 92), ty)
        
        # Soft warm glow aura behind character
        glow_dist = math.hypot(x - cx, y - (cy - 10))
        glow = smoothstep(270.0, 0.0, glow_dist) * 0.48
        col = mix(bg, (255, 145, 195), glow)
        
        # Soft floating heart in background
        hx = (x - cx) / 135.0
        hy = -(y - (cy - 30)) / 135.0
        h_val = (hx*hx + hy*hy - 0.75)**3 - hx*hx * hy*hy*hy
        if -0.12 < h_val < 0.22:
            h_edge = 1.0 - abs(h_val) / 0.22
            col = mix(col, (255, 180, 220), h_edge * 0.25)
            
        # Bokeh floating orbs
        for bx, by, br, bcol, balpha in [
            (75, 100, 36, (255, 205, 235), 0.16),
            (415, 115, 42, (210, 185, 255), 0.18),
            (65, 410, 48, (255, 185, 210), 0.15),
            (415, 390, 44, (230, 205, 255), 0.18),
            (135, 55, 26, (255, 235, 210), 0.20),
            (365, 65, 28, (255, 195, 235), 0.22),
        ]:
            b_dist = math.hypot(x - bx, y - by)
            if b_dist < br:
                b_mask = smoothstep(br, br * 0.15, b_dist)
                col = mix(col, bcol, b_mask * balpha)
                
        # Sparkle 4-point stars
        for sx, sy, s_size in [(95, 170, 13), (395, 180, 14), (65, 280, 10), (425, 260, 12), (205, 45, 9), (285, 40, 11)]:
            spx = abs(x - sx) / float(s_size)
            spy = abs(y - sy) / float(s_size)
            if spx < 1.0 and spy < 1.0:
                s_dist = math.sqrt(spx) + math.sqrt(spy)
                if s_dist < 1.0:
                    s_mask = smoothstep(1.0, 0.1, s_dist)
                    col = mix(col, (255, 255, 240), s_mask * 0.8)

        # 2. Back Hair (Curved Voluminous Twin Tails)
        # Left twin tail
        d_lt = dist_seg(x, y, cx - 80, cy - 20, cx - 145, cy + 220)
        if d_lt < 55.0:
            m_lt = smoothstep(55.0, 50.0, d_lt)
            c_hair = mix((205, 180, 238), (150, 120, 190), (y - cy) / 220.0)
            col = mix(col, c_hair, m_lt)
            
        # Right twin tail
        d_rt = dist_seg(x, y, cx + 80, cy - 20, cx + 145, cy + 220)
        if d_rt < 55.0:
            m_rt = smoothstep(55.0, 50.0, d_rt)
            c_hair = mix((205, 180, 238), (150, 120, 190), (y - cy) / 220.0)
            col = mix(col, c_hair, m_rt)

        # 3. Cat Ears (Nekomimi)
        for side in (-1, 1):
            eb_out_x = cx + side * 88.0
            eb_out_y = cy - 45.0
            eb_in_x  = cx + side * 22.0
            eb_in_y  = cy - 85.0
            et_x     = cx + side * 96.0
            et_y     = cy - 148.0
            
            in_outer_ear = point_in_tri(x, y, eb_out_x, eb_out_y, eb_in_x, eb_in_y, et_x, et_y)
            d_e1 = dist_seg(x, y, eb_out_x, eb_out_y, et_x, et_y)
            d_e2 = dist_seg(x, y, eb_in_x, eb_in_y, et_x, et_y)
            if in_outer_ear or d_e1 < 4.0 or d_e2 < 4.0:
                ear_grad = smoothstep(cy - 40, cy - 150, y)
                ear_col = mix((180, 150, 220), (230, 210, 250), ear_grad)
                col = mix(col, ear_col, 1.0)
                
                # Inner Ear Pink
                ieb_out_x = cx + side * 78.0
                ieb_out_y = cy - 50.0
                ieb_in_x  = cx + side * 30.0
                ieb_in_y  = cy - 80.0
                iet_x     = cx + side * 90.0
                iet_y     = cy - 136.0
                if point_in_tri(x, y, ieb_out_x, ieb_out_y, ieb_in_x, ieb_in_y, iet_x, iet_y):
                    inner_grad = smoothstep(cy - 50, cy - 140, y)
                    inner_col = mix((255, 125, 160), (255, 195, 215), inner_grad)
                    col = mix(col, inner_col, 1.0)
                    
                    # White ear fluff tufts
                    fluff_dist = math.hypot(x - (cx + side * 52.0), y - (cy - 72.0))
                    if fluff_dist < 18.0:
                        fluff_m = smoothstep(18.0, 5.0, fluff_dist)
                        col = mix(col, (255, 255, 255), fluff_m * 0.92)

        # 4. Body & Outfit (Soft curved shoulders, black dress & white apron)
        if y > cy + 60:
            # Curved shoulders: distance to shoulder capsules
            d_ls = dist_seg(x, y, cx - 20, cy + 72, cx - 110, cy + 150)
            d_rs = dist_seg(x, y, cx + 20, cy + 72, cx + 110, cy + 150)
            d_chest = dist_seg(x, y, cx, cy + 70, cx, cy + 300)
            
            in_body = (d_ls < 42.0) or (d_rs < 42.0) or (d_chest < 75.0) or (y > cy + 130 and abs(x - cx) < (80.0 + (y - (cy + 130)) * 0.8))
            if in_body:
                dress_col = mix((32, 22, 45), (18, 12, 28), abs(x - cx) / 140.0)
                col = mix(col, dress_col, 1.0)
                
                # White Apron / Frilly Bib
                bib_w = 36.0 + (y - (cy + 75)) * 0.35
                if abs(x - cx) < bib_w and y < cy + 220:
                    bib_mask = smoothstep(bib_w, bib_w - 2.5, abs(x - cx))
                    bib_col = mix((252, 252, 255), (225, 220, 240), (y - (cy + 75)) / 120.0)
                    col = mix(col, bib_col, bib_mask)
                    
                # Red Bowtie on chest at (cx, cy + 96)
                if abs(y - (cy + 96)) < 15 and abs(x - cx) < 32:
                    bow_edge = abs(x - cx) / 32.0 + abs(y - (cy + 96)) / 15.0
                    if bow_edge < 1.15:
                        bow_c = mix((235, 45, 80), (170, 20, 48), abs(x - cx) / 28.0)
                        col = mix(col, bow_c, 1.0)
                # Golden Bell at (cx, cy + 108)
                bell_d = math.hypot(x - cx, y - (cy + 108))
                if bell_d < 8.0:
                    bell_m = smoothstep(8.0, 6.5, bell_d)
                    bell_c = mix((255, 230, 80), (210, 140, 15), (y - (cy + 104)) / 8.0)
                    if math.hypot(x - (cx - 2.5), y - (cy + 106)) < 3.0:
                        bell_c = (255, 255, 220)
                    col = mix(col, bell_c, bell_m)

        # 5. Neck & Choker
        if cy + 32 < y <= cy + 68:
            neck_w = 18.0 + (y - (cy + 32)) * 0.15
            if abs(x - cx) < neck_w:
                neck_mask = smoothstep(neck_w, neck_w - 2.0, abs(x - cx))
                neck_c = mix((255, 238, 230), (245, 210, 198), (y - (cy + 32)) / 36.0)
                # Velvet choker at cy + 54
                if abs(y - (cy + 54)) < 4.0:
                    neck_c = (35, 20, 45)
                col = mix(col, neck_c, neck_mask)

        # 6. Face Base (Soft Curved Kawaii Anime Head)
        # Top head oval
        top_head = math.hypot((x - cx) / 76.0, (y - (cy - 5.0)) / 68.0)
        # Soft rounded anime cheeks & chin
        chin_round = math.hypot((x - cx) / 54.0, (y - (cy + 22.0)) / 44.0)
        face_dist = min(top_head, chin_round)
        
        if face_dist < 1.0:
            face_mask = smoothstep(1.0, 0.95, face_dist)
            # Porcelain anime skin
            skin_col = mix((255, 248, 242), (255, 230, 222), (y - (cy - 40)) / 100.0)
            col = mix(col, skin_col, face_mask)
            
            # Soft rosy cheeks blush
            for bx in (cx - 40.0, cx + 40.0):
                blush_d = math.hypot((x - bx) / 22.0, (y - (cy + 16.0)) / 11.0)
                if blush_d < 1.0:
                    blush_m = smoothstep(1.0, 0.0, blush_d) * 0.58
                    col = mix(col, (255, 95, 130), blush_m)
                    
            # Whiskers / cute anime cheek lines (3 lines on each cheek)
            for side in (-1, 1):
                wx = cx + side * 42.0
                wy = cy + 14.0
                for line_idx, line_ang in enumerate([-0.22, 0.0, 0.22]):
                    w_d = dist_seg(x, y, wx, wy + line_idx * 5.0, wx + side * 22.0, wy + line_idx * 5.0 + line_ang * 20.0)
                    if w_d < 1.3:
                        w_m = smoothstep(1.3, 0.4, w_d)
                        col = mix(col, (255, 120, 150), w_m * 0.72)

            # Nose: tiny soft pink shadow dot at (cx, cy + 9)
            nose_d = math.hypot(x - cx, y - (cy + 9.0))
            if nose_d < 2.5:
                nose_m = smoothstep(2.5, 0.5, nose_d)
                col = mix(col, (230, 140, 135), nose_m * 0.8)

            # Mouth: cute anime cat smile 'ω' at (cx, cy + 24)
            for side in (-1, 1):
                arc_cx = cx + side * 4.2
                arc_cy = cy + 23.5
                arc_r = math.hypot(x - arc_cx, y - arc_cy)
                if y >= arc_cy - 1.0 and abs(arc_r - 4.5) < 1.4 and abs(x - cx) <= 8.5:
                    m_m = smoothstep(1.4, 0.4, abs(arc_r - 4.5))
                    col = mix(col, (190, 50, 75), m_m)
            # Tiny cute white cat fang (yaeba) on the left side
            if (cx - 4.5 < x < cx - 1.0) and (cy + 23.5 <= y <= cy + 29.0):
                col = mix(col, (255, 255, 255), 0.95)

            # Anime Eyes: Left eye (cx - 34, cy - 5), Right eye (cx + 34, cy - 5)
            for side in (-1, 1):
                ecx = cx + side * 34.0
                ecy = cy - 5.0
                
                # Upper lash: arched curve
                arch_t = (x - ecx) / 18.0
                target_y = ecy - 13.0 - (1.0 - clamp(arch_t*arch_t, 0.0, 1.0)) * 5.5
                
                # Iris: Large expressive vertical oval rx = 14, ry = 20
                iris_d = math.hypot((x - ecx) / 14.0, (y - ecy) / 20.0)
                if iris_d < 1.0:
                    iris_m = smoothstep(1.0, 0.90, iris_d)
                    
                    # Multi-tone violet-magenta-gold anime gradient
                    iris_ty = (y - (ecy - 20.0)) / 40.0
                    if iris_ty < 0.42:
                        iris_c = mix((35, 10, 55), (120, 20, 110), iris_ty / 0.42)
                    elif iris_ty < 0.80:
                        iris_c = mix((120, 20, 110), (235, 60, 180), (iris_ty - 0.42) / 0.38)
                    else:
                        iris_c = mix((235, 60, 180), (255, 220, 120), (iris_ty - 0.80) / 0.20)
                        
                    # Dark pupil
                    pupil_d = math.hypot((x - ecx) / 6.0, (y - (ecy - 2.0)) / 9.0)
                    if pupil_d < 1.0:
                        pupil_m = smoothstep(1.0, 0.4, pupil_d)
                        iris_c = mix(iris_c, (20, 5, 30), pupil_m)
                        
                    # Sparkle star in eye
                    star_d = math.hypot(x - (ecx - side * 2.0), y - (ecy + 9.5))
                    if star_d < 3.5:
                        iris_c = mix(iris_c, (255, 245, 190), smoothstep(3.5, 0.5, star_d) * 0.8)
                        
                    # Anime highlights
                    h1_d = math.hypot(x - (ecx - 5.0), y - (ecy - 7.0))
                    if h1_d < 4.8:
                        iris_c = mix(iris_c, (255, 255, 255), smoothstep(4.8, 3.2, h1_d))
                    h2_d = math.hypot(x - (ecx + 6.0), y - (ecy + 6.0))
                    if h2_d < 2.6:
                        iris_c = mix(iris_c, (255, 255, 255), smoothstep(2.6, 1.4, h2_d) * 0.9)
                        
                    col = mix(col, iris_c, iris_m)
                    
                # Upper Eyelash line
                if abs(x - ecx) < 22.0 and abs(y - target_y) < 3.5:
                    lash_m = smoothstep(3.5, 0.8, abs(y - target_y))
                    col = mix(col, (38, 18, 48), lash_m)
                    
                # Double eyelid crease
                crease_y = target_y - 6.0
                if abs(x - ecx) < 14.0 and abs(y - crease_y) < 1.0:
                    c_m = smoothstep(1.0, 0.2, abs(y - crease_y))
                    col = mix(col, (190, 120, 130), c_m * 0.5)

                # Eyebrows
                brow_y = ecy - 24.0 + abs(x - ecx) * 0.22
                if abs(x - (ecx + side * 2.0)) < 16.0 and abs(y - brow_y) < 1.6:
                    b_m = smoothstep(1.6, 0.4, abs(y - brow_y))
                    col = mix(col, (150, 110, 175), b_m * 0.85)

        # 7. Front Hair (Bangs & Sidelocks)
        # Sidelocks
        for side in (-1, 1):
            sl_d = dist_seg(x, y, cx + side * 62.0, cy - 60.0, cx + side * 68.0, cy + 90.0)
            if sl_d < 16.0:
                sl_m = smoothstep(16.0, 13.0, sl_d)
                sl_col = mix((215, 190, 245), (165, 135, 205), (y - (cy - 60.0)) / 150.0)
                col = mix(col, sl_col, sl_m)

        # Hair dome & bangs
        if cy - 95 < y < cy + 15:
            hair_dome = math.hypot((x - cx) / 86.0, (y - (cy - 35.0)) / 68.0)
            if hair_dome < 1.0 and y < cy - 25:
                dome_m = smoothstep(1.0, 0.94, hair_dome)
                dome_col = mix((230, 210, 255), (180, 155, 220), (y - (cy - 95)) / 70.0)
                col = mix(col, dome_col, dome_m)
                
            # Delicate curved bangs
            for bx_off, b_len in [(-46, 46), (-28, 54), (-10, 58), (0, 60), (12, 56), (30, 52), (48, 44)]:
                strand_tip_x = cx + bx_off + math.sin(bx_off * 0.05) * 5.0
                strand_tip_y = (cy - 85.0) + b_len
                strand_d = dist_seg(x, y, cx + bx_off * 0.9, cy - 85.0, strand_tip_x, strand_tip_y)
                if strand_d < 11.5:
                    str_m = smoothstep(11.5, 9.0, strand_d)
                    str_col = mix((235, 215, 255), (175, 145, 215), (y - (cy - 85.0)) / b_len)
                    col = mix(col, str_col, str_m)
                    
            # Angel's Ring (hair gloss shine)
            halo_y = cy - 58.0 + math.cos((x - cx) / 58.0) * 8.0
            if abs(y - halo_y) < 6.0 and abs(x - cx) < 68.0:
                halo_m = smoothstep(6.0, 0.0, abs(y - halo_y)) * smoothstep(68.0, 42.0, abs(x - cx))
                col = mix(col, (255, 255, 255), halo_m * 0.78)

        # 8. Ear Ribbon Accessory (Right ear base)
        rib_d = math.hypot(x - (cx + 56.0), y - (cy - 68.0))
        if rib_d < 14.0:
            if abs(x - (cx + 56.0)) < 13.0 and abs(y - (cy - 68.0)) < 8.0:
                col = mix(col, (255, 60, 110), 1.0)
            if rib_d < 5.0:
                col = mix(col, (255, 225, 80), 1.0)

        # 9. Cat Paw Gesture (Raised Nyan~ Paw at cx + 64, cy + 68 near cheek)
        paw_cx = cx + 64.0
        paw_cy = cy + 68.0
        paw_d = math.hypot(x - paw_cx, y - paw_cy)
        if paw_d < 24.0:
            paw_m = smoothstep(24.0, 21.0, paw_d)
            paw_col = (252, 252, 255)
            if y > paw_cy + 4.0:
                paw_col = mix(paw_col, (225, 220, 240), (y - paw_cy) / 20.0)
            col = mix(col, paw_col, paw_m)
            
            # Pink Paw Pads (肉球 - Nikukyuu!)
            main_pad_d = math.hypot((x - paw_cx) / 8.5, (y - (paw_cy + 2.0)) / 7.0)
            if main_pad_d < 1.0:
                col = mix(col, (255, 125, 165), smoothstep(1.0, 0.7, main_pad_d))
            for tox, toy in [(-7.5, -8.5), (0.0, -11.0), (7.5, -8.5)]:
                toe_d = math.hypot(x - (paw_cx + tox), y - (paw_cy + toy))
                if toe_d < 3.8:
                    col = mix(col, (255, 130, 170), smoothstep(3.8, 2.2, toe_d))

        r_byte = int(clamp(col[0], 0, 255))
        g_byte = int(clamp(col[1], 0, 255))
        b_byte = int(clamp(col[2], 0, 255))
        raw.extend([r_byte, g_byte, b_byte, 255])

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(raw), level=9))
png += chunk(b'IEND', b'')

with open('neko_girl.png', 'wb') as f:
    f.write(png)

print('Updated neko_girl.png successfully, size:', len(png), 'bytes')
