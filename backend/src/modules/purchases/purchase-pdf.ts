import PDFDocument from 'pdfkit';
import { displayDate } from '../invoices/invoice-pdf.js';
import type { Purchase } from './purchases.service.js';

// A4 is 595 x 842 points; 50-point margins leave 495 points for the table.
const LEFT = 50;
const COLUMNS = [
  { title: '#', width: 20, align: 'right' },
  { title: 'Product', width: 185, align: 'left' },
  { title: 'Unit', width: 45, align: 'left' },
  { title: 'Bought', width: 50, align: 'right' },
  { title: 'Received', width: 55, align: 'right' },
  { title: 'Unit cost', width: 65, align: 'right' },
  { title: 'Amount', width: 75, align: 'right' },
] as const;
/** Text in left-aligned columns keeps clear of the right-aligned number before it. */
const padLeft = (column: { align: string }) => (column.align === 'left' ? 6 : 2);
const TABLE_WIDTH = COLUMNS.reduce((sum, column) => sum + column.width, 0);
const PAGE_BOTTOM = 780;

const RECEIVING: Record<Purchase['receivingStatus'], string> = {
  NOT_RECEIVED: 'Not received yet',
  PARTLY_RECEIVED: 'Partly received',
  RECEIVED: 'Received in full',
};

/**
 * Renders a list of goods bought as an A4 PDF, to check the delivery against or file with the
 * supplier's invoice. A cancelled list is clearly marked.
 */
export function renderPurchasePdf(
  purchase: Purchase,
  business: { name: string; contact: string | null },
): Promise<Buffer> {
  const doc = new PDFDocument({
    size: 'A4',
    margin: LEFT,
    info: {
      Title: `Goods bought ${purchase.purchaseNumber}`,
      Author: business.name,
      Subject: 'Goods bought',
    },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  doc.font('Helvetica-Bold').fontSize(18).text(business.name, LEFT, 50, { width: 230 });
  if (business.contact) doc.font('Helvetica').fontSize(9).text(business.contact, { width: 230 });

  doc
    .font('Helvetica-Bold')
    .fontSize(13)
    .text(purchase.status === 'CANCELLED' ? 'CANCELLED: GOODS BOUGHT' : 'GOODS BOUGHT', 290, 50, {
      width: 255,
      align: 'right',
    });
  doc.font('Helvetica').fontSize(10);
  const details = [
    `Number: ${purchase.purchaseNumber}`,
    `Bought: ${displayDate(purchase.purchaseDate)}`,
    purchase.supplierInvoiceNumber ? `Supplier invoice: ${purchase.supplierInvoiceNumber}` : null,
    purchase.status === 'OPEN' ? RECEIVING[purchase.receivingStatus] : null,
  ].filter((line): line is string => line !== null);
  for (const line of details) doc.text(line, 290, doc.y, { width: 255, align: 'right' });

  doc.moveDown(2);
  const top = Math.max(doc.y, 140);
  const party = (x: number, title: string, text: string) => {
    doc.font('Helvetica-Bold').fontSize(10).text(title, x, top, { width: 230 });
    doc.font('Helvetica').text(text, x, doc.y, { width: 230 });
    return doc.y;
  };
  const bottom = Math.max(
    party(
      LEFT,
      'Supplier',
      purchase.supplier ? `${purchase.supplier.name} (${purchase.supplier.code})` : 'Not given',
    ),
    party(LEFT + 250, 'For', `${purchase.owner.name} (${purchase.owner.code})`),
  );

  let y = bottom + 20;
  const rule = () =>
    doc
      .moveTo(LEFT, y)
      .lineTo(LEFT + TABLE_WIDTH, y)
      .lineWidth(0.5)
      .stroke();
  const drawHeader = () => {
    doc.font('Helvetica-Bold').fontSize(8);
    let x = LEFT;
    for (const column of COLUMNS) {
      doc.text(column.title, x + padLeft(column), y, {
        width: column.width - padLeft(column) - 2,
        align: column.align,
      });
      x += column.width;
    }
    y += 12;
    rule();
    y += 4;
    doc.font('Helvetica').fontSize(8);
  };
  drawHeader();

  for (const line of purchase.lines) {
    const cells = [
      String(line.lineNumber),
      `${line.product.description} (${line.product.sku})${line.notes ? `\n${line.notes}` : ''}`,
      line.unit.code,
      String(line.quantity),
      // Left blank to tick off by hand when nothing has arrived yet.
      line.quantityReceived > 0 ? String(line.quantityReceived) : '',
      line.unitCost,
      line.lineTotal,
    ];
    const height =
      Math.max(
        ...cells.map((text, index) =>
          doc.heightOfString(text || ' ', { width: (COLUMNS[index]?.width ?? 0) - 8 }),
        ),
      ) + 6;
    if (y + height > PAGE_BOTTOM) {
      doc.addPage();
      y = 50;
      drawHeader();
    }
    let x = LEFT;
    cells.forEach((text, index) => {
      const column = COLUMNS[index] as (typeof COLUMNS)[number];
      doc.text(text, x + padLeft(column), y, {
        width: column.width - padLeft(column) - 2,
        align: column.align,
      });
      x += column.width;
    });
    y += height;
  }
  rule();

  if (y + 160 > PAGE_BOTTOM) {
    doc.addPage();
    y = 50;
  }
  y += 8;
  doc.font('Helvetica-Bold').fontSize(10);
  doc.text('Total', LEFT + TABLE_WIDTH - 230, y, { width: 120, align: 'right' });
  doc.text(`${purchase.currency} ${purchase.total}`, LEFT + TABLE_WIDTH - 105, y, {
    width: 105,
    align: 'right',
  });
  y += 26;

  doc.font('Helvetica').fontSize(9);
  const notes = [
    `Entered by ${purchase.createdBy.fullName}.`,
    purchase.status === 'CANCELLED' ? `Cancelled: ${purchase.cancelReason ?? ''}` : null,
    purchase.receipts.length > 0
      ? `Received on: ${purchase.receipts.map((r) => r.grnNumber).join(', ')}.`
      : null,
    purchase.notes ? `Notes: ${purchase.notes}` : null,
  ].filter((line): line is string => line !== null);
  for (const line of notes) {
    doc.text(line, LEFT, y, { width: TABLE_WIDTH });
    y = doc.y + 2;
  }

  // Signatures for the paper copy: who checked the goods in against this list.
  y += 30;
  doc.fontSize(9);
  for (const [index, label] of ['Checked by (warehouse)', 'Approved by'].entries()) {
    const x = LEFT + index * 250;
    doc
      .moveTo(x, y)
      .lineTo(x + 220, y)
      .lineWidth(0.5)
      .stroke();
    doc.text(`${label}, date`, x, y + 4, { width: 220 });
  }
  doc
    .fontSize(8)
    .text(`All amounts in ${purchase.currency}. Quantities in the unit shown.`, LEFT, y + 30, {
      width: TABLE_WIDTH,
    });

  doc.end();
  return finished;
}
