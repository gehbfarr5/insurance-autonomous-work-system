/**
 * config.ts
 * Gateway configuration parsing and validation.
 */

import { AppError, type MacServerGatewayConfig } from './types.ts';

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
  let timeoutMs = 5000;
  if (candidate.timeoutMs !== undefined) {
    const parsed = Number(candidate.timeoutMs);
    if (!Number.isInteger(parsed) || parsed < 500 || parsed > 60000) {
      throw new AppError('INVALID_INPUT', 'timeoutMs 必须在 500 到 60000 毫秒之间');
    }
    timeoutMs = parsed;
  }

  // 4. Allowed list IDs validation
  let allowedListIds: string[] | undefined;
  if (candidate.allowedListIds !== undefined) {
    if (!Array.isArray(candidate.allowedListIds)) {
      throw new AppError('INVALID_INPUT', 'allowedListIds 必须是字符串数组');
    }
    allowedListIds = candidate.allowedListIds.map((id, index) => {
      if (typeof id !== 'string' || !id.trim()) {
        throw new AppError('INVALID_INPUT', `allowedListIds[${index}] 必须为非空字符串`);
      }
      return id.trim();
    });
  }

  // 5. Expected source validation
  const expectedSourceType = typeof candidate.expectedSourceType === 'string' && candidate.expectedSourceType.trim()
    ? candidate.expectedSourceType.trim()
    : 'calDAV';

  const expectedSourceName = typeof candidate.expectedSourceName === 'string' && candidate.expectedSourceName.trim()
    ? candidate.expectedSourceName.trim()
    : 'iCloud';

  return {
    macserverEndpoint: parsedUrl.origin,
    authToken: token.trim(),
    timeoutMs,
    allowedListIds,
    expectedSourceType,
    expectedSourceName,
  };
}

/**
 * Loads gateway config from environment variables.
 */
export function loadGatewayConfigFromEnv(env: Record<string, string | undefined> = process.env): MacServerGatewayConfig {
  const endpoint = env.MACSERVER_EVENTKIT_ENDPOINT || 'http://127.0.0.1:18765';
  const token = env.MACSERVER_EVENTKIT_TOKEN || '';
  const timeoutMs = env.MACSERVER_EVENTKIT_TIMEOUT_MS ? Number(env.MACSERVER_EVENTKIT_TIMEOUT_MS) : 5000;
  
  let allowedListIds: string[] | undefined;
  if (env.MACSERVER_EVENTKIT_ALLOWED_LIST_IDS) {
    allowedListIds = env.MACSERVER_EVENTKIT_ALLOWED_LIST_IDS.split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  }

  return validateGatewayConfig({
    macserverEndpoint: endpoint,
    authToken: token,
    timeoutMs,
    allowedListIds,
    expectedSourceType: env.MACSERVER_EVENTKIT_EXPECTED_SOURCE_TYPE || 'calDAV',
    expectedSourceName: env.MACSERVER_EVENTKIT_EXPECTED_SOURCE_NAME || 'iCloud',
  });
}
