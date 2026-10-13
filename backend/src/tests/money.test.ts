import { describe, expect, it } from 'vitest';
import { fromCents, toCents } from '../utils/money.js';

describe('toCents', () => {
  it('reads exact decimal amounts', () => {
    expect(toCents('12.34')).toBe(1234);
    expect(toCents('0.5')).toBe(50);
    expect(toCents('7')).toBe(700);
    expect(toCents('0.00')).toBe(0);
    expect(toCents('-3.05')).toBe(-305);
    expect(toCents('9999999999.99')).toBe(999_999_999_999);
  });

  it('adds up without floating-point errors', () => {
    expect(toCents('0.10') + toCents('0.20')).toBe(toCents('0.30'));
  });
});

describe('fromCents', () => {
  it('writes two decimal places', () => {
    expect(fromCents(1234)).toBe('12.34');
    expect(fromCents(5)).toBe('0.05');
    expect(fromCents(0)).toBe('0.00');
    expect(fromCents(-50)).toBe('-0.50');
    expect(fromCents(toCents('123.40'))).toBe('123.40');
  });
});
