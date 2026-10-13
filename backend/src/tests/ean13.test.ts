import { BitArray, EAN13Reader } from '@zxing/library';
import { describe, expect, it } from 'vitest';
import {
  EAN13_TABLES,
  asEan13,
  ean13CheckDigit,
  ean13Modules,
  internalEan13,
  isValidEan13,
} from '../utils/ean13.js';

/** Reads modules back with ZXing, an independent decoder used by many scanning apps. */
function decodeWithZxing(modules: string): string {
  const quiet = 12;
  const scale = 3; // pixels per module, as a camera would see them
  const row = new BitArray((modules.length + 2 * quiet) * scale);
  [...modules].forEach((module, i) => {
    if (module === '1') {
      for (let p = 0; p < scale; p += 1) row.set((quiet + i) * scale + p);
    }
  });
  return new EAN13Reader().decodeRow(0, row, new Map()).getText();
}

describe('EAN-13 check digits', () => {
  it('match published examples', () => {
    expect(ean13CheckDigit('400638133393')).toBe(1); // 4006381333931
    expect(ean13CheckDigit('590123412345')).toBe(7); // 5901234123457
    expect(ean13CheckDigit('978030640615')).toBe(7); // ISBN 978-0-306-40615-7
    expect(isValidEan13('4006381333931')).toBe(true);
    expect(isValidEan13('4006381333932')).toBe(false);
    expect(isValidEan13('400638133393')).toBe(false);
  });

  it('accept UPC-A codes as EAN-13 with a leading 0', () => {
    expect(asEan13('036000291452')).toBe('0036000291452');
    expect(asEan13('5901234123457')).toBe('5901234123457');
    expect(asEan13('5901234123458')).toBeNull();
    expect(asEan13('PC-BBQ-S')).toBeNull();
  });
});

describe('internal barcodes', () => {
  it('start with 20, count up and are valid EAN-13s', () => {
    expect(internalEan13(1)).toBe('2000000000015');
    expect(internalEan13(42)).toMatch(/^200000000042\d$/);
    for (const n of [1, 2, 999, 1234567890]) expect(isValidEan13(internalEan13(n))).toBe(true);
    expect(() => internalEan13(10_000_000_000)).toThrow(/used up/);
  });
});

describe('EAN-13 bar patterns', () => {
  it('follow the rules every scanner relies on', () => {
    const ones = (pattern: string) => [...pattern].filter((m) => m === '1').length;
    EAN13_TABLES.L.forEach((l, digit) => {
      const r = EAN13_TABLES.R[digit] as string;
      const g = EAN13_TABLES.G[digit] as string;
      expect(ones(l) % 2, `L${digit} has odd parity`).toBe(1);
      // R is L with bars and spaces swapped; G is R backwards.
      expect(r).toBe([...l].map((m) => (m === '1' ? '0' : '1')).join(''));
      expect(g).toBe([...r].reverse().join(''));
    });
  });

  it('can be read back by an independent decoder', () => {
    const codes = [
      '4006381333931',
      '5901234123457',
      '9780306406157',
      '0036000291452',
      internalEan13(1),
      internalEan13(7_654_321),
    ];
    for (const code of codes) {
      const modules = ean13Modules(code);
      expect(modules).toHaveLength(95);
      expect(decodeWithZxing(modules), code).toBe(code);
    }
    // Every first digit (which only changes the left-hand patterns) is covered too.
    for (let first = 0; first <= 9; first += 1) {
      const body = `${first}12345678901`;
      const code = `${body}${ean13CheckDigit(body)}`;
      expect(decodeWithZxing(ean13Modules(code))).toBe(code);
    }
  });

  it('refuse a code with a wrong check digit', () => {
    expect(() => ean13Modules('4006381333932')).toThrow(/Not a valid EAN-13/);
  });
});
