import type pg from 'pg';

/**
 * A compact description of everything in the database's public schema: each table's row count
 * and a hash of its contents, each sequence's position, and a hash of each kind of schema
 * object (columns, constraints, indexes, triggers, views, functions, privileges).
 *
 * A backup stores the fingerprint of the moment it was taken. A restored copy must produce the
 * same fingerprint, which proves that nothing was lost or changed on the way.
 */
export interface Fingerprint {
  tables: Record<string, { rows: number; hash: string }>;
  sequences: Record<string, { lastValue: string; isCalled: boolean }>;
  schema: Record<SchemaPart, { count: number; hash: string }>;
}

export const SCHEMA_PARTS = [
  'columns',
  'constraints',
  'indexes',
  'triggers',
  'views',
  'functions',
  'privileges',
] as const;
export type SchemaPart = (typeof SCHEMA_PARTS)[number];

/** One line of text per object; the hash covers all of them, sorted the same way everywhere. */
const SCHEMA_QUERIES: Record<SchemaPart, string> = {
  columns: `
    SELECT format('%s.%s %s not_null=%s default=%s', c.relname, a.attname,
                  format_type(a.atttypid, a.atttypmod), a.attnotnull,
                  pg_get_expr(d.adbin, d.adrelid)) AS line
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v')
      AND a.attnum > 0 AND NOT a.attisdropped`,
  constraints: `
    SELECT format('%s %s %s', c.relname, k.conname, pg_get_constraintdef(k.oid)) AS line
    FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid
    WHERE k.connamespace = 'public'::regnamespace`,
  indexes: `
    SELECT pg_get_indexdef(i.indexrelid) AS line
    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
    WHERE c.relnamespace = 'public'::regnamespace`,
  triggers: `
    SELECT pg_get_triggerdef(t.oid) AS line
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
    WHERE c.relnamespace = 'public'::regnamespace AND NOT t.tgisinternal`,
  views: `
    SELECT format('%s %s', c.relname, pg_get_viewdef(c.oid)) AS line
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('v', 'm')`,
  functions: `
    SELECT pg_get_functiondef(p.oid) AS line
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind IN ('f', 'p')`,
  // Who may do what: this is where the app role's REVOKEs (for example, no UPDATE on the stock
  // ledger) live, so a restore that lost them would be caught here. An empty list means "the
  // owner's defaults", so it is spelled out (acldefault) to compare equal to the same list
  // written explicitly.
  privileges: `
    SELECT format('%s %s', c.relname,
                  coalesce(c.relacl,
                           acldefault(CASE c.relkind WHEN 'S' THEN 's' ELSE 'r' END::"char",
                                      c.relowner))::text) AS line
    FROM pg_class c
    WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    UNION ALL
    SELECT format('schema public %s', coalesce(n.nspacl, acldefault('n', n.nspowner))::text)
    FROM pg_namespace n WHERE n.nspname = 'public'
    UNION ALL
    SELECT format('default %s %s %s', d.defaclrole::regrole, d.defaclobjtype, d.defaclacl::text)
    FROM pg_default_acl d WHERE d.defaclnamespace = 'public'::regnamespace`,
};

/**
 * Reads the fingerprint through `client`. To match a backup exactly, call it inside the
 * transaction whose snapshot the backup was taken from.
 */
export async function fingerprintDatabase(client: pg.ClientBase): Promise<Fingerprint> {
  // Values must print the same way on every connection, or equal data would hash differently.
  await client.query(`SET LOCAL timezone = 'UTC'`);
  await client.query(`SET LOCAL datestyle = 'ISO, YMD'`);
  await client.query(`SET LOCAL intervalstyle = 'postgres'`);
  await client.query(`SET LOCAL extra_float_digits = 3`);

  const { rows: relations } = await client.query<{ name: string; kind: string }>(`
    SELECT relname AS name, relkind AS kind FROM pg_class
    WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r', 'p', 'S')
    ORDER BY relname COLLATE "C"`);

  const tables: Fingerprint['tables'] = {};
  const sequences: Fingerprint['sequences'] = {};
  for (const { name, kind } of relations) {
    const identifier = client.escapeIdentifier(name);
    if (kind === 'S') {
      const { rows } = await client.query<{ last_value: string; is_called: boolean }>(
        `SELECT last_value::text, is_called FROM public.${identifier}`,
      );
      const row = rows[0] as { last_value: string; is_called: boolean };
      sequences[name] = { lastValue: row.last_value, isCalled: row.is_called };
    } else {
      // Sorted byte by byte (COLLATE "C") so the order does not depend on the server's locale.
      const { rows } = await client.query<{ rows: number; hash: string }>(
        `SELECT count(*)::int AS rows,
                md5(coalesce(string_agg(t::text, E'\\n' ORDER BY (t::text) COLLATE "C"), '')) AS hash
         FROM public.${identifier} t`,
      );
      tables[name] = rows[0] as { rows: number; hash: string };
    }
  }

  const schema = {} as Fingerprint['schema'];
  for (const part of SCHEMA_PARTS) {
    const { rows } = await client.query<{ count: number; hash: string }>(
      `SELECT count(*)::int AS count,
              md5(coalesce(string_agg(line, E'\\n' ORDER BY line COLLATE "C"), '')) AS hash
       FROM (${SCHEMA_QUERIES[part]}) parts`,
    );
    schema[part] = rows[0] as { count: number; hash: string };
  }

  return { tables, sequences, schema };
}

/** Lists every difference between the backup's fingerprint and the restored copy's, in words. */
export function compareFingerprints(expected: Fingerprint, actual: Fingerprint): string[] {
  const problems: string[] = [];

  for (const name of union(expected.tables, actual.tables)) {
    const want = expected.tables[name];
    const got = actual.tables[name];
    if (!got) problems.push(`table ${name} is missing from the restored copy`);
    else if (!want) problems.push(`table ${name} is in the restored copy but not in the backup`);
    else if (want.rows !== got.rows) {
      problems.push(`table ${name}: ${want.rows} rows in the backup, ${got.rows} restored`);
    } else if (want.hash !== got.hash) {
      problems.push(`table ${name}: same number of rows, but the contents differ`);
    }
  }

  for (const name of union(expected.sequences, actual.sequences)) {
    const want = expected.sequences[name];
    const got = actual.sequences[name];
    if (!got) problems.push(`sequence ${name} is missing from the restored copy`);
    else if (!want) problems.push(`sequence ${name} is in the restored copy but not in the backup`);
    else if (want.lastValue !== got.lastValue || want.isCalled !== got.isCalled) {
      problems.push(
        `sequence ${name}: at ${want.lastValue} in the backup, ${got.lastValue} restored` +
          (want.isCalled === got.isCalled ? '' : ' (used/unused state differs)'),
      );
    }
  }

  for (const part of SCHEMA_PARTS) {
    const want = expected.schema[part];
    const got = actual.schema[part];
    if (!got) problems.push(`${part}: not checked in the restored copy`);
    else if (want.count !== got.count) {
      problems.push(`${part}: ${want.count} in the backup, ${got.count} restored`);
    } else if (want.hash !== got.hash) {
      problems.push(`${part}: same number, but the definitions differ`);
    }
  }

  return problems;
}

function union(a: object, b: object): string[] {
  return [...new Set([...Object.keys(a), ...Object.keys(b)])].sort();
}
