import { BitArray, EAN13Reader } from '@zxing/library';
import { describe, expect, it } from 'vitest';
import { drawEan13, MM, MODULE_MM } from '../modules/products/labels-pdf.js';
import { internalEan13 } from '../utils/ean13.js';

/** Records the rectangles drawn, standing in for a PDF document. */
function recordingDoc() {
  const rects: { x: number; y: number; w: number; h: number }[] = [];
  const doc = {
    rect(x: number, y: number, w: number, h: number) {
      rects.push({ x, y, w, h });
      return doc;
    },
    fill: () => doc,
    font: () => doc,
    fontSize: () => doc,
    fillColor: () => doc,
    text: () => doc,
  };
  return { doc: doc as unknown as PDFKit.PDFDocument, rects };
}

/** Samples a line through the drawn bars, as a camera would, and decodes it with ZXing. */
function scanAcross(rects: { x: number; y: number; w: number; h: number }[], atY: number) {
  const left = Math.min(...rects.map((r) => r.x));
  const right = Math.max(...rects.map((r) => r.x + r.w));
  const pixel = (MODULE_MM * MM) / 4; // 4 samples per module
  const quiet = 12 * 4;
  const width = Math.ceil((right - left) / pixel);
  const row = new BitArray(width + 2 * quiet);
  for (let p = 0; p < width; p += 1) {
    const x = left + (p + 0.5) * pixel;
    if (rects.some((r) => x >= r.x && x < r.x + r.w && atY >= r.y && atY < r.y + r.h)) {
      row.set(quiet + p);
    }
  }
  return new EAN13Reader().decodeRow(0, row, new Map()).getText();
}

describe('barcodes on labels', () => {
  it('are drawn so that a scanner reads the right number', () => {
    for (const code of ['5901234123457', '0036000291452', internalEan13(1), internalEan13(98765)]) {
      const { doc, rects } = recordingDoc();
      drawEan13(doc, code, 300, 100);

      expect(scanAcross(rects, 100 + 5 * MM), code).toBe(code);
      // 0.33 mm per module: 95 modules are 31.35 mm wide.
      const left = Math.min(...rects.map((r) => r.x));
      const right = Math.max(...rects.map((r) => r.x + r.w));
      expect((right - left) / MM).toBeCloseTo(95 * MODULE_MM, 1);
    }
  });
});
