import PDFDocument from 'pdfkit';
import { ean13Modules } from '../../utils/ean13.js';
import type { Product } from './products.service.js';

export const MM = 72 / 25.4; // points per millimetre

/**
 * A4 sheets of 24 labels, 3 across and 8 down, each 70 × 37 mm: the common "24 per sheet"
 * self-adhesive label size. Content keeps 3 mm from each label edge.
 */
export const LABEL_SHEET = {
  columns: 3,
  rows: 8,
  perSheet: 24,
  widthMm: 70,
  heightMm: 37,
  topMarginMm: 0.5,
  insetMm: 3,
};

/** Module (thinnest bar) width at EAN-13's nominal size, so phone cameras read it easily. */
export const MODULE_MM = 0.33;
const BAR_HEIGHT_MM = 13;
/** The start, centre and end guard bars reach a little lower than the rest. */
const GUARD_EXTRA_MM = 1.6;
const GUARD_MODULES = new Set([0, 1, 2, 45, 46, 47, 48, 49, 92, 93, 94]);

/** Draws an EAN-13 with its centre at `centreX` and the top of its bars at `top` (points). */
export function drawEan13(doc: PDFKit.PDFDocument, code: string, centreX: number, top: number) {
  const modules = ean13Modules(code);
  const moduleWidth = MODULE_MM * MM;
  const left = centreX - (modules.length * moduleWidth) / 2;
  const height = BAR_HEIGHT_MM * MM;

  // Each run of bars is drawn as one rectangle, so no hairline gaps appear when printed.
  let i = 0;
  while (i < modules.length) {
    if (modules[i] !== '1') {
      i += 1;
      continue;
    }
    let end = i;
    while (end + 1 < modules.length && modules[end + 1] === '1') end += 1;
    const guard = GUARD_MODULES.has(i);
    doc
      .rect(
        left + i * moduleWidth,
        top,
        (end - i + 1) * moduleWidth,
        height + (guard ? GUARD_EXTRA_MM * MM : 0),
      )
      .fill('black');
    i = end + 1;
  }

  // The digits people can read, in the usual places: the first digit outside the bars, then
  // six under each half.
  const textTop = top + height + 0.3 * MM;
  doc.font('Helvetica').fontSize(8).fillColor('black');
  doc.text(code[0] as string, left - 7 * moduleWidth, textTop, {
    width: 6 * moduleWidth,
    align: 'right',
    lineBreak: false,
  });
  doc.text(code.slice(1, 7), left + 3 * moduleWidth, textTop, {
    width: 42 * moduleWidth,
    align: 'center',
    lineBreak: false,
    characterSpacing: 1,
  });
  doc.text(code.slice(7), left + 50 * moduleWidth, textTop, {
    width: 42 * moduleWidth,
    align: 'center',
    lineBreak: false,
    characterSpacing: 1,
  });
}

/**
 * Barcode labels for a product. `skip` leaves that many labels blank at the start of the first
 * sheet, so a part-used sheet can be printed on.
 */
export function renderLabelsPdf(
  product: Product,
  ean13: string,
  options: { count: number; skip: number },
): Promise<Buffer> {
  const doc = new PDFDocument({
    size: 'A4',
    margin: 0,
    info: { Title: `Barcode labels ${product.sku}`, Subject: 'Barcode labels' },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  const sheet = LABEL_SHEET;
  const description = `${product.name} — ${product.flavour} — ${product.size}`;
  const inset = sheet.insetMm * MM;
  const labelWidth = sheet.widthMm * MM;
  const labelHeight = sheet.heightMm * MM;
  let page = 0;

  for (let n = options.skip; n < options.skip + options.count; n += 1) {
    const onPage = Math.floor(n / sheet.perSheet);
    if (onPage > page) {
      doc.addPage({ size: 'A4', margin: 0 });
      page = onPage;
    }
    const position = n % sheet.perSheet;
    const x = (position % sheet.columns) * labelWidth;
    const y = sheet.topMarginMm * MM + Math.floor(position / sheet.columns) * labelHeight;

    doc
      .font('Helvetica-Bold')
      .fontSize(8)
      .fillColor('black')
      .text(description, x + inset, y + inset, {
        width: labelWidth - 2 * inset,
        height: 2 * 10,
        ellipsis: true,
        align: 'center',
      });
    doc
      .font('Helvetica')
      .fontSize(7)
      .text(product.sku, x + inset, y + inset + 21, {
        width: labelWidth - 2 * inset,
        align: 'center',
        lineBreak: false,
      });
    drawEan13(doc, ean13, x + labelWidth / 2, y + inset + 31);
  }

  doc.end();
  return finished;
}
