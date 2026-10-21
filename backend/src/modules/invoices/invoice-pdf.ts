import PDFDocument from 'pdfkit';
import type { Invoice } from './invoices.service.js';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "2026-10-12" -> "12 Oct 2026". */
export function displayDate(date: string): string {
  const [year, month, day] = date.split('-').map(Number);
  return `${day} ${MONTHS[(month ?? 1) - 1]} ${year}`;
}

// A4 is 595 x 842 points; 50-point margins leave 495 points for the table.
const LEFT = 50;
const COLUMNS = [
  { title: 'Date', width: 62, align: 'left' },
  { title: 'Dispatch', width: 60, align: 'left' },
  { title: 'Product', width: 191, align: 'left' },
  { title: 'Qty', width: 42, align: 'right' },
  { title: 'Unit price', width: 66, align: 'right' },
  { title: 'Amount', width: 74, align: 'right' },
] as const;
const TABLE_WIDTH = COLUMNS.reduce((sum, column) => sum + column.width, 0);
const PAGE_BOTTOM = 780;

/** Renders an invoice as an A4 PDF (spec 6.8). Drafts and voided drafts are clearly marked. */
export function renderInvoicePdf(
  invoice: Invoice,
  business: { name: string; contact: string | null },
): Promise<Buffer> {
  const title =
    invoice.status === 'issued'
      ? `Invoice ${invoice.invoiceNumber}`
      : `${invoice.status === 'voided' ? 'Voided draft' : 'Draft'} invoice for ${invoice.customer.name}`;
  const doc = new PDFDocument({
    size: 'A4',
    margin: LEFT,
    info: { Title: title, Author: business.name, Subject: 'Invoice' },
  });
  const chunks: Buffer[] = [];
  doc.on('data', (chunk: Buffer) => chunks.push(chunk));
  const finished = new Promise<Buffer>((resolve, reject) => {
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
  });

  const money = (amount: string) => `${invoice.currency} ${amount}`;

  // Business (left) and invoice details (right).
  doc.font('Helvetica-Bold').fontSize(18).text(business.name, LEFT, 50, { width: 260 });
  if (business.contact) doc.font('Helvetica').fontSize(9).text(business.contact, { width: 260 });

  const heading =
    invoice.status === 'issued'
      ? 'INVOICE'
      : invoice.status === 'voided'
        ? 'VOIDED DRAFT'
        : 'DRAFT INVOICE';
  doc.font('Helvetica-Bold').fontSize(16).text(heading, 330, 50, { width: 215, align: 'right' });
  doc.font('Helvetica').fontSize(10);
  const details = [
    invoice.invoiceNumber
      ? `Invoice number: ${invoice.invoiceNumber}`
      : 'Not issued: not a valid invoice',
    invoice.issueDate ? `Issue date: ${displayDate(invoice.issueDate)}` : null,
    invoice.dueDate ? `Due date: ${displayDate(invoice.dueDate)}` : null,
    `Period: ${displayDate(invoice.periodFrom)} – ${displayDate(invoice.periodTo)}`,
  ].filter((line): line is string => line !== null);
  for (const line of details) doc.text(line, 330, doc.y, { width: 215, align: 'right' });

  // Bill to.
  doc.moveDown(2);
  const billToTop = Math.max(doc.y, 130);
  doc.font('Helvetica-Bold').fontSize(10).text('Bill to', LEFT, billToTop);
  doc.font('Helvetica').text(`${invoice.customer.name} (${invoice.customer.code})`);
  if (invoice.customer.address) doc.text(invoice.customer.address, { width: 300 });
  if (invoice.customer.phone) doc.text(invoice.customer.phone);

  // Lines.
  let y = doc.y + 20;
  const drawHeader = () => {
    doc.font('Helvetica-Bold').fontSize(9);
    let x = LEFT;
    for (const column of COLUMNS) {
      doc.text(column.title, x + 2, y, { width: column.width - 4, align: column.align });
      x += column.width;
    }
    y += 14;
    doc
      .moveTo(LEFT, y)
      .lineTo(LEFT + TABLE_WIDTH, y)
      .lineWidth(0.5)
      .stroke();
    y += 4;
    doc.font('Helvetica').fontSize(9);
  };
  drawHeader();

  for (const line of invoice.lines) {
    const cells = [
      displayDate(line.dispatchDate),
      line.dispatchNumber,
      `${line.product.description} (${line.product.sku})`,
      String(line.quantity),
      line.unitPrice,
      line.lineTotal,
    ];
    const height =
      Math.max(
        ...cells.map((text, index) =>
          doc.heightOfString(text, { width: (COLUMNS[index]?.width ?? 0) - 4 }),
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
      doc.text(text, x + 2, y, { width: column.width - 4, align: column.align });
      x += column.width;
    });
    y += height;
  }
  doc
    .moveTo(LEFT, y)
    .lineTo(LEFT + TABLE_WIDTH, y)
    .lineWidth(0.5)
    .stroke();

  // Totals.
  if (y + 80 > PAGE_BOTTOM) {
    doc.addPage();
    y = 50;
  }
  y += 8;
  const totals: [string, string, boolean][] = [
    ['Subtotal', money(invoice.subtotal), false],
    ['Total', money(invoice.total), true],
    ['Amount paid', money(invoice.amountPaid), false],
    ['Balance due', money(invoice.balanceDue), true],
  ];
  for (const [label, value, bold] of totals) {
    doc.font(bold ? 'Helvetica-Bold' : 'Helvetica').fontSize(10);
    doc.text(label, LEFT + TABLE_WIDTH - 230, y, { width: 120, align: 'right' });
    doc.text(value, LEFT + TABLE_WIDTH - 105, y, { width: 105, align: 'right' });
    y += 16;
  }

  doc
    .font('Helvetica')
    .fontSize(8)
    .text(`All amounts in ${invoice.currency}.`, LEFT, y + 16, { width: TABLE_WIDTH });

  doc.end();
  return finished;
}
