# SPDX-License-Identifier: MIT
"""Create the physical acceptance label. Requires ReportLab only for generation."""
from pathlib import Path
import sys
from reportlab.pdfgen import canvas
from reportlab.graphics.barcode import code128, qr
from reportlab.graphics.shapes import Drawing
from reportlab.graphics import renderPDF

target = Path(sys.argv[1])
c = canvas.Canvas(str(target), pagesize=(288, 432), pageCompression=1)
c.setTitle('RW403B Bluetooth print test')
c.setAuthor('Local printer validation')
c.setLineWidth(1)
c.rect(12, 12, 264, 408)
c.setFont('Helvetica-Bold', 16)
c.drawString(24, 394, 'RW403B Bluetooth test')
c.setFont('Helvetica', 10)
c.drawString(24, 376, '4 x 6 inches | 203 dpi | One label')
c.drawString(24, 360, 'Check all four border edges.')

payload = 'RW403B-BLUETOOTH-4X6'
symbol = qr.QrCodeWidget(payload, barLevel='M')
b = symbol.getBounds()
size = 108
d = Drawing(size, size, transform=[size/(b[2]-b[0]), 0, 0, size/(b[3]-b[1]), 0, 0])
d.add(symbol)
renderPDF.draw(d, c, 90, 232)
c.setFont('Helvetica', 9)
c.drawCentredString(144, 220, payload)
c.drawCentredString(144, 205, 'Scan the QR code and confirm this text.')

barcode = code128.Code128('RW403B-4X6', barHeight=40, barWidth=0.9, humanReadable=False)
barcode.drawOn(c, (288-barcode.width)/2, 140)
c.drawCentredString(144, 127, 'Code 128: RW403B-4X6')

c.setLineWidth(1)
c.line(24, 87, 168, 87)
for i in range(9):
    x = 24 + i*18
    c.line(x, 82, x, 94 if i%4==0 else 91)
c.drawString(24, 66, 'This line should measure 2 inches (50.8 mm).')
c.setFont('Helvetica-Bold', 10)
c.drawString(24, 36, 'BOTTOM')
c.save()
print(target)
