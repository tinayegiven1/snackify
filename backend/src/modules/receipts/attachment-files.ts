import { createHash, randomBytes } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { AppError } from '../../utils/app-error.js';

/** The document types receipts accept, recognised by their first bytes, never by their name. */
export type DocumentType = 'application/pdf' | 'image/jpeg' | 'image/png';

const SIGNATURES: { type: DocumentType; bytes: number[]; extensions: string[] }[] = [
  { type: 'application/pdf', bytes: [0x25, 0x50, 0x44, 0x46, 0x2d], extensions: ['.pdf'] }, // %PDF-
  { type: 'image/jpeg', bytes: [0xff, 0xd8, 0xff], extensions: ['.jpg', '.jpeg'] },
  {
    type: 'image/png',
    bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    extensions: ['.png'],
  },
];

const invalidFile = (message: string) =>
  new AppError(415, 'UNSUPPORTED_DOCUMENT', message, [{ field: 'file', message }]);

/**
 * What a file really is, from its content. A file whose content is not a PDF, JPEG or PNG, or
 * whose name claims another type (for example a program renamed "invoice.pdf"), is refused.
 */
export function detectDocumentType(content: Buffer, filename: string): DocumentType {
  const match = SIGNATURES.find((signature) =>
    signature.bytes.every((byte, index) => content[index] === byte),
  );
  if (!match) {
    throw invalidFile(
      'Only PDF, JPEG and PNG documents are accepted (this file is something else).',
    );
  }
  if (!match.extensions.includes(extname(filename).toLowerCase())) {
    throw invalidFile(
      `The file is a ${match.extensions[0]?.slice(1).toUpperCase()} but its name says otherwise.`,
    );
  }
  return match.type;
}

/** A name safe to show and to offer as a download name: no paths or control characters. */
export function cleanFilename(filename: string): string {
  const base = filename.split(/[\\/]/).pop() ?? '';
  // eslint-disable-next-line no-control-regex
  const cleaned = base.replace(/[\u0000-\u001f\u007f"<>|:*?]/g, '').trim();
  if (cleaned.length === 0 || cleaned.length > 200) {
    throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
      { field: 'filename', message: 'Give the file a name of up to 200 characters' },
    ]);
  }
  return cleaned;
}

/**
 * Saves a document under a random name (never the uploaded name) in `dir`, which is outside
 * the web app. Returns the key it is stored under and its SHA-256 checksum.
 */
export async function storeDocument(
  dir: string,
  content: Buffer,
): Promise<{ storageKey: string; sha256: string }> {
  await mkdir(dir, { recursive: true });
  const storageKey = randomBytes(32).toString('hex');
  await writeFile(join(dir, storageKey), content, { flag: 'wx' });
  return { storageKey, sha256: createHash('sha256').update(content).digest('hex') };
}

export async function readDocument(dir: string, storageKey: string): Promise<Buffer> {
  if (!/^[a-f0-9]{64}$/.test(storageKey)) throw new Error('Invalid storage key');
  return readFile(join(dir, storageKey));
}
