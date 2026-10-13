import type { Queryable } from '../../database/transaction.js';
import { addDays, daysBetween, periods, periodStart, type GroupBy } from '../../utils/dates.js';
import { fromCents, toCents } from '../../utils/money.js';
import { listCustomerBalances } from '../payments/balances.service.js';
import { listBalances } from '../stock/stock.service.js';

/*
 * Reports (spec 6.10). Every measure is defined once, here, and labelled separately; they are
 * never added together:
 * - Sales value: confirmed dispatches (quantity x agreed price) by dispatch date. Drafts,
 *   cancelled and reversed dispatches do not count.
 * - Invoiced: issued invoices by issue date.
 * - Payments received: payments that have not been voided, by the date received.
 * - Owed by customers: the current balance (confirmed dispatches less payments), as on the
 *   Payments screen.
 */

export interface ProductRef {
  id: string;
  sku: string;
  description: string;
}

const describe = (row: { name: string; flavour: string; size: string }) =>
  `${row.name} — ${row.flavour} — ${row.size}`;

/** SQL for the first day of the day, week or month containing `column` ($3 = week start). */
function periodKeySql(column: string, groupBy: GroupBy): string {
  if (groupBy === 'day') return column;
  if (groupBy === 'month') return `date_trunc('month', ${column})::date`;
  return `(${column} - ((extract(isodow FROM ${column})::integer - $3::integer + 7) % 7))`;
}

export interface SalesMeasures {
  dispatches: number;
  packs: number;
  salesValue: string;
  invoiced: string;
  paymentsReceived: string;
}

export interface SalesReport {
  from: string;
  to: string;
  groupBy: GroupBy;
  currency: string;
  totals: SalesMeasures;
  /** Every day, week or month in the range, including ones with nothing in them. */
  periods: (SalesMeasures & { start: string; end: string })[];
}

/** Sales, invoicing and payments per day, week or month (daily/weekly/monthly trends). */
export async function salesReport(
  db: Queryable,
  range: { from: string; to: string },
  groupBy: GroupBy,
  weekStartsOn: number,
  currency: string,
): Promise<SalesReport> {
  const params = [range.from, range.to, weekStartsOn];
  const { rows: sold } = await db.query<{
    key: string;
    dispatches: number;
    packs: number;
    value: string;
  }>(
    `SELECT ${periodKeySql('d.dispatch_date', groupBy)} AS key,
            count(DISTINCT d.id)::integer AS dispatches, sum(i.quantity)::integer AS packs,
            sum(i.quantity * i.unit_price)::numeric(14, 2)::text AS value
     FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
     WHERE d.status = 'confirmed' AND d.dispatch_date BETWEEN $1 AND $2
       AND $3::integer IS NOT NULL
     GROUP BY 1`,
    params,
  );
  const { rows: invoiced } = await db.query<{ key: string; amount: string }>(
    `SELECT ${periodKeySql('v.issue_date', groupBy)} AS key,
            sum(v.total)::numeric(14, 2)::text AS amount
     FROM invoices v
     WHERE v.status = 'issued' AND v.issue_date BETWEEN $1 AND $2 AND $3::integer IS NOT NULL
     GROUP BY 1`,
    params,
  );
  const { rows: paid } = await db.query<{ key: string; amount: string }>(
    `SELECT ${periodKeySql('p.payment_date', groupBy)} AS key,
            sum(p.amount)::numeric(14, 2)::text AS amount
     FROM payments p
     WHERE p.status = 'recorded' AND p.payment_date BETWEEN $1 AND $2 AND $3::integer IS NOT NULL
     GROUP BY 1`,
    params,
  );

  const soldBy = new Map(sold.map((row) => [row.key, row]));
  const invoicedBy = new Map(invoiced.map((row) => [row.key, row.amount]));
  const paidBy = new Map(paid.map((row) => [row.key, row.amount]));
  const buckets = periods(range.from, range.to, groupBy, weekStartsOn).map((period) => {
    const s = soldBy.get(period.key);
    return {
      start: period.start,
      end: period.end,
      dispatches: s?.dispatches ?? 0,
      packs: s?.packs ?? 0,
      salesValue: s?.value ?? '0.00',
      invoiced: invoicedBy.get(period.key) ?? '0.00',
      paymentsReceived: paidBy.get(period.key) ?? '0.00',
    };
  });

  const sumCents = (key: 'salesValue' | 'invoiced' | 'paymentsReceived') =>
    fromCents(buckets.reduce((total, b) => total + toCents(b[key]), 0));
  return {
    from: range.from,
    to: range.to,
    groupBy,
    currency,
    totals: {
      // A dispatch has one date, so it is counted in exactly one period.
      dispatches: buckets.reduce((total, b) => total + b.dispatches, 0),
      packs: buckets.reduce((total, b) => total + b.packs, 0),
      salesValue: sumCents('salesValue'),
      invoiced: sumCents('invoiced'),
      paymentsReceived: sumCents('paymentsReceived'),
    },
    periods: buckets,
  };
}

