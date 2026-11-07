/**
 * types.ts
 * Type definitions for Seoul -> MacServer EventKit Readonly Gateway.
 * Integrated into apple-icloud-mcp under src/modules/reminders/gateway/.
 */

import type { AccountConfig } from '../../../core/config.js';
import type {
  ReminderListSummary,
  ListRemindersParams,
  ListRemindersResult,
  PartialFailure,
} from '../types.js';
import type { Reminder, ReminderInput } from '../../../parsers/ical.js';
import type { ReminderService, UpdateOptions } from '../service.js';

export type {
  ReminderListSummary,
  ListRemindersParams,
  ListRemindersResult,
  Reminder,
  ReminderInput,
  UpdateOptions,
  PartialFailure,
  AccountConfig,
  ReminderService,
};

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

// ==========================================
// MacServer EventKit Bridge Protocol Types
// (Sources/EventKitBridge/Protocol/*.swift)
// ==========================================

export interface SourceIdentity {
  sourceID: string;
  sourceType: string;
  sourceName?: string;
}

export interface RemindersList {
  listID: string;
  title: string;
  color?: string;
  isImmutable?: boolean;
  sourceID: string;
  sourceType: string;
  sourceName: string;
}

export interface ReminderItem {
  itemID: string;
  title: string;
  notes?: string;
  isCompleted: boolean;
  dueDate?: number | string | null;
  completionDate?: number | string | null;
  priority?: number;
  listID: string;
  creationDate?: number | string | null;
  lastModifiedDate?: number | string | null;
  url?: string | null;
}

// ==========================================
// Gateway Configuration Types
// ==========================================

export interface BoundListConfig {
  listId: string;
  expectedSourceId: string;
  expectedSourceName?: string; // defaults to "iCloud"
  expectedSourceType?: string; // defaults to "calDAV"
}

export interface MacServerGatewayConfig {
  macserverEndpoint: string;
  authToken: string;
  timeoutMs: number;
  maxResponseSizeBytes: number;
  allowedLists: BoundListConfig[];
  expectedSourceType?: string;
  expectedSourceName?: string;
}
