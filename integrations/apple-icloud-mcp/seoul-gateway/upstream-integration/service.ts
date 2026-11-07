/**
 * service.ts
 * ReminderService implementation routing read requests to MacServer EventKit Transport.
 */

import { AppError } from '../../../core/errors.js';
import type {
  ReminderService,
  ReminderListSummary,
  ListRemindersParams,
  ListRemindersResult,
  Reminder,
  ReminderInput,
  UpdateOptions,
  PartialFailure,
  AccountConfig,
} from './types.js';
import type {
  BoundListConfig,
  MacServerGatewayConfig,
  RemindersList,
  ReminderItem,
} from './types.js';
import { EventKitReadonlyTransport, parseBridgeDate } from './transport.js';

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
  account?: AccountConfig;
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
      if (!list || typeof list !== 'object') {
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

      if (list.sourceType.toLowerCase() !== expType.toLowerCase()) continue;
      if (list.sourceName.toLowerCase() !== expName.toLowerCase()) continue;

      verifiedLists.push(list);
    }

    return verifiedLists;
  }

  return {
    async listLists(): Promise<ReminderListSummary[]> {
      requireRead();
      const lists = await fetchAllowedICloudLists();
      return lists.map((list) => {
        const summary: ReminderListSummary = {
          list_id: list.listID,
          name: list.title,
          writable: false,
        };
        if (list.color && list.color.trim()) {
          summary.color = list.color.trim();
        }
        return summary;
      });
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
            `指定的提醒列表不存在或未在白名单中: ${missing.join(', ')}`,
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

        for (const item of items) {
          if (item.listID && item.listID !== targetList.listID) {
            throw new AppError(
              'UPSTREAM_ERROR',
              `Bridge 返回条目归属列表不一致: 期望 ${targetList.listID}, 收到 ${item.listID}`
            );
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
            reminder_id: item.itemID,
            list_id: targetList.listID,
            title: item.title,
            completed: item.isCompleted,
            priority: item.priority !== undefined ? item.priority : 0,
          };

          if (item.notes !== undefined && item.notes !== null) {
            reminderObj.notes = item.notes;
          }
          if (dueIso) {
            reminderObj.due = dueIso;
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
      return transport.rejectWrite('create');
    },

    async update(_reminderId: string, _patch: Partial<ReminderInput>, _options?: UpdateOptions): Promise<Reminder> {
      return transport.rejectWrite('update');
    },

    async remove(_reminderId: string, _options?: UpdateOptions): Promise<{ deleted: true }> {
      return transport.rejectWrite('delete');
    },
  };
}
