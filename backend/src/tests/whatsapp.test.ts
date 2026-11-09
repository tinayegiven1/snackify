import { describe, expect, it } from 'vitest';
import { cloudApiSender, whatsAppDigits, WhatsAppError } from '../modules/whatsapp/whatsapp.js';

const config = {
  accessToken: 'test-token-that-is-long-enough',
  phoneNumberId: '1234567890',
  templateName: 'goods_received_note',
  templateLanguage: 'en',
  apiVersion: 'v23.0',
};

const document = {
  to: '+263 (77) 123-4567',
  filename: 'GRN000001.pdf',
  content: Buffer.from('%PDF-1.4 note'),
  bodyValues: ['GRN000001', 'Avondale Shop', '8 Nov 2026'],
};

function fakeFetch(answers: { status: number; body: unknown }[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const answer = answers.shift() ?? { status: 500, body: {} };
    return new Response(JSON.stringify(answer.body), { status: answer.status });
  }) as unknown as typeof fetch;
  return { calls, fetchImpl };
}

describe('WhatsApp Cloud API sender', () => {
  it('uploads the PDF, then sends the template with it as the document header', async () => {
    const { calls, fetchImpl } = fakeFetch([
      { status: 200, body: { id: 'media-1' } },
      { status: 200, body: { messages: [{ id: 'wamid.ABC' }] } },
    ]);
    const result = await cloudApiSender(config, fetchImpl)(document);

    expect(result).toEqual({ messageId: 'wamid.ABC' });
    expect(calls.map((c) => c.url)).toEqual([
      'https://graph.facebook.com/v23.0/1234567890/media',
      'https://graph.facebook.com/v23.0/1234567890/messages',
    ]);
    expect(calls[0]?.init.headers).toMatchObject({
      Authorization: 'Bearer test-token-that-is-long-enough',
    });
    const upload = calls[0]?.init.body as FormData;
    expect(upload.get('messaging_product')).toBe('whatsapp');
    expect((upload.get('file') as File).name).toBe('GRN000001.pdf');

    expect(JSON.parse(calls[1]?.init.body as string)).toEqual({
      messaging_product: 'whatsapp',
      recipient_type: 'individual',
      to: '263771234567',
      type: 'template',
      template: {
        name: 'goods_received_note',
        language: { code: 'en' },
        components: [
          {
            type: 'header',
            parameters: [
              { type: 'document', document: { id: 'media-1', filename: 'GRN000001.pdf' } },
            ],
          },
          {
            type: 'body',
            parameters: [
              { type: 'text', text: 'GRN000001' },
              { type: 'text', text: 'Avondale Shop' },
              { type: 'text', text: '8 Nov 2026' },
            ],
          },
        ],
      },
    });
  });

  it("explains WhatsApp's refusal without the access token", async () => {
    const { fetchImpl } = fakeFetch([
      { status: 200, body: { id: 'media-1' } },
      {
        status: 400,
        body: {
          error: {
            message: '(#132001) Template name does not exist in the translation',
            code: 132001,
            error_data: { details: 'template name (goods_received_note) does not exist in en' },
          },
        },
      },
    ]);
    const sending = cloudApiSender(config, fetchImpl)(document);
    await expect(sending).rejects.toBeInstanceOf(WhatsAppError);
    await expect(sending).rejects.toThrow(
      'WhatsApp refused the message (code 132001): template name (goods_received_note) does not exist in en',
    );
    await expect(sending).rejects.not.toThrow(config.accessToken);
  });

  it('reports an unreachable WhatsApp plainly', async () => {
    const fetchImpl = (async () => {
      throw new TypeError('fetch failed');
    }) as unknown as typeof fetch;
    await expect(cloudApiSender(config, fetchImpl)(document)).rejects.toThrow(
      'WhatsApp could not be reached. Try sending again later.',
    );
  });

  it('keeps only the digits of a number', () => {
    expect(whatsAppDigits('+263 (77) 123-4567')).toBe('263771234567');
  });
});
