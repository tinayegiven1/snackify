type LogLevel = 'info' | 'warn' | 'error';
type LogFields = Record<string, unknown>;

/**
 * Minimal structured (JSON-lines) logger.
 * Never pass passwords, tokens, or connection strings in `fields`.
 */
// Google Cloud Logging reads the level from "severity".
const SEVERITY: Record<LogLevel, string> = { info: 'INFO', warn: 'WARNING', error: 'ERROR' };

function write(level: LogLevel, message: string, fields: LogFields = {}): void {
  const line = JSON.stringify({
    level,
    severity: SEVERITY[level],
    time: new Date().toISOString(),
    message,
    ...fields,
  });
  if (level === 'error') {
    console.error(line);
  } else {
    console.log(line);
  }
}

export const logger = {
  info: (message: string, fields?: LogFields) => write('info', message, fields),
  warn: (message: string, fields?: LogFields) => write('warn', message, fields),
  error: (message: string, fields?: LogFields) => write('error', message, fields),
};
