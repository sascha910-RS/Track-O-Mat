#!/usr/bin/env python3
# Track-O-Mat – Tagesmenü aus einem PDF lesen
#
#   python3 menu.py Tagesmenu.pdf menu.js
#
# Liest aus dem PDF eines Lokals die Menüs pro Tag und schreibt sie als menu.js, das die
# Seite als Script lädt. kiosk.sh ruft das nach jedem neuen PDF auf. Braucht nur die
# Standardbibliothek, weil auf dem Pi kein PDF-Werkzeug vorausgesetzt werden kann.
#
# Der Text wird nach seiner Position auf der Seite geordnet, nicht nach der Reihenfolge in
# der Datei: Die ist je nach Programm, mit dem das PDF entstand, durcheinander (im PDF von
# Pizza Züri stehen auf den Seiten 2–4 Fusszeile zuerst und Datum zuletzt).
#
# Erwartet pro Seite ein Datum mit passendem Wochentag ("Dienstag, 20. Oktober 2026") und
# darunter Zeilen wie "Menu 1", "Vegimenu" oder "Tagespizza", je gefolgt von Gericht,
# Beschreibung, "Vorspeise: …" und Preis ("CHF 21.50"). Seiten ohne gültiges Datum werden
# übersprungen. Das PDF kommt aus dem Netz: Alle Grössen sind begrenzt, und menu.js
# enthält nur Text, der mit json.dumps geschrieben ist, nie Programmcode.

import datetime, json, math, re, sys, unicodedata, zlib

MAX_STREAM = 4 * 1024 * 1024       # grösster entpackter Datenstrom; schützt vor "Zip-Bomben"
WS = b' \t\r\n\x0c\x00'
TOKEN_END = WS + b'()<>[]{}/%'
NUMBER = re.compile(rb'[+-]?(\d+\.?\d*|\.\d+)$')
ESCAPES = {ord('n'): b'\n', ord('r'): b'\r', ord('t'): b'\t', ord('b'): b'\b', ord('f'): b'\f'}
IDENTITY = (1, 0, 0, 1, 0, 0)


class Name(str):
    pass


class Op(str):
    pass


class Ref:
    def __init__(self, num):
        self.num = num


class Stream:
    def __init__(self, info, raw):
        self.info, self.raw = info, raw


def is_op(tok, *names):
    return isinstance(tok, Op) and (not names or tok in names)


class Lexer:
    def __init__(self, data, pos=0):
        self.data, self.pos = data, pos

    def token(self):
        d, n, i = self.data, len(self.data), self.pos
        while i < n:
            if d[i] in WS:
                i += 1
            elif d[i] == 0x25:                                  # % Kommentar
                while i < n and d[i] not in b'\r\n':
                    i += 1
            else:
                break
        if i >= n:
            self.pos = n
            return None
        c = d[i]
        if c == 0x28:                                           # (Text)
            return self.literal(i + 1)
        if c == 0x3c:                                           # << oder <Hex>
            if d[i + 1:i + 2] == b'<':
                self.pos = i + 2
                return Op('<<')
            j = d.find(b'>', i)
            j = n if j < 0 else j
            self.pos = j + 1
            digits = re.sub(rb'[^0-9A-Fa-f]', b'', d[i + 1:j])
            return bytes.fromhex((digits + b'0' * (len(digits) % 2)).decode())
        if c == 0x3e:
            if d[i + 1:i + 2] == b'>':
                self.pos = i + 2
                return Op('>>')
            self.pos = i + 1
            return Op('>')
        if c in b'[]{})':
            self.pos = i + 1
            return Op(chr(c))
        if c == 0x2f:                                           # /Name
            j = i + 1
            while j < n and d[j] not in TOKEN_END:
                j += 1
            self.pos = j
            raw = re.sub(rb'#([0-9A-Fa-f]{2})', lambda m: bytes([int(m.group(1), 16)]), d[i + 1:j])
            return Name(raw.decode('latin-1'))
        j = i
        while j < n and d[j] not in TOKEN_END:
            j += 1
        self.pos = j
        word = d[i:j]
        if NUMBER.match(word):
            return float(word) if b'.' in word else int(word)
        return Op(word.decode('latin-1'))

    def literal(self, i):
        d, n, out, depth = self.data, len(self.data), bytearray(), 1
        while i < n:
            c = d[i]
            if c == 0x5c:                                       # Backslash
                i += 1
                if i >= n:
                    break
                c = d[i]
                if c in ESCAPES:
                    out += ESCAPES[c]
                    i += 1
                elif 0x30 <= c <= 0x37:
                    j = i
                    while j < n and j < i + 3 and 0x30 <= d[j] <= 0x37:
                        j += 1
                    out.append(int(d[i:j], 8) & 0xff)
                    i = j
                elif c in b'\r\n':                              # Zeilenfortsetzung
                    i += 2 if d[i:i + 2] == b'\r\n' else 1
                else:
                    out.append(c)
                    i += 1
                continue
            if c == 0x28:
                depth += 1
            elif c == 0x29:
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            out.append(c)
            i += 1
        self.pos = i
        return bytes(out)


