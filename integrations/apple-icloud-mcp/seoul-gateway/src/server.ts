/**
 * server.ts
 * Real MCP HTTP Gateway Server for Seoul -> MacServer Reminders Readonly Gateway.
 * 
 * Provides:
 * - Real /health endpoint answering HTTP 200 OK
 * - Real MCP Streamable HTTP / SSE endpoints (/sse and /message)
 * - Real ToolRegistrar assembly via registerReminderTools (Pinned commit 92bd313)
 * - Strict client-side write rejection (PERMISSION_DENIED)
 */

import http from 'node:http';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import { loadGatewayConfigFromEnv } from './config.ts';
import { EventKitReadonlyTransport } from './transport.ts';
import { createMacServerReminderService } from './service.ts';
import { registerReminderTools, type ToolRegistrar } from '../upstream/pinned/modules/reminders/tools.ts';

const PORT = parseInt(process.env.PORT || '17733', 10);
const HOST = process.env.HOST || '0.0.0.0';

console.log(`[SeoulGatewayServer] Initializing on ${HOST}:${PORT}...`);

// 1. Load gateway configuration
const config = loadGatewayConfigFromEnv(process.env);
console.log(`[SeoulGatewayServer] Loaded config: target=${config.macserverEndpoint}, allowedLists=${config.allowedLists.length}`);

// 2. Initialize Transport and ReminderService
const transport = new EventKitReadonlyTransport(config);
const reminderService = createMacServerReminderService({ transport, config });

// 3. Initialize McpServer
const mcpServer = new McpServer({
  name: 'apple-icloud-mcp-readonly-gateway',
  version: '1.0.0',
});

// 4. Assemble Reminder tools using pinned upstream registrar
const mockSessions = {
  get: (sessionId: string) => ({ id: sessionId || 'default-session', account: 'default-account' }),
};

const mockLogger = {
  debug: (msg: string, meta?: any) => console.log(`[DEBUG] ${msg}`, meta ?? ''),
  info: (msg: string, meta?: any) => console.log(`[INFO] ${msg}`, meta ?? ''),
  warn: (msg: string, meta?: any) => console.warn(`[WARN] ${msg}`, meta ?? ''),
  error: (msg: string, meta?: any) => console.error(`[ERROR] ${msg}`, meta ?? ''),
};

const toolRegistrar: ToolRegistrar = {
  registerTool(name, toolConfig, handler) {
    console.log(`[SeoulGatewayServer] Registering tool: ${name}`);
    mcpServer.tool(
      name,
      toolConfig.description,
      toolConfig.inputSchema as any,
      async (args: any, extra: any) => {
        const res = await handler(args, extra);
        return res as any;
      }
    );
  },
};

registerReminderTools(toolRegistrar, {
  sessions: mockSessions as any,
  logger: mockLogger,
  reminderFor: () => reminderService,
});

// 5. Active SSE transports map
const transports = new Map<string, SSEServerTransport>();

// 6. Create HTTP Server
const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);

  // Health endpoint: Real HTTP 200 OK response
  if (url.pathname === '/health') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-cache',
    });
    res.end(
      JSON.stringify({
        status: 'ok',
        service: 'seoul-macserver-readonly-gateway',
        version: '1.0.0',
        mode: 'readonly',
        allowedLists: config.allowedLists.length,
        timestamp: new Date().toISOString(),
      })
    );
    return;
  }

  // SSE connection endpoint for MCP
  if (url.pathname === '/sse') {
    console.log('[SeoulGatewayServer] Client connecting via SSE...');
    const sseTransport = new SSEServerTransport('/message', res);
    const sessionId = sseTransport.sessionId;
    transports.set(sessionId, sseTransport);

    sseTransport.onclose = () => {
      console.log(`[SeoulGatewayServer] SSE session closed: ${sessionId}`);
      transports.delete(sessionId);
    };

    await mcpServer.connect(sseTransport);
    return;
  }

  // POST /message endpoint for MCP JSON-RPC
  if (url.pathname === '/message' && req.method === 'POST') {
    const sessionId = url.searchParams.get('sessionId');
    const sseTransport = sessionId ? transports.get(sessionId) : (transports.values().next().value as SSEServerTransport | undefined);

    if (sseTransport) {
      await sseTransport.handlePostMessage(req, res);
    } else {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'No active SSE connection found for session' }));
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not Found' }));
});

httpServer.listen(PORT, HOST, () => {
  console.log(`[SeoulGatewayServer] Real MCP Gateway listening on http://${HOST}:${PORT}`);
  console.log(`[SeoulGatewayServer] Health check available at http://${HOST}:${PORT}/health`);
  console.log(`[SeoulGatewayServer] MCP SSE endpoint available at http://${HOST}:${PORT}/sse`);
});

// Graceful shutdown
const shutdown = () => {
  console.log('[SeoulGatewayServer] Shutting down gracefully...');
  httpServer.close(() => {
    console.log('[SeoulGatewayServer] HTTP server closed.');
    process.exit(0);
  });
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
