import { AppError, type ErrorCode, type AppErrorOptions } from '../../../src/types.ts';
export { AppError, type ErrorCode, type AppErrorOptions };

export interface ErrorPayload {
  error: {
    code: ErrorCode;
    message: string;
    hint?: string;
    retryable: boolean;
  };
}

/** 把任意抛出物转成给模型看的结构化载荷。cause 只留在日志里，不外泄。 */
export function toErrorPayload(err: unknown): ErrorPayload {
  if (err instanceof AppError) {
    const error: ErrorPayload['error'] = {
      code: err.code,
      message: err.message,
      retryable: err.retryable,
    };
    if (err.hint !== undefined) error.hint = err.hint;
    return { error };
  }
  return {
    error: {
      code: 'INTERNAL',
      message: '服务内部错误',
      retryable: false,
    },
  };
}
