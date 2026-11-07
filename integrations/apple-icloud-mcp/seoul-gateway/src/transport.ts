/**
 * transport.ts
 * Readonly HTTP transport client connecting Seoul MCP to MacServer EventKit Bridge.
 * 
 * Invariants & Hardening:
 * 1. Strictly READ-ONLY: Never sends POST, PUT, PATCH, DELETE requests.
 * 2. Unified Deadline: A single abort timer spans connection establishment, header parsing,
 *    and streaming response body downloading until completion.
 * 3. Connection & Socket Release: On timeout or abort, active body reader is cancelled and
 *    released immediately to prevent socket exhaustion.
 * 4. Max Response Size Enforcement: Byte stream is metered; exceeding limit aborts immediately.
 * 5. Explicit Failures: Stalled streams, network errors, timeouts, 401, 403, 404, 5xx throw AppError;
 *    never masquerading as empty arrays.
 */

import {
  AppError,
  type BridgeHealthResponse,
  type MacServerGatewayConfig,
  type ReminderItem,
  type RemindersList,
} from './types.ts';

export const COCOA_OFFSET_SECONDS = 978307200;

export function parseBridgeDate(raw: unknown): string | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 返回非法数值日期: ${raw}`);
    }
    const epochMs = (raw + COCOA_OFFSET_SECONDS) * 1000;
    const d = new Date(epochMs);
    if (Number.isNaN(d.getTime())) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 转换 Cocoa 纪元日期失败 (非法日期): ${raw}`);
    }
    return d.toISOString();
  }
  if (typeof raw === 'string') {
    const trimmed = raw.trim();
    if (!trimmed) {
      throw new AppError('UPSTREAM_ERROR', 'Bridge 返回空日期字符串 (非法日期)');
    }
    const d = new Date(trimmed);
    if (Number.isNaN(d.getTime())) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 返回非法日期编码或格式字符串: ${raw}`);
    }
    return d.toISOString();
  }
  throw new AppError('UPSTREAM_ERROR', `Bridge 返回非法日期数据类型: ${typeof raw}`);
}

export type TransportFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export class EventKitReadonlyTransport {
  private readonly config: MacServerGatewayConfig;
  private readonly fetchFn: TransportFetch;

  constructor(config: MacServerGatewayConfig, customFetch?: TransportFetch) {
    this.config = config;
    this.fetchFn = customFetch || globalThis.fetch.bind(globalThis);
  }

  async healthCheck(): Promise<BridgeHealthResponse> {
    const url = `${this.config.macserverEndpoint}/health`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);
    try {
      const res = await this.fetchFn(url, { method: 'GET', signal: controller.signal });
      if (!res.ok) {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 健康检查失败 (HTTP ${res.status})`);
      }
      return (await res.json()) as BridgeHealthResponse;
    } catch (cause: any) {
      if (cause instanceof AppError) throw cause;
      throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 无法连接: ${cause?.message || cause}`, { cause });
    } finally {
      clearTimeout(timer);
    }
  }

  async fetchListsMetadata(): Promise<RemindersList[]> {
    const url = `${this.config.macserverEndpoint}/reminders/lists`;
    const headers = {
      Authorization: `Bearer ${this.config.authToken}`,
      Accept: 'application/json',
      'User-Agent': 'Seoul-MCP-Gateway/1.0.0 (Readonly)',
    };

    const data = await this.getBoundedJson<unknown>(url, headers);
    if (!Array.isArray(data)) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的列表数据结构非法: 期望为 Array');
    }
    return data as RemindersList[];
  }

  async fetchReminders(listId: string): Promise<ReminderItem[]> {
    const trimmedId = listId.trim();
    if (!trimmedId) {
      throw new AppError('INVALID_INPUT', 'listId 不能为空');
    }

    const isAllowed = this.config.allowedLists.some((item) => item.listId === trimmedId);
    if (!isAllowed) {
      throw new AppError('PERMISSION_DENIED', `列表未在网关白名单中: ${trimmedId} (必须显式配置绑定)`, {
        hint: '请在 MACSERVER_EVENTKIT_ALLOWED_LISTS 中配置该列表及来源 ID 绑定',
      });
    }

    const url = `${this.config.macserverEndpoint}/reminders/lists/${encodeURIComponent(trimmedId)}/items`;
    const headers = {
      Authorization: `Bearer ${this.config.authToken}`,
      Accept: 'application/json',
      'User-Agent': 'Seoul-MCP-Gateway/1.0.0 (Readonly)',
    };

    const data = await this.getBoundedJson<unknown>(url, headers);
    if (!Array.isArray(data)) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的提醒条目数据结构非法: 期望为 Array');
    }
    return data as ReminderItem[];
  }

  async rejectWrite(operationName: string): Promise<never> {
    throw new AppError(
      'PERMISSION_DENIED',
      `[WriteRejected] MacServer EventKit Gateway 运行于严格只读模式，禁止执行写操作: ${operationName}`
    );
  }

  /**
   * Unified GET execution spanning request, headers, and full body stream download
   * under a single deadline timer. Ensures prompt socket release on timeout/abort.
   */
  private async getBoundedJson<T>(url: string, headers: Record<string, string>): Promise<T> {
    const controller = new AbortController();
    let isTimedOut = false;
    const timer = setTimeout(() => {
      isTimedOut = true;
      controller.abort();
    }, this.config.timeoutMs);

    let activeReader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    const onAbort = () => {
      if (activeReader) {
        try { activeReader.cancel(); } catch {}
      }
    };
    controller.signal.addEventListener('abort', onAbort, { once: true });

    try {
      let res: Response;
      try {
        res = await this.fetchFn(url, {
          method: 'GET',
          headers,
          signal: controller.signal,
        });
      } catch (cause: any) {
        if (isTimedOut || controller.signal.aborted || cause?.name === 'AbortError') {
          throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求/读取超时 (${this.config.timeoutMs}ms): ${url}`, {
            cause,
            retryable: true,
          });
        }
        throw new AppError('UPSTREAM_ERROR', `无法连接到 MacServer EventKit Bridge: ${cause?.message || cause}`, {
          cause,
          retryable: true,
        });
      }

      if (res.status === 401) {
        throw new AppError('AUTH_FAILED', 'MacServer EventKit Bridge 鉴权失败: 提供的 Bearer Token 无效或已过期');
      }
      if (res.status === 403) {
        throw new AppError('PERMISSION_DENIED', 'MacServer EventKit 权限拒绝: Bridge 生产授权开关关闭或无权限访问');
      }
      if (res.status === 404) {
        throw new AppError('NOT_FOUND', `MacServer 提醒列表未找到: ${url}`);
      }
      if (!res.ok) {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 响应异常 (HTTP ${res.status})`);
      }

      const contentLength = res.headers.get('content-length');
      if (contentLength && parseInt(contentLength, 10) > this.config.maxResponseSizeBytes) {
        throw new AppError(
          'UPSTREAM_ERROR',
          `MacServer EventKit Bridge 响应体大小 (${contentLength} bytes) 超出限制 (${this.config.maxResponseSizeBytes} bytes)`
        );
      }

      let text = '';
      if (!res.body) {
        text = await res.text();
      } else {
        const reader = res.body.getReader();
        activeReader = reader;
        const chunks: Uint8Array[] = [];
        let receivedBytes = 0;

        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value) {
              receivedBytes += value.length;
              if (receivedBytes > this.config.maxResponseSizeBytes) {
                controller.abort();
                throw new AppError(
                  'UPSTREAM_ERROR',
                  `MacServer EventKit Bridge 响应体大小 (${receivedBytes} bytes) 超出限制 (${this.config.maxResponseSizeBytes} bytes)`
                );
              }
              chunks.push(value);
            }
          }
        } finally {
          activeReader = undefined;
          try { reader.releaseLock(); } catch {}
        }

        if (isTimedOut || controller.signal.aborted) {
          throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求/读取超时 (${this.config.timeoutMs}ms): ${url}`, {
            retryable: true,
          });
        }

        const totalBuffer = new Uint8Array(receivedBytes);
        let offset = 0;
        for (const chunk of chunks) {
          totalBuffer.set(chunk, offset);
          offset += chunk.length;
        }
        text = new TextDecoder('utf-8').decode(totalBuffer);
      }

      if (isTimedOut || controller.signal.aborted) {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求/读取超时 (${this.config.timeoutMs}ms): ${url}`, {
          retryable: true,
        });
      }

      if (!text.trim()) {
        throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回空响应体');
      }

      try {
        return JSON.parse(text) as T;
      } catch (cause) {
        throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的成功响应非有效 JSON', { cause });
      }
    } catch (err: any) {
      if (err instanceof AppError) throw err;
      if (isTimedOut || controller.signal.aborted || err?.name === 'AbortError' || err?.message?.includes('aborted')) {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求/读取超时 (${this.config.timeoutMs}ms): ${url}`, {
          cause: err,
          retryable: true,
        });
      }
      throw new AppError('UPSTREAM_ERROR', `读取 MacServer EventKit 响应异常: ${err?.message || err}`, { cause: err });
    } finally {
      controller.signal.removeEventListener('abort', onAbort);
      clearTimeout(timer);
    }
  }
}
