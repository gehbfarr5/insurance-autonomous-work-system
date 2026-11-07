import { AppError, toErrorPayload } from '../core/errors.ts';
import type { ToolExtra, ToolResult } from './types.ts';

const asText = (value: unknown): ToolResult => ({
  content: [{ type: 'text', text: JSON.stringify(value, null, 2) }],
});

export function wrapTool<T>(
  logger: any,
  name: string,
  handler: (args: T, extra?: ToolExtra) => Promise<unknown>,
): (args: T, extra?: ToolExtra) => Promise<ToolResult> {
  return async (args: T, extra?: ToolExtra): Promise<ToolResult> => {
    const startedAt = Date.now();
    try {
      const result = await handler(args, extra);
      logger?.debug?.('tool ok', { tool: name, ms: Date.now() - startedAt });
      return asText(result);
    } catch (err) {
      const payload = toErrorPayload(err);
      logger?.warn?.('tool failed', {
        tool: name,
        ms: Date.now() - startedAt,
        code: payload.error.code,
        detail: err instanceof AppError ? err.message : err instanceof Error ? err.name : typeof err,
      });
      return { ...asText(payload), isError: true };
    }
  };
}
