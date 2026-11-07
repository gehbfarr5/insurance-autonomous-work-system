/**
 * fake-bridge.ts
 * In-memory Mock EventKit Bridge HTTP Server for unit and integration testing.
 * 
 * Faithful emulation of MacServer EventKit Bridge behavior:
 * - Bearer token validation (HTTP 401)
 * - Production authorized switch (HTTP 403 PERMISSION_DENIED)
 * - Allowlist validation (HTTP 403 LIST_NOT_ALLOWED)
 * - Non-GET method rejection (HTTP 405 WRITE_OPERATION_REJECTED)
 * - Metadata-only /reminders/lists (FIX-R4A-01)
 * - Content query with source verification /reminders/lists/:id/items (FIX-R4A-02)
 * - Fault injection: timeouts, 500 internal errors, malformed JSON, simulated 404.
 */

import http from 'node:http';
import type { ReminderItem, RemindersList } from './types.ts';

export interface RecordedRequest {
  method: string;
  url: string;
  headers: http.IncomingHttpHeaders;
  timestamp: number;
}

export interface FakeBridgeOptions {
  validToken?: string;
  productionAuthorized?: boolean;
  allowedListIds?: string[];
  mockLists?: RemindersList[];
  mockItems?: Record<string, ReminderItem[]>;
}

export class FakeEventKitBridge {
  private server: http.Server | null = null;
  private port: number = 0;

  public validToken: string;
  public productionAuthorized: boolean;
  public allowedListIds: Set<string>;
  public mockLists: RemindersList[];
  public mockItems: Map<string, ReminderItem[]>;

  // Fault injection controls
  public delayMs: number = 0;
  public simulateServerError: boolean = false;
  public simulateCorruptJson: boolean = false;
  public simulateListNotFound: boolean = false;

  public readonly requests: RecordedRequest[] = [];

  constructor(options: FakeBridgeOptions = {}) {
    this.validToken = options.validToken || 'test-valid-bridge-token-at-least-32chars!';
    this.productionAuthorized = options.productionAuthorized ?? true;
    this.allowedListIds = new Set(options.allowedListIds || []);
    this.mockLists = options.mockLists || [];
    this.mockItems = new Map();

    if (options.mockItems) {
      for (const [k, v] of Object.entries(options.mockItems)) {
        this.mockItems.set(k, v);
      }
    }
  }

  async start(): Promise<string> {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => this.handle(req, res));
      this.server.listen(0, '127.0.0.1', () => {
        const addr = this.server?.address();
        if (addr && typeof addr === 'object') {
          this.port = addr.port;
          resolve(`http://127.0.0.1:${this.port}`);
        } else {
          reject(new Error('Failed to obtain server address'));
        }
      });
    });
  }

  async stop(): Promise<void> {
    return new Promise((resolve) => {
      if (this.server) {
        this.server.close(() => {
          this.server = null;
          resolve();
        });
      } else {
        resolve();
      }
    });
  }

  get url(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    this.requests.push({
      method: req.method || '',
      url: req.url || '',
      headers: req.headers,
      timestamp: Date.now(),
    });

    if (this.delayMs > 0) {
      await new Promise((r) => setTimeout(r, this.delayMs));
    }

    const method = (req.method || '').toUpperCase();
    const parsedUrl = new URL(req.url || '/', `http://127.0.0.1:${this.port}`);
    const pathname = parsedUrl.pathname;

    // 1. Health check bypasses auth & productionAuthorized checks
    if (pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          status: 'ok',
          mode: 'readonly',
          store: 'fake',
          active_requests: 0,
          generation: 1,
          timestamp: new Date().toISOString(),
        })
      );
      return;
    }

    // 2. Reject non-GET methods with HTTP 405 (WRITE_OPERATION_REJECTED)
    if (method !== 'GET') {
      res.writeHead(405, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          success: 'false',
          error: 'Write operations are strictly rejected by readonly bridge',
          code: 'WRITE_OPERATION_REJECTED',
        })
      );
      return;
    }

    // 3. Bearer Token Auth Check
    const authHeader = req.headers.authorization;
    if (!authHeader || authHeader !== `Bearer ${this.validToken}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          success: 'false',
          error: 'Authentication failed. Invalid or missing token.',
          code: 'AUTHENTICATION_FAILED',
        })
      );
      return;
    }

    // 4. Production Authorized Gating Check
    if (!this.productionAuthorized) {
      res.writeHead(403, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          success: 'false',
          error: 'EventKit production bridge not authorized.',
          code: 'PERMISSION_DENIED',
        })
      );
      return;
    }

    // 5. Simulated Fault Injections
    if (this.simulateServerError) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          success: 'false',
          error: 'Simulated internal bridge server error',
          code: 'INTERNAL_ERROR',
        })
      );
      return;
    }

    if (this.simulateCorruptJson) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('CORRUPT_NOT_VALID_JSON{:::');
      return;
    }

    // 6. Route: GET /reminders/lists
    if (pathname === '/reminders/lists') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(this.mockLists));
      return;
    }

    // 7. Route: GET /reminders/lists/:id/items
    const itemsMatch = pathname.match(/^\/reminders\/lists\/([^/]+)\/items$/);
    if (itemsMatch) {
      const listID = decodeURIComponent(itemsMatch[1]!);

      if (this.simulateListNotFound) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            success: 'false',
            error: 'List not found',
            code: 'LIST_NOT_FOUND',
          })
        );
        return;
      }

      // Allowlist check if configured
      if (this.allowedListIds.size > 0 && !this.allowedListIds.has(listID)) {
        res.writeHead(403, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            success: 'false',
            error: `List not allowed: ${listID}`,
            code: 'LIST_NOT_ALLOWED',
          })
        );
        return;
      }

      const items = this.mockItems.get(listID) || [];
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(items));
      return;
    }

    // 8. 404 Not Found
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        success: 'false',
        error: 'Unknown route',
        code: 'INTERNAL_ERROR',
      })
    );
  }
}