export interface ProductSales {
  product: ProductRef;
  dispatches: number;
  packs: number;
  salesValue: string;
}

/** Best-selling products in the period, by packs or by value (confirmed dispatches). */
export async function productSalesReport(
  db: Queryable,
  range: { from: string; to: string },
  sortBy: 'packs' | 'value',
): Promise<{ products: ProductSales[]; totals: { packs: number; salesValue: string } }> {
  const { rows } = await db.query<{
    id: string;
    sku: string;
    name: string;
    flavour: string;
    size: string;
    dispatches: number;
    packs: number;
    value: string;
  }>(
    `SELECT p.id, p.sku, p.name, p.flavour, p.size, count(DISTINCT d.id)::integer AS dispatches,
            sum(i.quantity)::integer AS packs,
            sum(i.quantity * i.unit_price)::numeric(14, 2)::text AS value
     FROM dispatch_items i
     JOIN dispatches d ON d.id = i.dispatch_id
     JOIN products p ON p.id = i.product_id
     WHERE d.status = 'confirmed' AND d.dispatch_date BETWEEN $1 AND $2
     GROUP BY p.id
     ORDER BY ${
       // Sorted on the numbers themselves: the text "4.50" would sort above "15.30".
       sortBy === 'packs'
         ? 'sum(i.quantity) DESC, sum(i.quantity * i.unit_price) DESC'
         : 'sum(i.quantity * i.unit_price) DESC, sum(i.quantity) DESC'
     }, p.name, p.sku`,
    [range.from, range.to],
  );
  const products = rows.map((row) => ({
    product: { id: row.id, sku: row.sku, description: describe(row) },
    dispatches: row.dispatches,
    packs: row.packs,
    salesValue: row.value,
  }));
  return {
    products,
    totals: {
      packs: products.reduce((total, p) => total + p.packs, 0),
      salesValue: fromCents(products.reduce((total, p) => total + toCents(p.salesValue), 0)),
    },
  };
}

export interface CustomerSummary {
  customer: { id: string; code: string; name: string };
  dispatches: number;
  packs: number;
  salesValue: string;
  invoiced: string;
  paymentsReceived: string;
  /** What the customer owes now (not limited to the period); negative when in credit. */
  balanceNow: string;
}

