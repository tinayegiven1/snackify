/** Escapes % and _ so text is matched literally inside an ILIKE pattern. */
export const escapeLike = (text: string) => text.replace(/[\\%_]/g, (char) => `\\${char}`);
