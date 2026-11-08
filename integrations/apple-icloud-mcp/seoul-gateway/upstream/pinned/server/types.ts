import type { ZodRawShape } from 'zod';
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js';

export interface ToolExtra {
  authInfo?: AuthInfo;
}

export interface ToolResult {
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
  [x: string]: unknown;
}

export interface ToolAnnotations {
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
}

export interface ToolConfig {
  title?: string;
  description: string;
  inputSchema: ZodRawShape;
  annotations?: ToolAnnotations;
}

export interface ToolRegistrar {
  registerTool(
    name: string,
    config: ToolConfig,
    handler: (args: any, extra?: ToolExtra) => Promise<ToolResult>,
  ): unknown;
}

export interface ToolDeps {
  sessions: any;
  logger: any;
}