def parse_value(lex, tok=None, depth=0):
    if depth > 50:
        raise ValueError('zu tief verschachtelt')
    if tok is None:
        tok = lex.token()
    if is_op(tok, '['):
        items = []
        while True:
            t = lex.token()
            if t is None or is_op(t, ']'):
                return items
            items.append(parse_value(lex, t, depth + 1))
    if is_op(tok, '<<'):
        info = {}
        while True:
            t = lex.token()
            if t is None or is_op(t, '>>'):
                return info
            if isinstance(t, Name):
                info[str(t)] = parse_value(lex, None, depth + 1)
    if isinstance(tok, int):                                    # "12 0 R" = Verweis
        save = lex.pos
        if isinstance(lex.token(), int) and is_op(lex.token(), 'R'):
            return Ref(tok)
        lex.pos = save
    return tok


def inflate(raw):
    unpack = zlib.decompressobj()
    out = unpack.decompress(raw, MAX_STREAM)
    if unpack.unconsumed_tail:
        raise ValueError('Datenstrom zu gross')
    return out


class Pdf:
    def __init__(self, data):
        self.data, self.offsets, self.cache = data, {}, {}
        skip = 0
        for m in re.finditer(rb'(?<![0-9])(\d+)\s+\d+\s+obj\b', data):
            if m.start() < skip:                                # Treffer mitten in einem Datenstrom
                continue
            self.offsets[int(m.group(1))] = m.end()
            start, end = data.find(b'stream', m.end()), data.find(b'endobj', m.end())
            if start >= 0 and (end < 0 or start < end):
                stop = data.find(b'endstream', start + 6)
                skip = stop if stop >= 0 else len(data)
        # Objektströme (ab PDF 1.5): mehrere Objekte gepackt in einem Datenstrom
        for num, off in list(self.offsets.items()):
            if b'/ObjStm' in data[off:off + 300]:
                try:
                    self.unpack_objects(self.get(num))
                except (ValueError, zlib.error):
                    pass

    def unpack_objects(self, stream):
        if not isinstance(stream, Stream):
            return
        count, first = self.resolve(stream.info.get('N')), self.resolve(stream.info.get('First'))
        if not isinstance(count, int) or not isinstance(first, int):
            return
        body = self.decode(stream)
        head = Lexer(body)
        pairs = [(head.token(), head.token()) for _ in range(count)]
        for num, off in pairs:
            if isinstance(num, int) and isinstance(off, int) and num not in self.offsets:
                self.cache[num] = parse_value(Lexer(body, first + off))

    def get(self, num):
        if num in self.cache:
            return self.cache[num]
        self.cache[num] = None                                  # gegen Endlosschleifen
        value = None
        if num in self.offsets:
            lex = Lexer(self.data, self.offsets[num])
            value = parse_value(lex)
            if isinstance(value, dict) and is_op(lex.token(), 'stream'):
                value = Stream(value, self.stream_data(value, lex.pos))
        self.cache[num] = value
        return value

    def resolve(self, value):
        for _ in range(20):
            if not isinstance(value, Ref):
                return value
            value = self.get(value.num)
        return None

    def stream_data(self, info, pos):
        d = self.data
        pos += 2 if d[pos:pos + 2] == b'\r\n' else 1 if d[pos:pos + 1] in (b'\r', b'\n') else 0
        length = self.resolve(info.get('Length'))
        if isinstance(length, int) and length >= 0 and d[pos + length:pos + length + 20].lstrip().startswith(b'endstream'):
            return d[pos:pos + length]
        end = d.find(b'endstream', pos)
        raw = d[pos:end if end >= 0 else len(d)]
        return raw[:-2] if raw.endswith(b'\r\n') else raw[:-1] if raw.endswith((b'\r', b'\n')) else raw

    def decode(self, stream):
        filters = self.resolve(stream.info.get('Filter'))
        filters = filters if isinstance(filters, list) else [filters] if filters else []
        data = stream.raw
        for name in filters:
            name = self.resolve(name)
            if name not in ('FlateDecode', 'Fl'):
                raise ValueError('Kompression %s wird nicht unterstützt' % name)
            data = inflate(data)
        return data

    def pages(self):
        """Seiten in der Reihenfolge des Dokuments, je mit ihren (geerbten) Ressourcen."""
        found = []
        roots = re.findall(rb'/Root\s+(\d+)\s+\d+\s+R', self.data)
        catalog = self.get(int(roots[-1])) if roots else None
        if isinstance(catalog, dict):
            self.walk(self.resolve(catalog.get('Pages')), {}, found, 0)
        if not found:                                           # ohne Seitenbaum: alle Seitenobjekte
            for num in sorted(self.offsets):
                page = self.get(num)
                if isinstance(page, dict) and page.get('Type') == 'Page':
                    found.append((page, self.resolve(page.get('Resources')) or {}))
        return found

    def walk(self, node, resources, found, depth):
        if not isinstance(node, dict) or depth > 20 or len(found) > 200:
            return
        own = self.resolve(node.get('Resources'))
        resources = own if isinstance(own, dict) else resources
        kids = self.resolve(node.get('Kids'))
        if isinstance(kids, list):
            for kid in kids:
                self.walk(self.resolve(kid), resources, found, depth + 1)
        elif node.get('Type') == 'Page' or 'Contents' in node:
            found.append((node, resources))


