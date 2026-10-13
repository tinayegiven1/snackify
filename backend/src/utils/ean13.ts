/**
 * EAN-13, the barcode on most retail packs. 13 digits: the last one is a check digit, so a
 * misread digit is caught by the scanner. UPC-A (12 digits, North America) is the same code
 * with a leading 0.
 */

/** The check digit for the first 12 digits: weights 1, 3, 1, 3, ... from the left. */
export function ean13CheckDigit(first12: string): number {
  if (!/^\d{12}$/.test(first12)) throw new Error('Need exactly 12 digits');
  let sum = 0;
  for (let i = 0; i < 12; i += 1) sum += Number(first12[i]) * (i % 2 === 0 ? 1 : 3);
  return (10 - (sum % 10)) % 10;
}

export function isValidEan13(code: string): boolean {
  return /^\d{13}$/.test(code) && ean13CheckDigit(code.slice(0, 12)) === Number(code[12]);
}

/** The EAN-13 form of a barcode (EAN-13 as is, UPC-A with a leading 0), or null. */
export function asEan13(barcode: string): string | null {
  if (isValidEan13(barcode)) return barcode;
  if (/^\d{12}$/.test(barcode) && isValidEan13(`0${barcode}`)) return `0${barcode}`;
  return null;
}

/**
 * Prefixes 20 to 29 are reserved for numbers a business assigns itself (GS1 "restricted
 * circulation"): they never clash with a manufacturer's barcode. Snackify uses 20.
 */
export const INTERNAL_PREFIX = '20';

/** An internal EAN-13 for sequence number `n` (1 to 9 999 999 999). */
export function internalEan13(n: number): string {
  const body = `${INTERNAL_PREFIX}${String(n).padStart(10, '0')}`;
  if (body.length !== 12) throw new Error('Internal barcode numbers are used up');
  return `${body}${ean13CheckDigit(body)}`;
}

// How each digit is drawn: 7 modules, 1 = bar, 0 = space.
const L = [
  '0001101',
  '0011001',
  '0010011',
  '0111101',
  '0100011',
  '0110001',
  '0101111',
  '0111011',
  '0110111',
  '0001011',
];
const G = [
  '0100111',
  '0110011',
  '0011011',
  '0100001',
  '0011101',
  '0111001',
  '0000101',
  '0010001',
  '0001001',
  '0010111',
];
const R = [
  '1110010',
  '1100110',
  '1101100',
  '1000010',
  '1011100',
  '1001110',
  '1010000',
  '1000100',
  '1001000',
  '1110100',
];
/** The first digit is not drawn: it chooses which of digits 2-7 use the L or G patterns. */
const PARITY = [
  'LLLLLL',
  'LLGLGG',
  'LLGGLG',
  'LLGGGL',
  'LGLLGG',
  'LGGLLG',
  'LGGGLL',
  'LGLGLG',
  'LGLGGL',
  'LGGLGL',
];

export const EAN13_TABLES = { L, G, R, PARITY };

/**
 * The 95 modules of an EAN-13: start guard 101, six left digits, centre guard 01010, six
 * right digits, end guard 101.
 */
export function ean13Modules(code: string): string {
  if (!isValidEan13(code)) throw new Error(`Not a valid EAN-13: ${code}`);
  const digits = [...code].map(Number);
  const parity = PARITY[digits[0] as number] as string;
  let modules = '101';
  for (let i = 1; i <= 6; i += 1) {
    const table = parity[i - 1] === 'L' ? L : G;
    modules += table[digits[i] as number];
  }
  modules += '01010';
  for (let i = 7; i <= 12; i += 1) modules += R[digits[i] as number];
  return `${modules}101`;
}
