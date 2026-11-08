import re, sys
from xml.sax.saxutils import escape
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Table,
                                TableStyle, Preformatted, PageBreak, KeepTogether, NextPageTemplate)
from reportlab.platypus.tableofcontents import TableOfContents

F = "/usr/share/fonts/truetype/dejavu/"
pdfmetrics.registerFont(TTFont("DV", F + "DejaVuSans.ttf"))
pdfmetrics.registerFont(TTFont("DVB", F + "DejaVuSans-Bold.ttf"))
pdfmetrics.registerFont(TTFont("DVM", F + "DejaVuSansMono.ttf"))
from reportlab.pdfbase.pdfmetrics import registerFontFamily
registerFontFamily("DV", normal="DV", bold="DVB", italic="DV", boldItalic="DVB")

SRC, OUT = sys.argv[1], sys.argv[2]
RED = colors.HexColor("#C62828"); DARK = colors.HexColor("#1B1F24"); GREY = colors.HexColor("#5A6270")
LIGHT = colors.HexColor("#F3F4F6"); LINE = colors.HexColor("#D0D4DA")

body = ParagraphStyle("b", fontName="DV", fontSize=9.2, leading=13, spaceAfter=4, textColor=DARK)
bullet = ParagraphStyle("bl", parent=body, leftIndent=12, bulletIndent=2, spaceAfter=2)
h1 = ParagraphStyle("h1", fontName="DVB", fontSize=16, leading=20, spaceBefore=6, spaceAfter=8, textColor=RED)
h2 = ParagraphStyle("h2", fontName="DVB", fontSize=12, leading=15, spaceBefore=8, spaceAfter=4, textColor=DARK)
h3 = ParagraphStyle("h3", fontName="DVB", fontSize=10, leading=13, spaceBefore=6, spaceAfter=3, textColor=DARK)
cell = ParagraphStyle("c", fontName="DV", fontSize=7.4, leading=9.4, textColor=DARK)
cellh = ParagraphStyle("ch", parent=cell, fontName="DVB", textColor=colors.white)
note = ParagraphStyle("n", parent=body, fontSize=9, leading=12.5, textColor=DARK)
code = ParagraphStyle("code", fontName="DVM", fontSize=7.4, leading=9.6, textColor=DARK)
toc1 = ParagraphStyle("t1", fontName="DVB", fontSize=9.5, leading=13, leftIndent=0)
toc2 = ParagraphStyle("t2", fontName="DV", fontSize=8.5, leading=11, leftIndent=14)

def fmt(t):
    t = escape(t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
    return t

class Doc(BaseDocTemplate):
    def afterFlowable(self, f):
        if isinstance(f, Paragraph) and f.style.name in ("h1", "h2"):
            lvl = 0 if f.style.name == "h1" else 1
            txt = f.getPlainText()
            key = "k%d" % id(f)
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(txt, key, level=lvl, closed=lvl > 0)
            self.notify("TOCEntry", (lvl, txt, self.page, key))

def deco(c, d):
    c.saveState()
    c.setFont("DV", 7.5); c.setFillColor(GREY)
    c.drawString(18*mm, 10*mm, "Manhunt App · Spezifikation v1.1 · 08.10.2026")
    c.drawRightString(A4[0]-18*mm, 10*mm, "Seite %d" % d.page)
    c.setStrokeColor(RED); c.setLineWidth(1.2)
    c.line(18*mm, A4[1]-12*mm, A4[0]-18*mm, A4[1]-12*mm)
    c.restoreState()

def cover(c, d):
    c.saveState()
    c.setFillColor(DARK); c.rect(0, 0, A4[0], A4[1], fill=1, stroke=0)
    c.setFillColor(RED); c.rect(0, A4[1]*0.52, A4[0], 6, fill=1, stroke=0)
    c.setFillColor(colors.white); c.setFont("DVB", 34)
    c.drawString(22*mm, A4[1]*0.62, "MANHUNT APP")
    c.setFont("DV", 15)
    c.drawString(22*mm, A4[1]*0.62 - 26, "Vollständiges Regelwerk und App-Spezifikation")
    c.setFont("DV", 10.5); c.setFillColor(colors.HexColor("#C9CED6"))
    y = A4[1]*0.45
    for line in ["Grundlage: offizielles Regelwerk manhunt.at (Wien, Bangkok, New York)",
                 "und Auswertung aller Staffeln der YouTube-Serie",
                 "",
                 "Ziel: Eine KI baut aus diesem Dokument direkt eine moderne,",
                 "vollständig konfigurierbare App, um Manhunt selbst zu spielen.",
                 "",
                 "Version 1.1 · 08.10.2026 · erstellt für Marvin"]:
        c.drawString(22*mm, y, line); y -= 15
    c.restoreState()

doc = Doc(OUT, pagesize=A4, leftMargin=18*mm, rightMargin=18*mm, topMargin=18*mm, bottomMargin=18*mm,
          title="Manhunt App – Spezifikation", author="Claude für Marvin")
fr = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="f")
doc.addPageTemplates([PageTemplate("cover", [fr], onPage=cover), PageTemplate("main", [fr], onPage=deco)])
W = doc.width

