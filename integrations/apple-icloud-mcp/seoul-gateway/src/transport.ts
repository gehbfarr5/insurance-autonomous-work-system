/**
 * transport.ts
 * Readonly HTTP transport client connecting Seoul MCP to MacServer EventKit Bridge.
 * 
 * Invariants:
 * 1. Strictly READ-ONLY: Never sends POST, PUT, PATCH, DELETE requests.
 * 2. Explicit failures: Network failures, timeouts, 401, 403, 404, 5xx, or corrupted JSON
 *    MUST throw AppError loudly; never masquerade as an empty list or success.
 * 3. Scope and identity: All requests carry restricted Bearer token and Accept headers.
 */

import {
  AppError,
  type BridgeHealthResponse,
  type MacServerGatewayConfig,
  type ReminderItem,
  type RemindersList,
} from './types.ts';

export interface TransportFetch {
  (input: string | URL | Request, init?: RequestInit): Promise<Response>;
}

export class EventKitReadonlyTransport {
  private readonly endpoint: string;
  private readonly token: string;
  private readonly timeoutMs: number;
  private readonly fetchFn: TransportFetch;

  constructor(config: MacServerGatewayConfig, customFetch?: TransportFetch) {
    this.endpoint = config.macserverEndpoint.replace(/\/+$/, '');
    this.token = config.authToken;
    this.timeoutMs = config.timeoutMs;
    // Allow injecting custom fetch (e.g. for testing)
    this.fetchFn = customFetch || globalThis.fetch.bind(globalThis);
  }

  /**
   * Health check endpoint probe (GET /health).
   */
  async healthCheck(): Promise<BridgeHealthResponse> {
    return this.get<BridgeHealthResponse>('/health');
  }

  /**
   * Fetch reminder lists metadata (GET /reminders/lists).
   * FIX-R4A-01: Metadata-only, zero reminder content or counts.
   */
  async fetchListsMetadata(): Promise<RemindersList[]> {
    const data = await this.get<unknown>('/reminders/lists');
    if (!Array.isArray(data)) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的列表元数据不是 JSON 数组');
    }
    return data as RemindersList[];
  }

  /**
   * Fetch reminder items for a specific list (GET /reminders/lists/{listID}/items).
   * FIX-R4A-02: Bound test/allowed list items only.
   */
  async fetchReminders(listId: string): Promise<ReminderItem[]> {
    if (!listId || typeof listId !== 'string' || !listId.trim()) {
      throw new AppError('INVALID_INPUT', 'fetchReminders 必须指定非空 listId');
    }
    const cleanId = encodeURIComponent(listId.trim());
    const data = await this.get<unknown>(`/reminders/lists/${cleanId}/items`);
    if (!Array.isArray(data)) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的提醒条目不是 JSON 数组');
    }
    return data as ReminderItem[];
  }

  /**
   * Explicit client-side write blocker.
   * Rejects any attempt to forward write requests to MacServer EventKit.
   */
  async rejectWrite(operationName: string): Promise<never> {
    throw new AppError(
      'PERMISSION_DENIED',
      `[WriteRejected] MacServer EventKit Gateway 运行于严格只读模式，禁止执行写操作: ${operationName}`
    );
  }

  /**
   * Core HTTP GET execution with timeout and structured error mapping.
   */
  private async get<T>(path: string): Promise<T> {
    const url = `${this.endpoint}${path}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    let response: Response;
    try {
      response = await this.fetchFn(url, {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: 'application/json',
          'User-Agent': 'Seoul-MCP-Gateway/1.0.0 (Readonly)',
        },
        signal: controller.signal,
      });
    } catch (err: unknown) {
      if (err instanceof Error && (err.name === 'AbortError' || err.message?.includes('aborted') || err.message?.includes('timeout'))) {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求超时 (${this.timeoutMs}ms): ${path}`, {
          retryable: true,
          cause: err,
        });
      }
      throw new AppError(
        'UPSTREAM_ERROR',
        `无法连接到 MacServer EventKit Bridge: ${err instanceof Error ? err.message : String(err)}`,
        { retryable: true, cause: err }
      );
    } finally {
      clearTimeout(timer);
    }

    // Process HTTP response
    const status = response.status;
    let rawText = '';
    try {
      rawText = await response.text();
    } catch (cause) {
      throw new AppError('UPSTREAM_ERROR', '读取 MacServer EventKit Bridge 响应体失败', { cause });
    }

    let parsedBody: Record<string, unknown> | unknown[] | null = null;
    if (rawText.trim().length > 0) {
      try {
        parsedBody = JSON.parse(rawText);
      } catch (cause) {
        if (status >= 200 && status < 300) {
          throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的成功响应非有效 JSON', { cause });
        }
      }
    }

    if (status === 200) {
      if (parsedBody === null) {
        throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回空响应体');
      }
      return parsedBody as T;
    }

    // Extract desensitized error information if available
    let errorCode = 'UPSTREAM_ERROR';
    let errorMessage = `MacServer EventKit Bridge 响应异常 (HTTP ${status})`;
    if (parsedBody && typeof parsedBody === 'object' && !Array.isArray(parsedBody)) {
      if (typeof parsedBody.code === 'string') errorCode = parsedBody.code;
      if (typeof parsedBody.error === 'string') errorMessage = parsedBody.error;
    }

    switch (status) {
      case 401:
        throw new AppError('AUTH_FAILED', `MacServer EventKit 鉴权失败: ${errorMessage}`, {
          hint: '核验 ~/.config/muse-macserver/bridge.env 中的 Bearer Token 是否与网关一致',
        });
      case 403:
        throw new AppError('PERMISSION_DENIED', `MacServer EventKit 权限拒绝: ${errorMessage}`, {
          hint: '核验 MacServer 激活开关 (EVENTKIT_BRIDGE_PRODUCTION_AUTHORIZED) 及列表允许名单',
        });
      case 404:
        throw new AppError('NOT_FOUND', `MacServer EventKit 对象不存在: ${errorMessage}`, {
          hint: '调用 reminders_lists 确认目标 list_id 是否有效',
        });
      case 405:
        throw new AppError('PERMISSION_DENIED', `MacServer EventKit 拒绝非 GET 请求: ${errorMessage}`);
      case 429:
        throw new AppError('RATE_LIMITED', `MacServer EventKit 速率超限: ${errorMessage}`, { retryable: true });
      case 504:
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit 超时 (504 Gateway Timeout): ${errorMessage}`, { retryable: true });
      default:
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit 上游错误 (HTTP ${status}, code: ${errorCode}): ${errorMessage}`, {
          retryable: status >= 500,
        });
    }
  }
}
