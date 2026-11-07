/**
 * index.ts
 * Entry point for MacServer EventKit Gateway module in apple-icloud-mcp.
 */

import { AppError } from '../../../core/errors.js';
import type { Session } from '../../../core/session.js';
import type { ReminderService, ListRemindersParams, ReminderInput, UpdateOptions } from './types.js';
import { createReminderService } from '../service.js';
import { loadGatewayConfigFromEnv } from './config.js';
import { EventKitReadonlyTransport } from './transport.js';
import { createMacServerReminderService } from './service.js';

export * from './types.js';
export * from './config.js';
export * from './transport.js';
export * from './service.js';

let sharedTransport: EventKitReadonlyTransport | undefined;
let sharedConfig: ReturnType<typeof loadGatewayConfigFromEnv> | undefined;

export function isMacServerGatewayConfigured(): boolean {
  return Boolean(
    process.env.MACSERVER_EVENTKIT_ENDPOINT ||
    process.env.EVENTKIT_GATEWAY_ENDPOINT ||
    process.env.EVENTKIT_BRIDGE_ENDPOINT
  );
}

/**
 * Service factory providing either the MacServer EventKit Gateway service (when configured)
 * or the default Apple CalDAV reminder service.
 * Enforces session account capability checks and read-only write protection.
 */
export function getGatewayReminderService(session: Session): ReminderService {
  if (!isMacServerGatewayConfigured()) {
    return createReminderService({ account: session.account, caldav: session.providers.caldav });
  }

  if (!sharedConfig) {
    sharedConfig = loadGatewayConfigFromEnv(process.env);
    sharedTransport = new EventKitReadonlyTransport(sharedConfig);
  }

  const baseGateway = createMacServerReminderService({
    transport: sharedTransport!,
    config: sharedConfig!,
    account: session.account,
  });

  return {
    async listLists() {
      if (!session.account.capabilities.remindersRead) {
        throw new AppError('PERMISSION_DENIED', '该账号的提醒事项读取权限未开启', {
          hint: 'ALLOW_REMINDERS_READ',
        });
      }
      return baseGateway.listLists();
    },
    async list(params: ListRemindersParams) {
      if (!session.account.capabilities.remindersRead) {
        throw new AppError('PERMISSION_DENIED', '该账号的提醒事项读取权限未开启', {
          hint: 'ALLOW_REMINDERS_READ',
        });
      }
      return baseGateway.list(params);
    },
    async create(input: ReminderInput, listId?: string) {
      return baseGateway.create(input, listId);
    },
    async update(reminderId: string, patch: Partial<ReminderInput>, options?: UpdateOptions) {
      return baseGateway.update(reminderId, patch, options);
    },
    async remove(reminderId: string, options?: UpdateOptions) {
      return baseGateway.remove(reminderId, options);
    },
  };
}