/** Each customer's sales, invoices and payments in the period, with what they owe now. */
export async function customerSummaryReport(
  db: Queryable,
  range: { from: string; to: string },
  today: string,
): Promise<{ customers: CustomerSummary[] }> {
  const { rows } = await db.query<{
    id: string;
    code: string;
    name: string;
    dispatches: number;
    packs: number;
    value: string;
    invoiced: string;
    paid: string;
  }>(
    `WITH sold AS (
       SELECT d.customer_id, count(DISTINCT d.id)::integer AS dispatches,
              sum(i.quantity)::integer AS packs, sum(i.quantity * i.unit_price) AS value
       FROM dispatches d JOIN dispatch_items i ON i.dispatch_id = d.id
       WHERE d.status = 'confirmed' AND d.dispatch_date BETWEEN $1 AND $2
       GROUP BY d.customer_id
     ),
     billed AS (
       SELECT customer_id, sum(total) AS amount FROM invoices
       WHERE status = 'issued' AND issue_date BETWEEN $1 AND $2 GROUP BY customer_id
     ),
     paid AS (
       SELECT customer_id, sum(amount) AS amount FROM payments
       WHERE status = 'recorded' AND payment_date BETWEEN $1 AND $2 GROUP BY customer_id
     )
     SELECT c.id, c.code, c.name,
            COALESCE(s.dispatches, 0) AS dispatches, COALESCE(s.packs, 0) AS packs,
            COALESCE(s.value, 0)::numeric(14, 2)::text AS value,
            COALESCE(b.amount, 0)::numeric(14, 2)::text AS invoiced,
            COALESCE(p.amount, 0)::numeric(14, 2)::text AS paid
     FROM customers c
     LEFT JOIN sold s ON s.customer_id = c.id
     LEFT JOIN billed b ON b.customer_id = c.id
     LEFT JOIN paid p ON p.customer_id = c.id
     WHERE s.customer_id IS NOT NULL OR b.customer_id IS NOT NULL OR p.customer_id IS NOT NULL
     ORDER BY COALESCE(s.value, 0) DESC, c.name, c.code`,
    [range.from, range.to],
  );
  const balances = new Map(
    (await listCustomerBalances(db, today)).customers.map((b) => [b.customer.id, b.balance]),
  );
  return {
    customers: rows.map((row) => ({
      customer: { id: row.id, code: row.code, name: row.name },
      dispatches: row.dispatches,
      packs: row.packs,
      salesValue: row.value,
      invoiced: row.invoiced,
      paymentsReceived: row.paid,
      balanceNow: balances.get(row.id) ?? '0.00',
    })),
  };
}

/** Stock received in the period, per product. Opening balances are not deliveries, so they are left out. */
export async function stockReceivedReport(
  db: Queryable,
  range: { from: string; to: string },
): Promise<{
  products: { product: ProductRef; receipts: number; packs: number }[];
  totals: { receipts: number; packs: number };
}> {
  const { rows } = await db.query<{
    id: string;
    sku: string;
    name: string;
    flavour: string;
    size: string;
    receipts: number;
    packs: number;
  }>(
    `SELECT p.id, p.sku, p.name, p.flavour, p.size, count(*)::integer AS receipts,
            sum(b.quantity_received)::integer AS packs
     FROM stock_batches b JOIN products p ON p.id = b.product_id
     WHERE b.received_date BETWEEN $1 AND $2 AND NOT b.is_opening_balance
     GROUP BY p.id
     ORDER BY packs DESC, p.name, p.sku`,
    [range.from, range.to],
  );
  const products = rows.map((row) => ({
    product: { id: row.id, sku: row.sku, description: describe(row) },
    receipts: row.receipts,
    packs: row.packs,
  }));
  return {
    products,
    totals: {
      receipts: products.reduce((total, p) => total + p.receipts, 0),
      packs: products.reduce((total, p) => total + p.packs, 0),
    },
  };
}

export interface ExpiringBatch {
  product: ProductRef;
  batchNumber: string | null;
  receivedDate: string;
  expiryDate: string;
  /** Negative once expired. */
  daysToExpiry: number;
  /**
   * An estimate: dispatches do not record which batch they took, so stock is assumed to leave
   * oldest first (what is on hand is assumed to be from the most recent deliveries).
   */
  estimatedPacksLeft: number;
}

/**
 * Batches that expire within `days` (or have already expired) and probably still have packs on
 * the shelf. Each product's stock on hand is assigned to its newest deliveries first.
 */
