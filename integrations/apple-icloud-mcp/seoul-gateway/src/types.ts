/**
 * types.ts
 * Type definitions for Seoul -> MacServer EventKit Readonly Gateway.
 * 
 * Strict alignment with:
 * - Seoul MCP Reminders service contract (src/modules/reminders/types.ts & service.ts)
 * - MacServer EventKit Bridge Protocol (Sources/EventKitBridge/Protocol/*.swift)
 */

export type ErrorCode =
  | 'AUTH_FAILED'
  | 'PERMISSION_DENIED'
  | 'NOT_FOUND'
  | 'INVALID_INPUT'
  | 'SESSION_EXPIRED'
  | 'CONFLICT'
  | 'RATE_LIMITED'
  | 'UPSTREAM_ERROR'
  | 'INTERNAL';

export interface AppErrorOptions {
  hint?: string;
  retryable?: boolean;
  cause?: unknown;
}

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly hint?: string;
  readonly retryable: boolean;
  readonly cause?: unknown;

  constructor(code: ErrorCode, message: string, options: AppErrorOptions = {}) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.hint = options.hint;
    this.retryable = options.retryable ?? false;
    this.cause = options.cause;
  }
}

// ==========================================
// MacServer EventKit Bridge Protocol Types
// (Sources/EventKitBridge/Protocol/*.swift)
// ==========================================

export interface SourceIdentity {
  sourceID: string;
  sourceType: string; // e.g. "calDAV", "local", "exchange"
  sourceTitle: string; // e.g. "iCloud"
}

export interface RemindersList {
  listID: string;
  title: string;
  sourceID: string;
  sourceType: string; // e.g. "calDAV"
  sourceName: string; // e.g. "iCloud"
  color: string;
  isImmutable: boolean;
}

export interface ReminderItem {
  itemID: string;
  title: string;
  isCompleted: boolean;
  dueDate: string | null; // ISO 8601 string from Swift Date
  priority: number; // 0..9
  notes: string | null;
  listID: string;
}

export interface BridgeHealthResponse {
  status: string;
  mode: string;
  store: string;
  active_requests?: number;
  active_store_operations?: number;
  generation?: number;
  timestamp?: string;
}

// ==========================================
// Seoul MCP Reminders Types
// (src/modules/reminders/types.ts & service.ts)
// ==========================================

export interface ReminderListSummary {
  list_id: string;
  name: string;
  color?: string;
  writable: boolean; // Always false in readonly gateway mode
}

export interface PartialFailure {
  list_id: string;
  name: string;
  reason: string;
}

export interface ListRemindersParams {
  list_ids?: string[];
  completed?: boolean;
  due_before?: string;
  due_after?: string;
  limit?: number;
}

export interface Reminder {
  reminder_id: string;
  list_id: string;
  title: string;
  notes?: string;
  due?: string;
  completed: boolean;
  completed_at?: string;
  priority?: number;
  percent_complete?: number;
  created?: string;
}

export interface ListRemindersResult {
  reminders: Reminder[];
  truncated?: true;
  partial_failures?: PartialFailure[];
}

export interface ReminderInput {
  title: string;
  notes?: string;
  due?: string | null;
  all_day_due?: boolean;
  priority?: number;
  completed?: boolean;
}

export interface UpdateOptions {
  expected_etag?: string;
}

export interface ReminderService {
  listLists(): Promise<ReminderListSummary[]>;
  list(params: ListRemindersParams): Promise<ListRemindersResult>;
  create(input: ReminderInput, listId?: string): Promise<Reminder>;
  update(reminderId: string, patch: Partial<ReminderInput>, options?: UpdateOptions): Promise<Reminder>;
  remove(reminderId: string, options?: UpdateOptions): Promise<{ deleted: true }>;
}

// ==========================================
// Gateway Configuration Types
// ==========================================

export interface MacServerGatewayConfig {
  /**
   * HTTP endpoint of MacServer EventKit Bridge.
   * e.g. "http://127.0.0.1:18765" (via persistent tunnel)
   * or "http://100.100.172.91:18765" (Tailscale mesh candidate)
   */
  macserverEndpoint: string;

  /**
   * Restricted Bearer token generated for this bridge connection.
   */
  authToken: string;

  /**
   * Request timeout in milliseconds (default: 5000ms).
   */
  timeoutMs: number;

  /**
   * Optional allowlist of permitted list UUIDs.
   * If provided, queries targeting unallowed lists will be rejected.
   */
  allowedListIds?: string[];

  /**
   * Expected source validation (default: sourceType="calDAV", sourceName="iCloud").
   */
  expectedSourceType?: string;
  expectedSourceName?: string;
}
