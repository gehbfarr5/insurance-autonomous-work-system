/**
 * service.ts
 * ReminderService implementation routing read requests to MacServer EventKit Transport.
 * 
 * Invariants:
 * 1. Interface conformance: Implements exact ReminderService required by registerReminderTools.
 * 2. Source and Identity binding: Only iCloud / calDAV lists and items are vended.
 * 3. Write prevention: create, update, remove MUST fail with PERMISSION_DENIED.
 *    ZERO fallback to legacy VTODO.
 * 4. Error honesty: Missing lists throw NOT_FOUND; backend errors throw upstream AppError;
 *    never masquerades failures as empty list [].
 */

import {
  AppError,
  type ListRemindersParams,
  type ListRemindersResult,
  type MacServerGatewayConfig,
  type PartialFailure,
  type Reminder,
  type ReminderInput,
  type ReminderItem,
  type ReminderListSummary,
  type ReminderService,
  type RemindersList,
  type UpdateOptions,
} from './types.ts';
import { EventKitReadonlyTransport } from './transport.ts';

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 1000;

function parseLimit(limit?: number): number {
  const value = limit ?? DEFAULT_LIMIT;
  if (!Number.isInteger(value) || value < 1 || value > MAX_LIMIT) {
    throw new AppError('INVALID_INPUT', `limit 必须在 1 到 ${MAX_LIMIT} 之间`);
  }
  return value;
}

function parseDueBound(label: string, value?: string): Date | undefined {
  if (value === undefined) return undefined;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new AppError('INVALID_INPUT', `${label} 必须是 ISO 8601 时间`, {
      hint: '例如 2026-09-01T00:00:00Z',
    });
  }
  return date;
}

export interface MacServerReminderServiceDeps {
  transport: EventKitReadonlyTransport;
  config: MacServerGatewayConfig;
}