export async function expiringStock(
  db: Queryable,
  today: string,
  days: number,
): Promise<{ withinDays: number; batches: ExpiringBatch[] }> {
  const { rows } = await db.query<{
    id: string;
    sku: string;
    name: string;
    flavour: string;
    size: string;
    batch_number: string | null;
    received_date: string;
    expiry_date: string;
    left: number;
  }>(
    `WITH batches AS (
       SELECT b.*, s.quantity_on_hand,
              COALESCE(sum(b.quantity_received) OVER (
                PARTITION BY b.product_id ORDER BY b.received_date DESC, b.created_at DESC
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS newer
       FROM stock_batches b JOIN stock_balances s ON s.product_id = b.product_id
     )
     SELECT p.id, p.sku, p.name, p.flavour, p.size, b.batch_number, b.received_date,
            b.expiry_date,
            GREATEST(0, LEAST(b.quantity_received, b.quantity_on_hand - b.newer))::integer AS left
     FROM batches b JOIN products p ON p.id = b.product_id
     WHERE p.is_active AND b.expiry_date IS NOT NULL AND b.expiry_date <= $1::date + $2::integer
       AND LEAST(b.quantity_received, b.quantity_on_hand - b.newer) > 0
     ORDER BY b.expiry_date, p.name, p.sku`,
    [today, days],
  );
  return {
    withinDays: days,
    batches: rows.map((row) => ({
      product: { id: row.id, sku: row.sku, description: describe(row) },
      batchNumber: row.batch_number,
      receivedDate: row.received_date,
      expiryDate: row.expiry_date,
      daysToExpiry: daysBetween(today, row.expiry_date),
      estimatedPacksLeft: row.left,
    })),
  };
}

export interface Dashboard {
  today: string;
  dispatchesToday: { dispatches: number; packs: number; salesValue: string | null };
  dispatchesThisWeek: { dispatches: number; packs: number; salesValue: string | null };
  receivedToday: { receipts: number; packs: number };
  lowStock: {
    count: number;
    products: { product: ProductRef; quantityOnHand: number; reorderLevel: number }[];
  };
  expiring: { withinDays: number; count: number; batches: ExpiringBatch[] };
  /** Money measures, for admins and accounts staff only (null for other roles). */
  money: {
    currency: string;
    salesThisMonth: string;
    invoicedThisMonth: string;
    paymentsThisMonth: string;
    owedByCustomers: string;
    overdue: string;
  } | null;
  /** Packs (and, for money roles, sales value) per day for the last 14 days. */
  trend: { date: string; packs: number; salesValue: string | null }[];
}

/** Today at a glance, for everyone; money only for roles that see financial figures. */
export async function dashboard(
  db: Queryable,
  today: string,
  weekStartsOn: number,
  currency: string,
  showMoney: boolean,
): Promise<Dashboard> {
  const hide = <T>(value: T): T | null => (showMoney ? value : null);
  const weekStart = periodStart(today, 'week', weekStartsOn);
  const monthStart = periodStart(today, 'month', weekStartsOn);

  const days = await salesReport(db, { from: addDays(today, -13), to: today }, 'day', 1, currency);
  const week = await salesReport(
    db,
    { from: weekStart, to: today },
    'week',
    weekStartsOn,
    currency,
  );
  const month = await salesReport(db, { from: monthStart, to: today }, 'month', 1, currency);
  const todays = days.periods[days.periods.length - 1] as SalesReport['periods'][number];
  const received = await stockReceivedReport(db, { from: today, to: today });
  const low = await listBalances(db, { lowStockOnly: true, includeInactive: false });
  const expiring = await expiringStock(db, today, 30);

  let money: Dashboard['money'] = null;
  if (showMoney) {
    const { totals } = await listCustomerBalances(db, today);
    money = {
      currency,
      salesThisMonth: month.totals.salesValue,
      invoicedThisMonth: month.totals.invoiced,
      paymentsThisMonth: month.totals.paymentsReceived,
      owedByCustomers: totals.balance,
      overdue: totals.overdue,
    };
  }

  return {
    today,
    dispatchesToday: {
      dispatches: todays.dispatches,
      packs: todays.packs,
      salesValue: hide(todays.salesValue),
    },
    dispatchesThisWeek: {
      dispatches: week.totals.dispatches,
      packs: week.totals.packs,
      salesValue: hide(week.totals.salesValue),
    },
    receivedToday: received.totals,
    lowStock: {
      count: low.length,
      products: low.slice(0, 8).map((b) => ({
        product: { id: b.product.id, sku: b.product.sku, description: describe(b.product) },
        quantityOnHand: b.quantityOnHand,
        reorderLevel: b.reorderLevel as number,
      })),
    },
    expiring: {
      withinDays: expiring.withinDays,
      count: expiring.batches.length,
      batches: expiring.batches.slice(0, 5),
    },
    money,
    trend: days.periods.map((p) => ({
      date: p.start,
      packs: p.packs,
      salesValue: hide(p.salesValue),
    })),
  };
}
