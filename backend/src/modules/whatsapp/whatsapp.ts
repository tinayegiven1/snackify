import type { WhatsAppConfig } from '../../config/env.js';

/** A PDF to send on WhatsApp with a pre-approved message template. */
export interface WhatsAppDocument {
  /** The number with its country code, e.g. "+263 77 123 4567". */
  to: string;
  filename: string;
  content: Buffer;
  /** The template's body values ({{1}}, {{2}}, ...), in order. */
  bodyValues: string[];
}

/** Sends a document; resolves with WhatsApp's message id, or throws a readable error. */
export type WhatsAppSender = (document: WhatsAppDocument) => Promise<{ messageId: string }>;

/** A sending problem worth showing to staff as it is (no secrets in it). */
export class WhatsAppError extends Error {}

/** WhatsApp wants the number as digits only, country code first: "+263 77-123" -> "26377123". */
export function whatsAppDigits(number: string): string {
  return number.replace(/[^0-9]/g, '');
}

const TIMEOUT_MS = 20_000;

/**
 * Sends through Meta's WhatsApp Cloud API: uploads the PDF, then sends the template message with
 * the PDF as its document header. Messages to people who have not written first must use an
 * approved template, which is why a plain document message is not used.
 */
export function cloudApiSender(
  config: WhatsAppConfig,
  fetchImpl: typeof fetch = fetch,
): WhatsAppSender {
  const base = `https://graph.facebook.com/${config.apiVersion}/${config.phoneNumberId}`;
  const auth = { Authorization: `Bearer ${config.accessToken}` };

  async function call(path: string, init: RequestInit): Promise<Record<string, unknown>> {
    let response: Response;
    try {
      response = await fetchImpl(`${base}/${path}`, {
        ...init,
        headers: { ...auth, ...init.headers },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch {
      throw new WhatsAppError('WhatsApp could not be reached. Try sending again later.');
    }
    const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    if (!response.ok) {
      const error = (body.error ?? {}) as {
        message?: string;
        code?: number;
        error_data?: { details?: string };
      };
      const reason = error.error_data?.details ?? error.message ?? `HTTP ${response.status}`;
      throw new WhatsAppError(
        `WhatsApp refused the message${error.code ? ` (code ${error.code})` : ''}: ${reason}`,
      );
    }
    return body;
  }

  return async (document) => {
    const form = new FormData();
    form.append('messaging_product', 'whatsapp');
    form.append('type', 'application/pdf');
    form.append(
      'file',
      new Blob([new Uint8Array(document.content)], { type: 'application/pdf' }),
      document.filename,
    );
    const uploaded = await call('media', { method: 'POST', body: form });
    const mediaId = uploaded.id;
    if (typeof mediaId !== 'string') throw new WhatsAppError('WhatsApp did not accept the PDF.');

    const sent = await call('messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        recipient_type: 'individual',
        to: whatsAppDigits(document.to),
        type: 'template',
        template: {
          name: config.templateName,
          language: { code: config.templateLanguage },
          components: [
            {
              type: 'header',
              parameters: [
                { type: 'document', document: { id: mediaId, filename: document.filename } },
              ],
            },
            {
              type: 'body',
              parameters: document.bodyValues.map((text) => ({ type: 'text', text })),
            },
          ],
        },
      }),
    });
    const messageId = (sent.messages as { id?: string }[] | undefined)?.[0]?.id;
    if (!messageId) throw new WhatsAppError('WhatsApp did not confirm the message.');
    return { messageId };
  };
}