export function createMacServerReminderService(deps: MacServerReminderServiceDeps): ReminderService {
  const { transport, config } = deps;
  const expectedSourceType = config.expectedSourceType || 'calDAV';
  const expectedSourceName = config.expectedSourceName || 'iCloud';

  /**
   * Internal helper to fetch and filter lists conforming to iCloud source and allowlist.
   */
  async function fetchAllowedICloudLists(): Promise<RemindersList[]> {
    const rawLists = await transport.fetchListsMetadata();

    // Verify source identity (FIX-R4A-02)
    const iCloudLists = rawLists.filter((list) => {
      const typeMatches = !expectedSourceType || list.sourceType.toLowerCase() === expectedSourceType.toLowerCase();
      const nameMatches = !expectedSourceName || list.sourceName.toLowerCase() === expectedSourceName.toLowerCase();
      return typeMatches && nameMatches;
    });

    // Apply allowed list IDs filter if configured
    if (config.allowedListIds && config.allowedListIds.length > 0) {
      const allowedSet = new Set(config.allowedListIds);
      return iCloudLists.filter((list) => allowedSet.has(list.listID));
    }

    return iCloudLists;
  }

  return {
    /**
     * Lists reminder lists metadata.
     * Maps to standard ReminderListSummary with writable: false.
     */
    async listLists(): Promise<ReminderListSummary[]> {
      const lists = await fetchAllowedICloudLists();
      return lists.map((list) => {
        const summary: ReminderListSummary = {
          list_id: list.listID,
          name: list.title,
          writable: false, // Strictly false in readonly gateway mode
        };
        if (list.color && list.color.trim()) {
          summary.color = list.color.trim();
        }
        return summary;
      });
    },

    /**
     * Queries reminders across specified or all allowed lists.
     * Strictly fails on errors, never masquerading as empty list.
     */
    async list(params: ListRemindersParams): Promise<ListRemindersResult> {
      const limit = parseLimit(params.limit);
      const dueAfter = parseDueBound('due_after', params.due_after);
      const dueBefore = parseDueBound('due_before', params.due_before);

      const availableLists = await fetchAllowedICloudLists();

      // Check requested list_ids
      let targetLists = availableLists;
      if (params.list_ids && params.list_ids.length > 0) {
        const missing = params.list_ids.filter(
          (reqId) => !availableLists.some((avail) => avail.listID === reqId)
        );
        if (missing.length > 0) {
          throw new AppError(
            'NOT_FOUND',
            `以下 list_id 不对应任何可用 iCloud 提醒列表：${missing.join('、')}`,
            { hint: '重新调用 reminders_lists 获取当前有效的 list_id' }
          );
        }
        targetLists = availableLists.filter((avail) => params.list_ids!.includes(avail.listID));
      }

      if (targetLists.length === 0) {
        return { reminders: [] };
      }

      // Query items for each target list with per-list isolation
      const settled = await Promise.allSettled(
        targetLists.map(async (list) => {
          const items = await transport.fetchReminders(list.listID);
          return { list, items };
        })
      );

      const allReminders: Reminder[] = [];
      const partialFailures: PartialFailure[] = [];
      let totalFailedLists = 0;
      let firstFailureError: unknown = null;

      settled.forEach((outcome, index) => {
        const list = targetLists[index]!;
        if (outcome.status === 'fulfilled') {
          const { items } = outcome.value;
          for (const item of items) {
            const reminder: Reminder = {
              reminder_id: item.itemID,
              list_id: item.listID,
              title: item.title,
              completed: item.isCompleted,
            };
            if (item.notes && item.notes.trim()) {
              reminder.notes = item.notes;
            }
            if (item.dueDate) {
              const d = new Date(item.dueDate);
              if (!Number.isNaN(d.getTime())) {
                reminder.due = d.toISOString();
              }
            }
            if (item.priority !== undefined && item.priority !== null) {
              reminder.priority = item.priority;
            }
            allReminders.push(reminder);
          }
        } else {
          totalFailedLists += 1;
          if (!firstFailureError) firstFailureError = outcome.reason;
          const reason =
            outcome.reason instanceof AppError
              ? outcome.reason.message
              : outcome.reason instanceof Error
              ? outcome.reason.message
              : '未知错误';
          partialFailures.push({
            list_id: list.listID,
            name: list.title,
            reason,
          });
        }
      });

      // Strict failure rule: If all requested lists failed, we MUST NOT report success with empty list!
      if (totalFailedLists === targetLists.length && targetLists.length > 0) {
        if (firstFailureError instanceof AppError) {
          throw firstFailureError;
        }
        throw new AppError(
          'UPSTREAM_ERROR',
          `所有目标提醒列表查询均失败: ${partialFailures.map((f) => `${f.name}(${f.reason})`).join('; ')}`
        );
      }

      // Filtering
      let filtered = allReminders;
      if (params.completed !== undefined) {
        filtered = filtered.filter((r) => r.completed === params.completed);
      }
      if (dueAfter || dueBefore) {
        filtered = filtered.filter((r) => {
          if (!r.due) return false;
          const due = new Date(r.due);
          if (dueAfter && due < dueAfter) return false;
          if (dueBefore && due > dueBefore) return false;
          return true;
        });
      }

      // Sorting: due asc (no due last), title tiebreaker
      const sorted = [...filtered].sort((a, b) => {
        if (a.due !== b.due) {
          if (!a.due) return 1;
          if (!b.due) return -1;
          return a.due < b.due ? -1 : 1;
        }
        return a.title.localeCompare(b.title);
      });

      const result: ListRemindersResult = {
        reminders: sorted.slice(0, limit),
      };
      if (sorted.length > limit) {
        result.truncated = true;
      }
      if (partialFailures.length > 0) {
        result.partial_failures = partialFailures;
      }

      return result;
    },

    /**
     * Write prevention: create is strictly rejected.
     */
    async create(_input: ReminderInput, _listId?: string): Promise<Reminder> {
      throw new AppError(
        'PERMISSION_DENIED',
        'MacServer EventKit Gateway 运行于严格只读模式，禁止写入并禁止回落旧 VTODO (create)'
      );
    },

    /**
     * Write prevention: update is strictly rejected.
     */
    async update(_reminderId: string, _patch: Partial<ReminderInput>, _options?: UpdateOptions): Promise<Reminder> {
      throw new AppError(
        'PERMISSION_DENIED',
        'MacServer EventKit Gateway 运行于严格只读模式，禁止写入并禁止回落旧 VTODO (update)'
      );
    },

    /**
     * Write prevention: remove is strictly rejected.
     */
    async remove(_reminderId: string, _options?: UpdateOptions): Promise<{ deleted: true }> {
      throw new AppError(
        'PERMISSION_DENIED',
        'MacServer EventKit Gateway 运行于严格只读模式，禁止写入并禁止回落旧 VTODO (remove)'
      );
    },
  };
}