def utf16(hexdigits):
    raw = bytes.fromhex(hexdigits + '0' * (len(hexdigits) % 2))
    return raw.decode('utf-16-be', 'replace') if len(raw) >= 2 else raw.decode('latin-1')


def parse_cmap(data):
    """ToUnicode-Tabelle einer Schrift: Zeichencode -> Text."""
    text, cmap = data.decode('latin-1'), {}
    clean = lambda h: re.sub(r'\s', '', h)
    for block in re.findall(r'beginbfchar(.*?)endbfchar', text, re.S):
        codes = re.findall(r'<([0-9A-Fa-f\s]*)>', block)
        for src, dst in zip(codes[0::2], codes[1::2]):
            if clean(src):
                cmap[int(clean(src), 16)] = utf16(clean(dst))
    pattern = r'<([0-9A-Fa-f\s]+)>\s*<([0-9A-Fa-f\s]+)>\s*(?:<([0-9A-Fa-f\s]*)>|\[([^\]]*)\])'
    for block in re.findall(r'beginbfrange(.*?)endbfrange', text, re.S):
        for m in re.finditer(pattern, block):
            low, high = int(clean(m.group(1)), 16), int(clean(m.group(2)), 16)
            if high < low or high - low > 0xffff or len(cmap) > 200000:
                continue
            if m.group(4) is not None:
                for k, dst in enumerate(re.findall(r'<([0-9A-Fa-f\s]*)>', m.group(4))):
                    if low + k <= high:
                        cmap[low + k] = utf16(clean(dst))
                continue
            dst = clean(m.group(3))
            dst = bytes.fromhex(dst + '0' * (len(dst) % 2))
            if len(dst) < 2:
                dst = b'\x00' + dst[:1]
            base = int.from_bytes(dst[-2:], 'big')
            for k in range(high - low + 1):
                cmap[low + k] = (dst[:-2] + ((base + k) & 0xffff).to_bytes(2, 'big')).decode('utf-16-be', 'replace')
    return cmap


