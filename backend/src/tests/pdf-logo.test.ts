import { describe, expect, it } from 'vitest';
import { renderPurchasePdf } from '../modules/purchases/purchase-pdf.js';
import type { Purchase } from '../modules/purchases/purchases.service.js';
import { LOGO_PATH, logoPath } from '../modules/pdf/letterhead.js';
import { renderLabelsPdf } from '../modules/products/labels-pdf.js';
import type { Product } from '../modules/products/products.service.js';

// Every PDF carries the Snackify logo (owner's request, 2026-11-09).

const images = (pdf: Buffer) => pdf.toString('latin1').split('/Subtype /Image').length - 1;

describe('the logo on PDFs', () => {
  it('is found next to the server code', () => {
    expect(logoPath()).toBe(LOGO_PATH);
  });

  it('heads a document, embedded once however many pages it has', async () => {
    const purchase = {
      purchaseNumber: 'GB000001',
      status: 'OPEN',
      receivingStatus: 'NOT_RECEIVED',
      owner: { id: 'o', code: 'HQ', name: 'Head Office' },
      supplier: null,
      supplierInvoiceNumber: null,
      purchaseDate: '2026-11-09',
      currency: 'USD',
      total: '10.00',
      lines: Array.from({ length: 80 }, (_, index) => ({
        lineNumber: index + 1,
        product: { id: 'p', sku: 'SKU', description: 'Potato Crisps — BBQ — Small' },
        unit: { id: 'u', code: 'pack', name: 'Pack' },
        quantity: 1,
        unitCost: '0.1250',
        lineTotal: '0.13',
        quantityReceived: 0,
        notes: null,
      })),
      createdBy: { id: 'u', fullName: 'Test' },
      cancelReason: null,
      receipts: [],
      notes: null,
      attachments: [],
    } as unknown as Purchase;
    const pdf = await renderPurchasePdf(purchase, { name: 'Snackify', contact: null });
    expect(
      pdf.toString('latin1').match(new RegExp('/Type /Page[^s]', 'g'))?.length,
    ).toBeGreaterThan(1);
    expect(images(pdf)).toBe(1); // the logo, once
  });

  it('is on every barcode label, embedded once for the whole sheet', async () => {
    const product = { sku: 'PC-BBQ-S', name: 'Potato Crisps', flavour: 'BBQ', size: 'Small' };
    const pdf = await renderLabelsPdf(product as Product, '6001234567899', { count: 30, skip: 0 });
    expect(images(pdf)).toBe(1);
    // 30 labels: the logo is drawn 30 times from that one image.
    expect(pdf.length).toBeLessThan(200_000);
  });
});
