import PDFDocument from 'pdfkit';
import { displayDate } from '../invoices/invoice-pdf.js';
import type { Receipt } from './receipts.service.js';

// A4 is 595 x 842 points; 50-point margins leave 495 points for the table.
const LEFT = 50;
const COLUMNS = [
  { title: '#', width: 20, align: 'right' },
  { title: 'Product', width: 150, align: 'left' },
  { title: 'Unit', width: 40, align: 'left' },
  { title: 'Bought', width: 42, align: 'right' },
  { title: 'Received', width: 48, align: 'right' },
  { title: 'Batch / expiry', width: 77, align: 'left' },
  { title: 'Unit cost', width: 52, align: 'right' },
  { title: 'Amount', width: 66, align: 'right' },
] as const;
/** Text in left-aligned columns keeps clear of the right-aligned number before it. */
const padLeft = (column: { align: string }) => (column.align === 'left' ? 6 : 2);
const TABLE_WIDTH = COLUMNS.reduce((sum, column) => sum + column.width, 0);
const PAGE_BOTTOM = 780;

const HEADINGS: Record<Receipt['status'], string> = {
  DRAFT: 'DRAFT GOODS RECEIVED NOTE',
  PENDING_VERIFICATION: 'GOODS RECEIVED NOTE (NOT YET VERIFIED)',
  VERIFIED: 'GOODS RECEIVED NOTE (VERIFIED)',
  POSTED: 'GOODS RECEIVED NOTE',
  REJECTED: 'REJECTED GOODS RECEIVED NOTE',
  REVERSED: 'REVERSED GOODS RECEIVED NOTE',
};

/** Renders a goods-received note as an A4 PDF. Anything not final is clearly marked. */
export function renderGrnPdf(
  receipt: Receipt,
  business: { name: string; contact: string | null },
): Promise<Buffer> {
  const doc = new PDFDocument({
    size: 'A4',
    margin: LEFT,
    info: {
      Title: `Goods received note ${receipt.grnNumber}`,
      Author: business.name,
      Subject: 'Goods received note',
    },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  // Business (left) and the note's details (right).
  doc.font('Helvetica-Bold').fontSize(18).text(business.name, LEFT, 50, { width: 230 });
  if (business.contact) doc.font('Helvetica').fontSize(9).text(business.contact, { width: 230 });

  doc
    .font('Helvetica-Bold')
    .fontSize(13)
    .text(HEADINGS[receipt.status], 290, 50, { width: 255, align: 'right' });
  doc.font('Helvetica').fontSize(10);
  const details = [
    `GRN number: ${receipt.grnNumber}`,
    `Received: ${displayDate(receipt.receivedDate)}`,
    receipt.purchaseDate ? `Purchased: ${displayDate(receipt.purchaseDate)}` : null,
    receipt.supplierInvoiceNumber ? `Supplier invoice: ${receipt.supplierInvoiceNumber}` : null,
  ].filter((line): line is string => line !== null);
  for (const line of details) doc.text(line, 290, doc.y, { width: 255, align: 'right' });

  // Who supplied it, who owns it, where it went.
  doc.moveDown(2);
  const top = Math.max(doc.y, 140);
  const party = (x: number, title: string, lines: (string | null)[]) => {
    doc.font('Helvetica-Bold').fontSize(10).text(title, x, top, { width: 160 });
    doc.font('Helvetica');
    for (const line of lines) if (line) doc.text(line, x, doc.y, { width: 160 });
    return doc.y;
  };
  const bottom = Math.max(
    party(LEFT, 'Supplier', [
      receipt.supplier ? `${receipt.supplier.name} (${receipt.supplier.code})` : 'Not given',
    ]),
    party(LEFT + 168, 'Stock owner', [`${receipt.owner.name} (${receipt.owner.code})`]),
    party(LEFT + 336, 'Warehouse', [`${receipt.warehouse.name} (${receipt.warehouse.code})`]),
  );

  // Lines.
  let y = bottom + 20;
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
    doc
      .moveTo(LEFT, y)
      .lineTo(LEFT + TABLE_WIDTH, y)
      .lineWidth(0.5)
      .stroke();
    y += 4;
    doc.font('Helvetica').fontSize(8);
  };
  drawHeader();

  for (const line of receipt.lines) {
    const batch = [
      line.batchNumber,
      line.expiryDate ? `exp ${displayDate(line.expiryDate)}` : null,
    ].filter(Boolean);
    const product = `${line.product.description} (${line.product.sku})${
      line.discrepancyReason ? `\nDifference: ${line.discrepancyReason}` : ''
    }`;
    const cells = [
      String(line.lineNumber),
      product,
      line.unit.code,
      String(line.quantityPurchased),
      String(line.quantityReceived),
      batch.length > 0 ? batch.join('\n') : '—',
      line.unitCost,
      line.lineTotal,
    ];
    const height =
      Math.max(
        ...cells.map((text, index) =>
          doc.heightOfString(text, { width: (COLUMNS[index]?.width ?? 0) - 8 }),
        ),
      ) + 4;
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
  doc
    .moveTo(LEFT, y)
    .lineTo(LEFT + TABLE_WIDTH, y)
    .lineWidth(0.5)
    .stroke();

  if (y + 140 > PAGE_BOTTOM) {
    doc.addPage();
    y = 50;
  }
  y += 8;
  doc.font('Helvetica-Bold').fontSize(10);
  doc.text('Total', LEFT + TABLE_WIDTH - 230, y, { width: 120, align: 'right' });
  doc.text(`${receipt.currency} ${receipt.total}`, LEFT + TABLE_WIDTH - 105, y, {
    width: 105,
    align: 'right',
  });
  y += 26;

  // The record of who did what.
  doc.font('Helvetica').fontSize(9);
  const notes = [
    `Received by ${receipt.receivedBy.fullName}.`,
    receipt.verifiedBy && receipt.status !== 'REJECTED'
      ? `Verified by ${receipt.verifiedBy.fullName}.`
      : null,
    receipt.status === 'REJECTED' ? `Rejected: ${receipt.rejectedReason ?? ''}` : null,
    receipt.status === 'REVERSED' ? `Reversed: ${receipt.reversalReason ?? ''}` : null,
    receipt.noDocumentReason
      ? `Submitted without a supplier document: ${receipt.noDocumentReason}`
      : `Supplier documents attached: ${receipt.attachments.length}.`,
    receipt.notes ? `Notes: ${receipt.notes}` : null,
  ].filter((line): line is string => line !== null);
  for (const line of notes) {
    doc.text(line, LEFT, y, { width: TABLE_WIDTH });
    y = doc.y + 2;
  }
  doc
    .fontSize(8)
    .text(`All amounts in ${receipt.currency}. Quantities in the unit shown.`, LEFT, y + 10, {
      width: TABLE_WIDTH,
    });

  doc.end();
  return finished;
}