class Font:
    def __init__(self, pdf, info):
        self.wide = info.get('Subtype') == 'Type0'              # Zwei-Byte-Codes (Identity-H)
        self.widths, self.default = {}, 1000 if self.wide else 500
        if self.wide:
            sub = pdf.resolve(info.get('DescendantFonts'))
            sub = pdf.resolve(sub[0]) if isinstance(sub, list) and sub else None
            if isinstance(sub, dict):
                dw = pdf.resolve(sub.get('DW'))
                if isinstance(dw, (int, float)):
                    self.default = dw
                w, i = pdf.resolve(sub.get('W')), 0
                while isinstance(w, list) and i + 1 < len(w):
                    first, nxt = pdf.resolve(w[i]), pdf.resolve(w[i + 1])
                    if isinstance(first, int) and isinstance(nxt, list):
                        for k, width in enumerate(nxt):
                            if isinstance(width, (int, float)):
                                self.widths[first + k] = width
                        i += 2
                    elif i + 2 < len(w) and isinstance(first, int) and isinstance(nxt, int):
                        width = pdf.resolve(w[i + 2])
                        for code in range(first, min(nxt, first + 0xffff) + 1):
                            self.widths[code] = width if isinstance(width, (int, float)) else self.default
                        i += 3
                    else:
                        break
        else:
            first, widths = pdf.resolve(info.get('FirstChar')), pdf.resolve(info.get('Widths'))
            if isinstance(first, int) and isinstance(widths, list):
                for k, width in enumerate(widths):
                    width = pdf.resolve(width)
                    if isinstance(width, (int, float)):
                        self.widths[first + k] = width
            desc = pdf.resolve(info.get('FontDescriptor'))
            if isinstance(desc, dict) and isinstance(desc.get('MissingWidth'), (int, float)):
                self.default = desc['MissingWidth']
        self.cmap = {}
        table = pdf.resolve(info.get('ToUnicode'))
        if isinstance(table, Stream):
            try:
                self.cmap = parse_cmap(pdf.decode(table))
            except (ValueError, zlib.error):
                pass

    def glyphs(self, raw):
        step = 2 if self.wide else 1
        for i in range(0, len(raw) - step + 1, step):
            code = int.from_bytes(raw[i:i + step], 'big')
            text = self.cmap.get(code)
            if text is None:
                text = '' if self.wide else bytes([code]).decode('cp1252', 'replace')
            yield code, text, self.widths.get(code, self.default)


def mul(m, n):
    a, b, c, d, e, f = m
    A, B, C, D, E, F = n
    return (a * A + b * C, a * B + b * D, c * A + d * C, c * B + d * D, e * A + f * C + E, e * B + f * D + F)


