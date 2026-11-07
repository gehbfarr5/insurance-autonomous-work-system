/**
 * service.ts
 * Real Reminders Service Implementation for Seoul -> MacServer Reminders Readonly Gateway.
 * 
 * Adapts MacServer EventKit Bridge HTTP endpoints to standard ReminderService interface:
 * - listLists: maps to ReminderListSummary[] with writable: false
 * - list: maps to ListRemindersResult with Reminder[]
 * - create/update/remove: rejects client-side with PERMISSION_DENIED (zero write forwarding)
 * 
 * Invariants:
 * 1. Strictly READ-ONLY: Rejects write operations with 0 forwarding and 0 VTODO fallback.
 * 2. Strict Item Field Validation: itemID, listID, title, isCompleted are mandatory;
 *    missing, empty, or mismatched listID is immediately rejected with UPSTREAM_ERROR.
 * 3. Error objects are NEVER mapped into normal reminders.
 * 4. Bound list verification: Only allowed and bound lists are returned or queried.
 */

import {
  AppError,
  type AccountConfigLike,
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

function parseLimit(rawLimit?: number): number {
  if (rawLimit === undefined) return 500;
  if (!Number.isInteger(rawLimit) || rawLimit <= 0) {
    throw new AppError('INVALID_INPUT', `limit 必须为正整数: ${rawLimit}`);
  }
  return Math.min(rawLimit, 1000);
}

function parseDueBound(label: string, value?: string): Date | undefined {
  if (!value) return undefined;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) {
    throw new AppError('INVALID_INPUT', `${label} 格式无法解析为有效日期: ${value}`);
  }
  return d;
}

export interface MacServerReminderServiceDeps {
  transport: EventKitReadonlyTransport;
  config: MacServerGatewayConfig;
  account?: AccountConfigLike;
}

