/**
 * config.ts
 * Gateway configuration parsing and validation.
 */

import { AppError } from '../../../core/errors.js';
import type { BoundListConfig, MacServerGatewayConfig } from './types.js';

const DEFAULT_TIMEOUT_MS = 5000;
const DEFAULT_MAX_RESPONSE_SIZE = 2 * 1024 * 1024; // 2MB

export function validateGatewayConfig(raw: unknown): MacServerGatewayConfig {
  if (!raw || typeof raw !== 'object') {
    throw new AppError('INVALID_INPUT', '网关配置对象必须是非空 Object');
  }

  const candidate = raw as Record<string, unknown>;

  // 1. Endpoint validation
  const endpoint = candidate.macserverEndpoint;
  if (typeof endpoint !== 'string' || !endpoint.trim()) {
    throw new AppError('INVALID_INPUT', '配置缺失或无效的 macserverEndpoint (必须为非空字符串)');
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(endpoint.trim());
  } catch (cause) {
    throw new AppError('INVALID_INPUT', `macserverEndpoint URL 格式非法: ${endpoint}`, { cause });
  }

  if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
    throw new AppError('INVALID_INPUT', `macserverEndpoint 协议必须是 http 或 https, 当前为: ${parsedUrl.protocol}`);
  }

  const hostname = parsedUrl.hostname;
  if (!hostname || hostname === '0.0.0.0' || hostname === '::' || hostname === '*') {
    throw new AppError('INVALID_INPUT', `macserverEndpoint 禁止使用通配监听地址: ${hostname}`);
  }

  // 2. Auth token validation
  const token = candidate.authToken;
  if (typeof token !== 'string' || token.trim().length < 16) {
    throw new AppError(
      'INVALID_INPUT',
      '配置缺失或无效的 authToken (必须为至少 16 字符的非空字符串)'
    );
  }

  // 3. Timeout validation
  let timeoutMs = DEFAULT_TIMEOUT_MS;
  if (candidate.timeoutMs !== undefined) {
    const parsed = Number(candidate.timeoutMs);
    if (!Number.isInteger(parsed) || parsed < 500 || parsed > 60000) {
      throw new AppError('INVALID_INPUT', 'timeoutMs 必须在 500 到 60000 毫秒之间');
    }
    timeoutMs = parsed;
  }

  // 4. Max response size validation
  let maxResponseSizeBytes = DEFAULT_MAX_RESPONSE_SIZE;
  if (candidate.maxResponseSizeBytes !== undefined) {
    const parsed = Number(candidate.maxResponseSizeBytes);
    if (!Number.isInteger(parsed) || parsed < 1024 || parsed > 50 * 1024 * 1024) {
      throw new AppError('INVALID_INPUT', 'maxResponseSizeBytes 必须在 1KB 到 50MB 之间');
    }
    maxResponseSizeBytes = parsed;
  }

  // 5. Explicit List-to-Source binding validation
  if (!candidate.allowedLists || !Array.isArray(candidate.allowedLists) || candidate.allowedLists.length === 0) {
    throw new AppError(
      'INVALID_INPUT',
      '配置缺失或空的 allowedLists: 列表白名单与来源 ID 绑定必须显式配置，缺失即拒绝'
    );
  }

  const allowedLists: BoundListConfig[] = candidate.allowedLists.map((item, index) => {
    if (!item || typeof item !== 'object') {
      throw new AppError('INVALID_INPUT', `allowedLists[${index}] 必须为包含 listId 与 expectedSourceId 的对象`);
    }
    const obj = item as Record<string, unknown>;
    const listId = typeof obj.listId === 'string' ? obj.listId.trim() : '';
    const expectedSourceId = typeof obj.expectedSourceId === 'string' ? obj.expectedSourceId.trim() : '';

    if (!listId) {
      throw new AppError('INVALID_INPUT', `allowedLists[${index}].listId 缺失或为空`);
    }
    if (!expectedSourceId) {
      throw new AppError(
        'INVALID_INPUT',
        `allowedLists[${index}] 缺失显式 expectedSourceId 绑定: 必须显式绑定来源 ID，缺失即拒绝`
      );
    }

    return {
      listId,
      expectedSourceId,
      expectedSourceName: typeof obj.expectedSourceName === 'string' && obj.expectedSourceName.trim()
        ? obj.expectedSourceName.trim()
        : 'iCloud',
      expectedSourceType: typeof obj.expectedSourceType === 'string' && obj.expectedSourceType.trim()
        ? obj.expectedSourceType.trim()
        : 'calDAV',
    };
  });

  return {
    macserverEndpoint: parsedUrl.origin,
    authToken: token.trim(),
    timeoutMs,
    maxResponseSizeBytes,
    allowedLists,
    expectedSourceType: typeof candidate.expectedSourceType === 'string' && candidate.expectedSourceType.trim()
      ? candidate.expectedSourceType.trim()
      : 'calDAV',
    expectedSourceName: typeof candidate.expectedSourceName === 'string' && candidate.expectedSourceName.trim()
      ? candidate.expectedSourceName.trim()
      : 'iCloud',
  };
}

