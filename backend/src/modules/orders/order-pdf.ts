import PDFDocument from 'pdfkit';
import { displayDate } from '../invoices/invoice-pdf.js';
import type { Order, OrderStatus } from './orders.service.js';

/** An organisation's details as printed on the sheet. */
export interface SheetParty {
  name: string;
  code: string;
  lines: string[];
}

// A4 is 595 x 842 points; 50-point margins leave 495 points for the table.
const LEFT = 50;
const COLUMNS = [
  { title: 'Product', width: 141, align: 'left' },
  { title: 'Qty', width: 34, align: 'right' },
  { title: 'Unit', width: 40, align: 'left' },
  { title: 'Expected', width: 46, align: 'right' },
  { title: 'Exp. total', width: 54, align: 'right' },
  { title: 'Maximum', width: 46, align: 'right' },
  { title: 'Max. total', width: 54, align: 'right' },
  { title: 'Actual', width: 40, align: 'right' },
  { title: 'Act. total', width: 40, align: 'right' },
] as const;
const TABLE_WIDTH = COLUMNS.reduce((sum, column) => sum + column.width, 0);
const PAGE_BOTTOM = 780;
const padLeft = (column: { align: string }) => (column.align === 'left' ? 6 : 2);

const HEADINGS: Record<OrderStatus, string> = {
  DRAFT: 'DRAFT ORDER',
  SUBMITTED: 'ORDER (SUBMITTED)',
  UNDER_REVIEW: 'ORDER (UNDER REVIEW)',
  APPROVED: 'APPROVED ORDER',
  REJECTED: 'REJECTED ORDER',
  CANCELLED: 'CANCELLED ORDER',
  PARTIALLY_DISPATCHED: 'ORDER (PARTLY DISPATCHED)',
  FULLY_DISPATCHED: 'ORDER (DISPATCHED)',
  COMPLETED: 'ORDER (COMPLETED)',
};

/**
 * The order sheet: who orders from whom, each line's expected, maximum and (once set) actual
 * price and totals, the overall values, the status and who decided.
 */
export function renderOrderPdf(
  order: Order,
  headOffice: SheetParty,
  business: { name: string; contact: string | null },
): Promise<Buffer> {
  const doc = new PDFDocument({
    size: 'A4',
    margin: LEFT,
    info: { Title: `Order ${order.orderNumber}`, Author: business.name, Subject: 'Order sheet' },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });
  const money = (amount: string) => `${order.currency} ${amount}`;

  doc.font('Helvetica-Bold').fontSize(18).text(business.name, LEFT, 50, { width: 230 });
  if (business.contact) doc.font('Helvetica').fontSize(9).text(business.contact, { width: 230 });
  doc
    .font('Helvetica-Bold')
    .fontSize(13)
    .text(HEADINGS[order.status], 290, 50, { width: 255, align: 'right' });
  doc.font('Helvetica').fontSize(10);
  const details = [
    `Order number: ${order.orderNumber}`,
    `Order date: ${displayDate(order.orderDate)}`,
    order.requiredDate ? `Required by: ${displayDate(order.requiredDate)}` : null,
  ].filter((line): line is string => line !== null);
  for (const line of details) doc.text(line, 290, doc.y, { width: 255, align: 'right' });

  doc.moveDown(2);
  const top = Math.max(doc.y, 130);
  const party = (x: number, title: string, who: SheetParty) => {
    doc.font('Helvetica-Bold').fontSize(10).text(title, x, top, { width: 240 });
    doc.font('Helvetica').text(`${who.name} (${who.code})`, x, doc.y, { width: 240 });
    for (const line of who.lines) doc.text(line, x, doc.y, { width: 240 });
    return doc.y;
  };
  const ordering: SheetParty = {
    name: order.organisation.name,
    code: order.organisation.code,
    lines: [`Requested by ${order.requestedBy.fullName}`],
  };
  let y =
    Math.max(
      party(LEFT, 'Ordered by', ordering),
      party(LEFT + 255, 'Supplied by (Head Office)', headOffice),
    ) + 20;

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

  for (const line of order.lines) {
    const cells = [
      `${line.product.description} (${line.product.sku})${line.priceException ? '\nPrice above maximum' : ''}`,
      String(line.requestedQuantity),
      line.unit.code,
      line.expectedUnitPrice,
      line.expectedLineTotal,
      line.maximumUnitPrice,
      line.maximumLineTotal,
      line.actualUnitPrice ?? '—',
      line.actualLineTotal ?? '—',
    ];
    const height =
      Math.max(
        ...cells.map((text, index) => {
          const column = COLUMNS[index] as (typeof COLUMNS)[number];
          return doc.heightOfString(text, { width: column.width - padLeft(column) - 2 });
        }),
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

  if (y + 160 > PAGE_BOTTOM) {
    doc.addPage();
    y = 50;
  }
  y += 8;
  const totals: [string, string, boolean][] = [
    ['Expected total', money(order.expectedTotal), false],
    ['Maximum total', money(order.maximumTotal), false],
    ['Actual total', order.actualTotal ? money(order.actualTotal) : 'Not priced yet', true],
  ];
  for (const [label, value, bold] of totals) {
    doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(10);
    doc.text(label, LEFT + TABLE_WIDTH - 260, y, { width: 140, align: 'right' });
    doc.text(value, LEFT + TABLE_WIDTH - 115, y, { width: 115, align: 'right' });
    y += 16;
  }
  y += 10;

  doc.font('Helvetica').fontSize(9);
  const notes = [
    order.submittedBy ? `Submitted by ${order.submittedBy.fullName}.` : 'Not submitted yet.',
    order.decidedBy
      ? `${order.status === 'REJECTED' ? 'Rejected' : 'Approved'} by ${order.decidedBy.fullName}` +
        (order.decisionComment ? `: ${order.decisionComment}` : '.')
      : null,
    order.priceExceptionApproved
      ? 'A price above the maximum was approved as a price exception.'
      : null,
    order.cancelReason ? `Cancelled: ${order.cancelReason}` : null,
    order.notes ? `Notes: ${order.notes}` : null,
  ].filter((line): line is string => line !== null);
  for (const line of notes) {
    doc.text(line, LEFT, y, { width: TABLE_WIDTH });
    y = doc.y + 2;
  }
  doc
    .fontSize(8)
    .text(
      `All amounts in ${order.currency}. Prices are per unit shown. Expected and maximum prices ` +
        "are the subsidiary's; actual prices are set by the Head Office.",
      LEFT,
      y + 10,
      { width: TABLE_WIDTH },
    );

  doc.end();
  return finished;
}
