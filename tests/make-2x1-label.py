# SPDX-License-Identifier: MIT
"""Generate a 2 x 1 inch acceptance label. Requires ReportLab."""
import sys
from reportlab.pdfgen import canvas
from reportlab.graphics.barcode import qr
from reportlab.graphics.shapes import Drawing
from reportlab.graphics import renderPDF

c = canvas.Canvas(sys.argv[1], pagesize=(144, 72), pageCompression=1)
c.setTitle('RW403B 2 x 1 inch test')
c.setAuthor('RW403B driver contributors')
c.setLineWidth(0.7)
c.rect(5, 5, 134, 62)
c.setFont('Helvetica-Bold', 9)
c.drawString(11, 53, '2 x 1 inches')
c.setFont('Helvetica', 7)
c.drawString(11, 41, 'One printed label')
c.drawString(11, 30, 'QR: RW403B-2X1')
c.setFont('Helvetica-Bold', 6)
c.drawString(11, 13, 'BOTTOM')
symbol = qr.QrCodeWidget('RW403B-2X1', barLevel='M')
b = symbol.getBounds()
size = 45
art = Drawing(size, size, transform=[size/(b[2]-b[0]), 0, 0, size/(b[3]-b[1]), 0, 0])
art.add(symbol)
renderPDF.draw(art, c, 88, 14)
c.save()