def make_table(rows):
    ncol = max(len(r) for r in rows)
    rows = [r + [""] * (ncol - len(r)) for r in rows]
    # widths proportional to sqrt of max length, with minimum
    lens = [max(len(r[i]) for r in rows) for i in range(ncol)]
    weights = [max(6, min(l, 70)) ** 0.75 for l in lens]
    tot = sum(weights)
    widths = [W * w / tot for w in weights]
    data = [[Paragraph(fmt(x), cellh if i == 0 else cell) for x in r] for i, r in enumerate(rows)]
    t = Table(data, colWidths=widths, repeatRows=1)
    st = [("BACKGROUND", (0, 0), (-1, 0), DARK), ("VALIGN", (0, 0), (-1, -1), "TOP"),
          ("GRID", (0, 0), (-1, -1), 0.4, LINE), ("LEFTPADDING", (0, 0), (-1, -1), 3),
          ("RIGHTPADDING", (0, 0), (-1, -1), 3), ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]
    for i in range(1, len(rows)):
        if i % 2 == 0:
            st.append(("BACKGROUND", (0, i), (-1, i), LIGHT))
    t.setStyle(TableStyle(st))
    return t

story = [NextPageTemplate("main"), PageBreak()]
toc = TableOfContents(); toc.levelStyles = [toc1, toc2]
story += [Paragraph("Inhaltsverzeichnis", ParagraphStyle("tt", parent=h1)), toc, PageBreak()]

lines = open(SRC, encoding="utf-8").read().split("\n")
i = 0; para = []; first_h1 = True
def flush():
    global para
    if para:
        story.append(Paragraph(fmt(" ".join(para)), body)); para = []
while i < len(lines):
    ln = lines[i]
    if ln.startswith("```"):
        flush(); j = i + 1; buf = []
        while not lines[j].startswith("```"):
            buf.append(lines[j]); j += 1
        p = Preformatted("\n".join(buf), code)
        t = Table([[p]], colWidths=[W]); t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), LIGHT),
            ("BOX", (0, 0), (-1, -1), 0.5, LINE), ("LEFTPADDING", (0, 0), (-1, -1), 6), ("TOPPADDING", (0, 0), (-1, -1), 5), ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))
        story += [t, Spacer(1, 6)]; i = j + 1; continue
    if ln.startswith("|"):
        flush(); rows = []
        while i < len(lines) and lines[i].startswith("|"):
            rows.append([c.strip() for c in lines[i].strip().strip("|").split(" | ")]); i += 1
        story += [make_table(rows), Spacer(1, 6)]; continue
    if ln.startswith("# "):
        flush()
        if not first_h1: story.append(PageBreak())
        first_h1 = False
        story.append(Paragraph(fmt(ln[2:]), h1))
    elif ln.startswith("## "):
        flush(); story.append(Paragraph(fmt(ln[3:]), h2))
    elif ln.startswith("### "):
        flush(); story.append(Paragraph(fmt(ln[4:]), h3))
    elif ln.startswith("> "):
        flush()
        t = Table([[Paragraph(fmt(ln[2:]), note)]], colWidths=[W])
        t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#FDECEA")), ("LINEBEFORE", (0, 0), (0, -1), 3, RED),
                               ("LEFTPADDING", (0, 0), (-1, -1), 8), ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6)]))
        story += [t, Spacer(1, 6)]
    elif ln.startswith("- "):
        flush(); story.append(Paragraph(fmt(ln[2:]), bullet, bulletText="•"))
    elif re.match(r"^\d+\. ", ln):
        flush(); m = re.match(r"^(\d+)\. (.*)", ln)
        story.append(Paragraph(fmt(m.group(2)), bullet, bulletText=m.group(1) + "."))
    elif ln.strip() == "":
        flush()
    else:
        para.append(ln.strip())
    i += 1
flush()
doc.multiBuild(story)
print("ok")