export function loadGatewayConfigFromEnv(env: Record<string, string | undefined> = process.env): MacServerGatewayConfig {
  const endpoint = env.MACSERVER_EVENTKIT_ENDPOINT || env.EVENTKIT_GATEWAY_ENDPOINT || env.EVENTKIT_BRIDGE_ENDPOINT || 'http://127.0.0.1:18765';
  const token = env.MACSERVER_EVENTKIT_TOKEN || env.EVENTKIT_BRIDGE_AUTH_TOKEN || env.EVENTKIT_BRIDGE_TOKEN || '';
  const timeoutMs = env.MACSERVER_EVENTKIT_TIMEOUT_MS || env.EVENTKIT_BRIDGE_TIMEOUT_MS
    ? Number(env.MACSERVER_EVENTKIT_TIMEOUT_MS || env.EVENTKIT_BRIDGE_TIMEOUT_MS)
    : DEFAULT_TIMEOUT_MS;
  const maxResponseSizeBytes = (env.MACSERVER_EVENTKIT_MAX_RESPONSE_SIZE || env.EVENTKIT_BRIDGE_MAX_RESPONSE_SIZE)
    ? Number(env.MACSERVER_EVENTKIT_MAX_RESPONSE_SIZE || env.EVENTKIT_BRIDGE_MAX_RESPONSE_SIZE)
    : DEFAULT_MAX_RESPONSE_SIZE;

  let allowedLists: BoundListConfig[] = [];
  const rawLists = env.MACSERVER_EVENTKIT_ALLOWED_LISTS || env.EVENTKIT_ALLOWED_LISTS;
  if (rawLists && rawLists.trim()) {
    const trimmed = rawLists.trim();
    if (trimmed.startsWith('[')) {
      try {
        allowedLists = JSON.parse(trimmed);
      } catch (cause) {
        throw new AppError('INVALID_INPUT', '环境变量 MACSERVER_EVENTKIT_ALLOWED_LISTS / EVENTKIT_ALLOWED_LISTS JSON 解析失败', { cause });
      }
    } else {
      allowedLists = trimmed.split(',').map((entry) => {
        const parts = entry.split(':').map((s) => s.trim());
        const listId = parts[0] || '';
        const expectedSourceId = parts[1] || '';
        const expectedSourceName = parts[2] || 'iCloud';
        const expectedSourceType = parts[3] || 'calDAV';
        return { listId, expectedSourceId, expectedSourceName, expectedSourceType };
      });
    }
  }

  return validateGatewayConfig({
    macserverEndpoint: endpoint,
    authToken: token,
    timeoutMs,
    maxResponseSizeBytes,
    allowedLists,
    expectedSourceType: env.MACSERVER_EVENTKIT_EXPECTED_SOURCE_TYPE || env.EVENTKIT_EXPECTED_SOURCE_TYPE || 'calDAV',
    expectedSourceName: env.MACSERVER_EVENTKIT_EXPECTED_SOURCE_NAME || env.EVENTKIT_EXPECTED_SOURCE_NAME || 'iCloud',
  });
}
