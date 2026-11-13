import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * The Snackify logo printed on every PDF: backend/assets/snackify-logo.png (a 220 px copy of
 * the app's logo, small enough to keep PDFs light). Found from both src/ and the built dist/,
 * which sit at the same depth.
 */
export const LOGO_PATH = fileURLToPath(
  new URL('../../../assets/snackify-logo.png', import.meta.url),
);

let logoFound: boolean | undefined;

/**
 * The logo's path, or null if it is missing (a PDF without a logo beats no PDF). Given as a path
 * so PDFKit embeds it once per document however many times it is drawn.
 */
export function logoPath(): string | null {
  logoFound ??= existsSync(LOGO_PATH);
  return logoFound ? LOGO_PATH : null;
}

/** Side of the logo in the letterhead, in points (about 17 mm). */
const LOGO_SIZE = 48;
const GAP = 10;

/**
 * The top-left of a document: the logo, then the business's name and contact beside it, in
 * [width] points. Leaves the cursor below both, so what follows never overlaps the logo.
 */
export function drawLetterhead(
  doc: PDFKit.PDFDocument,
  business: { name: string; contact: string | null },
  area: { left: number; top: number; width: number },
): void {
  const logo = logoPath();
  const textLeft = logo ? area.left + LOGO_SIZE + GAP : area.left;
  const textWidth = logo ? area.width - LOGO_SIZE - GAP : area.width;
  if (logo) doc.image(logo, area.left, area.top - 4, { fit: [LOGO_SIZE, LOGO_SIZE] });
  doc.font('Helvetica-Bold').fontSize(18).text(business.name, textLeft, area.top, {
    width: textWidth,
  });
  if (business.contact) {
    doc.font('Helvetica').fontSize(9).text(business.contact, textLeft, doc.y, {
      width: textWidth,
    });
  }
  const logoBottom = area.top - 4 + LOGO_SIZE;
  if (logo && doc.y < logoBottom) doc.y = logoBottom;
}