export function createMacServerReminderService(deps: MacServerReminderServiceDeps): ReminderService {
  const { transport, config, account } = deps;

  const requireRead = (): void => {
    if (account && account.capabilities && account.capabilities.remindersRead === false) {
      throw new AppError('PERMISSION_DENIED', '该账号的提醒事项读取权限未开启', {
        hint: 'ALLOW_REMINDERS_READ',
      });
    }
  };

  const bindingIndex = new Map<string, BoundListConfig>();
  for (const b of config.allowedLists) {
    bindingIndex.set(b.listId, b);
  }

  async function fetchAllowedICloudLists(): Promise<RemindersList[]> {
    const rawLists = await transport.fetchListsMetadata();

    const verifiedLists: RemindersList[] = [];
    for (const list of rawLists) {
      if (!list || typeof list !== 'object' || Array.isArray(list)) {
        throw new AppError('UPSTREAM_ERROR', 'Bridge 返回的列表元数据不是有效对象');
      }
      if (typeof list.listID !== 'string' || !list.listID.trim()) {
        throw new AppError('UPSTREAM_ERROR', 'Bridge 列表元数据缺失或包含非法的 listID');
      }
      if (typeof list.title !== 'string') {
        throw new AppError('UPSTREAM_ERROR', 'Bridge 列表元数据缺失或包含非法的 title');
      }
      if (typeof list.sourceID !== 'string' || !list.sourceID.trim()) {
        throw new AppError('UPSTREAM_ERROR', 'Bridge 列表元数据缺失或包含非法的 sourceID');
      }
      if (typeof list.sourceType !== 'string' || typeof list.sourceName !== 'string') {
        throw new AppError('UPSTREAM_ERROR', 'Bridge 列表元数据缺失有效的 source 字段');
      }

      const binding = bindingIndex.get(list.listID);
      if (!binding) continue;

      if (list.sourceID !== binding.expectedSourceId) {
        continue;
      }

      const expType = binding.expectedSourceType || config.expectedSourceType || 'calDAV';
      const expName = binding.expectedSourceName || config.expectedSourceName || 'iCloud';

      if (list.sourceType.toLowerCase() !== expType.toLowerCase()) {
        continue;
      }
      if (list.sourceName.toLowerCase() !== expName.toLowerCase()) {
        continue;
      }

      verifiedLists.push(list);
    }

    return verifiedLists;
  }

  function rejectWriteOp(op: string): never {
    throw new AppError(
      'PERMISSION_DENIED',
      `[WriteRejected] MacServer EventKit 网关运行于严格只读模式: 提醒事项 ${op} 写操作已在客户端拦截 (零转发/零VTODO回落/禁止写入并禁止回落旧 VTODO)`
    );
  }

  return {
    async listLists(): Promise<ReminderListSummary[]> {
      requireRead();
      const lists = await fetchAllowedICloudLists();
      return lists.map((list) => ({
        list_id: list.listID,
        name: list.title,
        color: list.color,
        writable: false,
      }));
    },

    async list(params: ListRemindersParams): Promise<ListRemindersResult> {
      requireRead();
      const limit = parseLimit(params.limit);
      const dueAfter = parseDueBound('due_after', params.due_after);
      const dueBefore = parseDueBound('due_before', params.due_before);

      const availableLists = await fetchAllowedICloudLists();

      let targetLists = availableLists;
      if (params.list_ids && params.list_ids.length > 0) {
        const missing = params.list_ids.filter(
          (reqId) => !availableLists.some((avail) => avail.listID === reqId)
        );
        if (missing.length > 0) {
          throw new AppError(
            'NOT_FOUND',
            `指定的提醒列表不存在或不对应任何已显式绑定的 iCloud 提醒列表: ${missing.join(', ')}`,
            { hint: '调用 reminders_lists 查询当前可用的提醒列表' }
          );
        }
        targetLists = availableLists.filter((avail) => params.list_ids!.includes(avail.listID));
      }

      const allReminders: Reminder[] = [];
      const partialFailures: PartialFailure[] = [];

      for (const targetList of targetLists) {
        let items: ReminderItem[];
        try {
          items = await transport.fetchReminders(targetList.listID);
        } catch (err: any) {
          if (targetLists.length === 1) {
            throw err;
          }
          partialFailures.push({
            list_id: targetList.listID,
            name: targetList.title,
            reason: err instanceof AppError ? err.message : String(err),
          });
          continue;
        }

        if (!Array.isArray(items)) {
          throw new AppError('UPSTREAM_ERROR', 'Bridge 返回的提醒条目不是 JSON 数组');
        }

        for (const rawItem of items) {
          if (!rawItem || typeof rawItem !== 'object' || Array.isArray(rawItem)) {
            throw new AppError('UPSTREAM_ERROR', 'Bridge 返回条目数据结构非法: 期望为 Object');
          }

          const item = rawItem as unknown as Record<string, unknown>;

          if ('error' in item || 'errorMessage' in item) {
            throw new AppError('UPSTREAM_ERROR', `Bridge 返回错误对象响应而非正常条目: ${JSON.stringify(item)}`);
          }

          if (typeof item.itemID !== 'string' || !item.itemID.trim()) {
            throw new AppError('UPSTREAM_ERROR', `Bridge 返回条目缺失必需的 itemID 字段: ${JSON.stringify(item)}`);
          }

          if (typeof item.listID !== 'string' || !item.listID.trim()) {
            throw new AppError('UPSTREAM_ERROR', `Bridge 返回条目缺失必需的 listID 字段: itemID=${item.itemID}`);
          }

          if (item.listID.trim() !== targetList.listID) {
            throw new AppError(
              'UPSTREAM_ERROR',
              `Bridge 返回条目归属列表 (${item.listID}) 与请求的目标列表 (${targetList.listID}) 不匹配/不一致`
            );
          }

          if (typeof item.title !== 'string') {
            throw new AppError('UPSTREAM_ERROR', `Bridge 返回条目缺失必需的 title 字段: itemID=${item.itemID}`);
          }

          if (typeof item.isCompleted !== 'boolean') {
            throw new AppError('UPSTREAM_ERROR', `Bridge 返回条目缺失必需的 isCompleted 布尔字段: itemID=${item.itemID}`);
          }

          if (params.completed !== undefined && item.isCompleted !== params.completed) {
            continue;
          }

          const dueIso = parseBridgeDate(item.dueDate);
          let dueDateObj: Date | undefined;
          if (dueIso) {
            dueDateObj = new Date(dueIso);
          }

          if (dueAfter !== undefined) {
            if (!dueDateObj || dueDateObj.getTime() < dueAfter.getTime()) {
              continue;
            }
          }
          if (dueBefore !== undefined) {
            if (!dueDateObj || dueDateObj.getTime() > dueBefore.getTime()) {
              continue;
            }
          }

          const reminderObj: Reminder = {
            id: String(item.itemID),
            reminder_id: String(item.itemID),
            list_id: targetList.listID,
            title: String(item.title),
            completed: Boolean(item.isCompleted),
            priority: typeof item.priority === 'number' ? item.priority : 0,
          };

          if (typeof item.notes === 'string') {
            reminderObj.notes = item.notes;
          }
          if (dueIso) {
            reminderObj.due = dueIso;
          }
          if (item.completionDate) {
            try {
              const compIso = parseBridgeDate(item.completionDate);
              if (compIso) reminderObj.completed_at = compIso;
            } catch {}
          }
          if (item.creationDate) {
            try {
              const crIso = parseBridgeDate(item.creationDate);
              if (crIso) reminderObj.created = crIso;
            } catch {}
          }

          allReminders.push(reminderObj);
        }
      }

      allReminders.sort((a, b) => {
        if (a.due && b.due) {
          return new Date(a.due).getTime() - new Date(b.due).getTime();
        }
        if (a.due && !b.due) return -1;
        if (!a.due && b.due) return 1;
        return a.title.localeCompare(b.title);
      });

      const truncated = allReminders.length > limit;
      const returnedReminders = truncated ? allReminders.slice(0, limit) : allReminders;

      const result: ListRemindersResult = {
        reminders: returnedReminders,
      };

      if (truncated) {
        result.truncated = true;
      }

      if (partialFailures.length > 0) {
        result.partial_failures = partialFailures;
      }

      return result;
    },

    async create(_input: ReminderInput, _listId?: string): Promise<Reminder> {
      rejectWriteOp('create');
    },

    async update(_reminderId: string, _patch: Partial<ReminderInput>, _options?: UpdateOptions): Promise<Reminder> {
      rejectWriteOp('update');
    },

    async remove(_reminderId: string, _options?: UpdateOptions): Promise<{ deleted: true }> {
      rejectWriteOp('remove');
    },
  };
}
