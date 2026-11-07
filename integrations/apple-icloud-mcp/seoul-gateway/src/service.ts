/**
 * service.ts
 * ReminderService implementation routing read requests to MacServer EventKit Transport.
 * 
 * Invariants & Strict Protections:
 * 1. Explicit List-to-Source ID Binding: Every list vended must have an explicit binding in
 *    config.allowedLists. Lists without explicit source ID binding are rejected immediately.
 * 2. Target list ownership: Every returned reminder item MUST belong to the requested listID.
 *    Any cross-list item mismatch causes explicit failure.
 * 3. Swift Date handling: Supports Cocoa reference date numbers and ISO 8601 strings via parseBridgeDate.
 * 4. Write prevention: create, update, remove MUST fail with PERMISSION_DENIED.
 *    ZERO write forwarding to MacServer, ZERO fallback to legacy VTODO.
 * 5. Error honesty: Missing lists throw NOT_FOUND; backend errors throw upstream AppError;
 *    never masquerades failures as empty list [].
 */

import {
  AppError,
  type BoundListConfig,
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
import { EventKitReadonlyTransport, parseBridgeDate } from './transport.ts';

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

  // Build lookup index of explicit list-source bindings
  const bindingIndex = new Map<string, BoundListConfig>();
  for (const b of config.allowedLists) {
    bindingIndex.set(b.listId, b);
  }

  /**
   * Internal helper: fetches lists metadata and verifies explicit list-source ID bindings.
   * Requirement: 白名单与列表—来源 ID 绑定必须显式配置，缺失即拒绝。
   */
  async function fetchAllowedICloudLists(): Promise<RemindersList[]> {
    const rawLists = await transport.fetchListsMetadata();

    const verifiedLists: RemindersList[] = [];
    for (const list of rawLists) {
      const binding = bindingIndex.get(list.listID);
      // If list is not explicitly bound in config, it is rejected/omitted
      if (!binding) continue;

      // Verify sourceID matches explicit binding
      if (list.sourceID !== binding.expectedSourceId) {
        continue; // Source mismatch, reject
      }

      // Verify sourceType and sourceName
      const expType = binding.expectedSourceType || config.expectedSourceType || 'calDAV';
      const expName = binding.expectedSourceName || config.expectedSourceName || 'iCloud';

      if (list.sourceType.toLowerCase() !== expType.toLowerCase()) continue;
      if (list.sourceName.toLowerCase() !== expName.toLowerCase()) continue;

      verifiedLists.push(list);
    }

    return verifiedLists;
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
            `以下 list_id 不对应任何已显式绑定的 iCloud 提醒列表：${missing.join('、')}`,
            { hint: '重新调用 reminders_lists 获取当前有效且已绑定的 list_id' }
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

      for (let i = 0; i < settled.length; i++) {
        const outcome = settled[i]!;
        const list = targetLists[i]!;

        if (outcome.status === 'fulfilled') {
          const { items } = outcome.value;
          for (const item of items) {
            // Rule: 返回条目必须属于请求的列表
            if (item.listID !== list.listID) {
              throw new AppError(
                'UPSTREAM_ERROR',
                `安全校验失败：返回条目 ${item.itemID} 所属列表 (${item.listID}) 与请求的目标列表 (${list.listID}) 不匹配`
              );
            }

            const reminder: Reminder = {
              reminder_id: item.itemID,
              list_id: item.listID,
              title: item.title,
              completed: item.isCompleted,
            };

            if (item.notes && item.notes.trim()) {
              reminder.notes = item.notes;
            }

            // Swift Date parsing (Cocoa seconds or ISO string)
            const parsedDue = parseBridgeDate(item.dueDate);
            if (parsedDue) {
              reminder.due = parsedDue;
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
      }

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