class Page:
    """Führt die Zeichenbefehle einer Seite aus und sammelt jedes Zeichen mit seiner Position."""

    def __init__(self, pdf):
        self.pdf, self.glyphs, self.fonts = pdf, [], {}

    def run(self, content, resources, ctm, depth=0):
        pdf = self.pdf
        fonts = pdf.resolve(resources.get('Font')) if isinstance(resources, dict) else None
        xobjects = pdf.resolve(resources.get('XObject')) if isinstance(resources, dict) else None
        st = {'ctm': ctm, 'font': None, 'size': 0, 'tc': 0, 'tw': 0, 'th': 1, 'tl': 0, 'rise': 0}
        saved, tm, tlm, args = [], IDENTITY, IDENTITY, []
        lex = Lexer(content)

        def num(k):
            v = args[k] if -len(args) <= k < len(args) else 0
            return v if isinstance(v, (int, float)) else 0

        def show(raw):
            nonlocal tm
            font, size, th = st['font'], st['size'], st['th']
            if font is None or not isinstance(raw, bytes) or len(self.glyphs) > 50000:
                return
            for code, text, width in font.glyphs(raw):
                m = mul(tm, st['ctm'])
                x = m[2] * st['rise'] + m[4]
                y = m[3] * st['rise'] + m[5]
                height = abs(size) * math.hypot(m[2], m[3])
                advance = (width / 1000 * size + st['tc'] + (st['tw'] if code == 32 and not font.wide else 0)) * th
                tm = mul((1, 0, 0, 1, advance, 0), tm)
                m = mul(tm, st['ctm'])
                self.glyphs.append((x, y, m[2] * st['rise'] + m[4], height, text))

        def newline(tx, ty):
            nonlocal tm, tlm
            tlm = mul((1, 0, 0, 1, tx, ty), tlm)
            tm = tlm

        while True:
            tok = lex.token()
            if tok is None:
                break
            if not isinstance(tok, Op) or tok in ('[', '<<'):
                args.append(parse_value(lex, tok))
                continue
            op = str(tok)
            if op == 'BI':                                      # eingebettetes Bild überspringen
                while True:
                    t = lex.token()
                    if t is None or is_op(t, 'ID'):
                        break
                m = re.compile(rb'\sEI(?=[\s/]|$)').search(content, lex.pos)
                lex.pos = m.end() if m else len(content)
            elif op == 'q':
                saved.append(dict(st))
            elif op == 'Q':
                if saved:
                    st = saved.pop()
            elif op == 'cm' and len(args) >= 6:
                st['ctm'] = mul(tuple(num(k) for k in range(-6, 0)), st['ctm'])
            elif op == 'BT':
                tm = tlm = IDENTITY
            elif op == 'Tf' and len(args) >= 2:
                name = args[-2]
                if isinstance(fonts, dict) and isinstance(name, Name):
                    key = (id(fonts), str(name))
                    if key not in self.fonts:
                        info = pdf.resolve(fonts.get(str(name)))
                        self.fonts[key] = Font(pdf, info) if isinstance(info, dict) else None
                    st['font'] = self.fonts[key]
                st['size'] = num(-1)
            elif op in ('Tc', 'Tw', 'TL', 'Ts'):
                st[{'Tc': 'tc', 'Tw': 'tw', 'TL': 'tl', 'Ts': 'rise'}[op]] = num(-1)
            elif op == 'Tz':
                st['th'] = num(-1) / 100
            elif op == 'Td':
                newline(num(-2), num(-1))
            elif op == 'TD':
                st['tl'] = -num(-1)
                newline(num(-2), num(-1))
            elif op == 'Tm' and len(args) >= 6:
                tm = tlm = tuple(num(k) for k in range(-6, 0))
            elif op == 'T*':
                newline(0, -st['tl'])
            elif op == 'Tj' and args:
                show(args[-1])
            elif op == 'TJ' and args and isinstance(args[-1], list):
                for part in args[-1]:
                    if isinstance(part, (int, float)):
                        tm = mul((1, 0, 0, 1, -part / 1000 * st['size'] * st['th'], 0), tm)
                    else:
                        show(part)
            elif op == "'" and args:
                newline(0, -st['tl'])
                show(args[-1])
            elif op == '"' and len(args) >= 3:
                st['tw'], st['tc'] = num(-3), num(-2)
                newline(0, -st['tl'])
                show(args[-1])
            elif op == 'Do' and args and isinstance(xobjects, dict) and depth < 4:
                form = pdf.resolve(xobjects.get(str(args[-1])))
                if isinstance(form, Stream) and form.info.get('Subtype') == 'Form':
                    matrix = pdf.resolve(form.info.get('Matrix'))
                    matrix = tuple(matrix) if isinstance(matrix, list) and len(matrix) == 6 else IDENTITY
                    own = pdf.resolve(form.info.get('Resources'))
                    self.run(pdf.decode(form), own if isinstance(own, dict) else resources,
                             mul(matrix, st['ctm']), depth + 1)
            args = []

    def lines(self):
        """Zeichen zu Textzeilen zusammensetzen, von oben nach unten."""
        glyphs = sorted((g for g in self.glyphs if g[4] and g[3] > 0), key=lambda g: (-g[1], g[0]))
        rows = []
        for g in glyphs:
            if rows and abs(rows[-1][0][1] - g[1]) <= 0.35 * max(rows[-1][0][3], g[3]):
                rows[-1].append(g)
            else:
                rows.append([g])
        out = []
        for row in rows:
            row.sort(key=lambda g: g[0])
            text, prev = '', None
            for g in row:
                if prev is not None:
                    if g[4] == prev[4] and abs(g[0] - prev[0]) < 0.1 * g[3]:
                        continue                                # doppelt gezeichnet (Ersatz für Fettschrift)
                    if g[0] - prev[2] > 0.18 * max(g[3], prev[3]) and not text.endswith(' ') and g[4] != ' ':
                        text += ' '
                text += g[4]
                prev = g
            text = unicodedata.normalize('NFKC', text)
            text = ''.join(ch if unicodedata.category(ch)[0] != 'C' else ' ' for ch in text)
            text = re.sub(r'\s+', ' ', text).strip()
            if text:
                out.append(text)
        return out


