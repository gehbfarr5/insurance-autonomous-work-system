/**
 * transport.ts
 * EventKitReadonlyTransport communicating with MacServer EventKit Bridge over HTTP.
 */

import { AppError } from '../../../core/errors.js';
import type { MacServerGatewayConfig, RemindersList, ReminderItem } from './types.js';

export function parseBridgeDate(raw: unknown): string | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 返回非法数值日期: ${raw}`);
    }
    const COCOA_OFFSET_SECONDS = 978307200;
    const epochMs = (raw + COCOA_OFFSET_SECONDS) * 1000;
    const d = new Date(epochMs);
    if (Number.isNaN(d.getTime())) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 转换 Cocoa 纪元日期失败: ${raw}`);
    }
    return d.toISOString();
  }
  if (typeof raw === 'string') {
    const trimmed = raw.trim();
    if (!trimmed) return undefined;
    const d = new Date(trimmed);
    if (Number.isNaN(d.getTime())) {
      throw new AppError('UPSTREAM_ERROR', `Bridge 返回无法识别的日期字符串: ${raw}`);
    }
    return d.toISOString();
  }
  throw new AppError('UPSTREAM_ERROR', `Bridge 返回未知日期数据类型: ${typeof raw}`);
}

export class EventKitReadonlyTransport {
  private readonly config: MacServerGatewayConfig;

  constructor(config: MacServerGatewayConfig) {
    this.config = config;
  }

  async healthCheck(): Promise<boolean> {
    const url = `${this.config.macserverEndpoint}/health`;
    try {
      const res = await this.fetchWithTimeout(url, { method: 'GET' });
      return res.status === 200;
    } catch {
      return false;
    }
  }

  async fetchListsMetadata(): Promise<RemindersList[]> {
    const url = `${this.config.macserverEndpoint}/reminders/lists`;
    const res = await this.fetchWithTimeout(url, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${this.config.authToken}`,
        Accept: 'application/json',
      },
    });

    if (res.status === 401) {
      throw new AppError('AUTH_FAILED', 'MacServer EventKit Bridge 鉴权失败: 提供的 Bearer Token 无效或已过期');
    }
    if (res.status === 403) {
      throw new AppError('PERMISSION_DENIED', 'MacServer EventKit 权限拒绝: Bridge 生产授权开关关闭或无权限访问');
    }
    if (!res.ok) {
      throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 响应异常 (HTTP ${res.status})`);
    }

    const data = await this.readBoundedJson(res);
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
    const res = await this.fetchWithTimeout(url, {
      method: 'GET',
      headers: {
        Authorization: `Bearer ${this.config.authToken}`,
        Accept: 'application/json',
      },
    });

    if (res.status === 401) {
      throw new AppError('AUTH_FAILED', 'MacServer EventKit Bridge 鉴权失败: Bearer Token 无效');
    }
    if (res.status === 403) {
      throw new AppError('PERMISSION_DENIED', `MacServer EventKit 权限拒绝: 列表 ${trimmedId} 访问受限`);
    }
    if (res.status === 404) {
      throw new AppError('NOT_FOUND', `MacServer 提醒列表未找到: ${trimmedId}`);
    }
    if (!res.ok) {
      throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 获取条目失败 (HTTP ${res.status})`);
    }

    const data = await this.readBoundedJson(res);
    if (!Array.isArray(data)) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit Bridge 返回的提醒条目数据结构非法: 期望为 Array');
    }
    return data as ReminderItem[];
  }

  rejectWrite(operation: 'create' | 'update' | 'delete'): never {
    throw new AppError(
      'PERMISSION_DENIED',
      `MacServer EventKit 网关为只读服务: 提醒事项 ${operation} 写操作已在客户端拦截 (零转发/零VTODO回落)`
    );
  }

  private async fetchWithTimeout(url: string, init: RequestInit): Promise<Response> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);

    try {
      return await fetch(url, {
        ...init,
        signal: controller.signal,
      });
    } catch (cause: any) {
      if (cause?.name === 'AbortError') {
        throw new AppError('UPSTREAM_ERROR', `MacServer EventKit Bridge 请求超时 (${this.config.timeoutMs}ms): ${url}`, {
          cause,
          retryable: true,
        });
      }
      throw new AppError('UPSTREAM_ERROR', `无法连接到 MacServer EventKit Bridge: ${cause?.message || cause}`, {
        cause,
        retryable: true,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  private async readBoundedJson(res: Response): Promise<unknown> {
    const contentLength = res.headers.get('content-length');
    if (contentLength && parseInt(contentLength, 10) > this.config.maxResponseSizeBytes) {
      throw new AppError(
        'UPSTREAM_ERROR',
        `MacServer EventKit 响应体积超过上限: ${contentLength} 字节 (最大允许: ${this.config.maxResponseSizeBytes} 字节)`
      );
    }

    if (!res.body) {
      const text = await res.text();
      return this.safeJsonParse(text);
    }

    const reader = res.body.getReader();
    const chunks: Uint8Array[] = [];
    let receivedBytes = 0;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (value) {
          receivedBytes += value.length;
          if (receivedBytes > this.config.maxResponseSizeBytes) {
            try { await reader.cancel(); } catch {}
            throw new AppError(
              'UPSTREAM_ERROR',
              `MacServer EventKit 响应流累计超过上限: ${receivedBytes} 字节 (最大允许: ${this.config.maxResponseSizeBytes} 字节)`
            );
          }
          chunks.push(value);
        }
      }
    } catch (cause: any) {
      if (cause instanceof AppError) throw cause;
      if (cause?.name === 'AbortError') {
        throw new AppError('UPSTREAM_ERROR', `读取 MacServer EventKit 响应体超时 (${this.config.timeoutMs}ms)`, {
          cause,
          retryable: true,
        });
      }
      throw new AppError('UPSTREAM_ERROR', `读取 MacServer EventKit 响应流异常: ${cause?.message || cause}`, { cause });
    } finally {
      clearTimeout(timer);
    }

    const totalBuffer = new Uint8Array(receivedBytes);
    let offset = 0;
    for (const chunk of chunks) {
      totalBuffer.set(chunk, offset);
      offset += chunk.length;
    }

    const text = new TextDecoder('utf-8').decode(totalBuffer);
    return this.safeJsonParse(text);
  }

  private safeJsonParse(text: string): unknown {
    try {
      return JSON.parse(text);
    } catch (cause) {
      throw new AppError('UPSTREAM_ERROR', 'MacServer EventKit 响应 JSON 解析失败', { cause });
    }
  }
}