WEEKDAYS = ['montag', 'dienstag', 'mittwoch', 'donnerstag', 'freitag', 'samstag', 'sonntag']
MONTHS = {'januar': 1, 'februar': 2, 'märz': 3, 'maerz': 3, 'april': 4, 'mai': 5, 'juni': 6, 'juli': 7,
          'august': 8, 'september': 9, 'oktober': 10, 'november': 11, 'dezember': 12}
DATE = re.compile(r'\b(%s)\b[\s,]*(\d{1,2})\s*\.\s*(?:(\d{1,2})\s*\.|(%s)\b)\s*(\d{4})?'
                  % ('|'.join(WEEKDAYS), '|'.join(MONTHS)), re.I)
LABEL = re.compile(r'(men[uü]\s*\d+|vegi\s*-?\s*men[uü]|vegetarisch(es)?\s+men[uü]|tages\s*-?\s*pizza)\s*:?', re.I)
PRICE = re.compile(r'(CHF|SFr\.?|Fr\.)\s*\d', re.I)
STARTER = re.compile(r'vorspeise\s*:?\s*', re.I)
FOOTER = re.compile(r'(zusätzliche|wir verwenden|gerne informieren)', re.I)


def clip(text, size=160):
    return text if len(text) <= size else text[:size - 1].rstrip() + '…'


def read_date(lines, today):
    for line in lines[:20]:
        m = DATE.search(line)
        if not m:
            continue
        month = int(m.group(3)) if m.group(3) else MONTHS[m.group(4).lower()]
        year = int(m.group(5)) if m.group(5) else today.year + (1 if month - today.month < -6 else -1 if month - today.month > 6 else 0)
        try:
            date = datetime.date(year, month, int(m.group(2)))
        except ValueError:
            return None
        # Wochentag und Datum müssen zusammenpassen, sonst ist die Seite fehlerhaft
        return date if date.weekday() == WEEKDAYS.index(m.group(1).lower()) else None
    return None


def read_items(lines):
    items, i = [], 0
    while i < len(lines) and len(items) < 8:
        if not LABEL.fullmatch(lines[i]):
            i += 1
            continue
        item = {'label': clip(re.sub(r'\s*:$', '', lines[i]), 30), 'name': '', 'desc': [], 'starter': '', 'price': ''}
        i += 1
        while i < len(lines) and not LABEL.fullmatch(lines[i]) and not FOOTER.match(lines[i]):
            line = lines[i]
            i += 1
            if PRICE.match(line):
                item['price'] = clip(line, 40)
                break
            if STARTER.match(line):
                item['starter'] = clip(STARTER.sub('', line, 1))
            elif not item['name']:
                item['name'] = clip(line)
            elif len(item['desc']) < 3:
                item['desc'].append(clip(line))
        if item['name']:
            items.append(item)
    return items


def main():
    source, target = sys.argv[1], sys.argv[2]
    with open(source, 'rb') as f:
        data = f.read()
    if not data.startswith(b'%PDF'):
        sys.exit('keine PDF-Datei')
    today = datetime.date.today()
    try:
        pdf = Pdf(data)
        pages = pdf.pages()
        days = {}
        for page, resources in pages:
            contents = pdf.resolve(page.get('Contents'))
            parts = contents if isinstance(contents, list) else [contents]
            content = b'\n'.join(pdf.decode(s) for s in map(pdf.resolve, parts) if isinstance(s, Stream))
            reader = Page(pdf)
            reader.run(content, resources, IDENTITY)
            lines = reader.lines()
            date, items = read_date(lines, today), read_items(lines)
            if date and items and date.isoformat() not in days:
                days[date.isoformat()] = items
    except Exception as err:                                    # beliebiges PDF: jeder Fehler heisst "nicht lesbar"
        sys.exit('PDF nicht lesbar (%s: %s)' % (type(err).__name__, err))
    if not days:
        sys.exit('kein Tagesmenü mit gültigem Datum gefunden (%d Seiten)' % len(pages))
    menu = {'days': [{'date': key, 'items': days[key]} for key in sorted(days)[:31]]}
    with open(target, 'w', encoding='ascii') as f:
        f.write('window.TRACKOMAT_MENU = %s;\n' % json.dumps(menu))
    keys = sorted(days)
    print('%d Tage (%s bis %s)' % (len(keys), keys[0], keys[-1]))


if __name__ == "__main__":
    main()
