import { test, describe, before, after } from 'node:test';
import assert from 'node:assert';
import http from 'node:http';
import net from 'node:net';
import { FakeEventKitBridge } from '../src/fake-bridge.ts';
import { EventKitReadonlyTransport } from '../src/transport.ts';
import { createMacServerReminderService } from '../src/service.ts';
import { AppError, type MacServerGatewayConfig } from '../src/types.ts';

describe('Container -> Host Tunnel -> Fake Bridge Multi-Hop Integration', () => {
  const token = 'container-tunnel-auth-token-32chars!';
  let fakeBridge: FakeEventKitBridge;
  let bridgePort: number;

  // Mock SSH Tunnel forwarder (listening on 127.0.0.1:tunnelPort -> forwarding to 127.0.0.1:bridgePort)
  let sshTunnelServer: net.Server;
  let tunnelPort: number;

  // Mock Host Docker Gateway Relay (listening on 127.0.0.1:dockerGatewayPort -> forwarding to 127.0.0.1:tunnelPort)
  // Simulates container accessing host gateway (e.g. 172.19.0.1:18765)
  let dockerGatewayServer: net.Server;
  let dockerGatewayPort: number;

  let config: MacServerGatewayConfig;

  before(async () => {
    // 1. Start Fake Bridge (simulating MacServer loopback 127.0.0.1:18765)
    fakeBridge = new FakeEventKitBridge({
      validToken: token,
      productionAuthorized: true,
      allowedListIds: ['list-bound-01'],
      mockLists: [
        {
          listID: 'list-bound-01',
          title: '已绑定列表',
          sourceID: 'src-icloud-01',
          sourceType: 'calDAV',
          sourceName: 'iCloud',
          color: '#34C759',
          isImmutable: true,
        },
      ],
      mockItems: {
        'list-bound-01': [
          {
            itemID: 'item-01',
            title: '容器经宿主隧道读取成功',
            isCompleted: false,
            dueDate: 815961600,
            priority: 1,
            notes: '多跳链路完整打通',
            listID: 'list-bound-01',
          },
        ],
      },
    });

    const bridgeUrl = await fakeBridge.start();
    const bridgeAddr = new URL(bridgeUrl);
    bridgePort = Number(bridgeAddr.port);

    // 2. Start mock SSH Tunnel (Local Forwarding: 127.0.0.1:tunnelPort -> 127.0.0.1:bridgePort)
    await new Promise<void>((resolve) => {
      sshTunnelServer = net.createServer((clientSocket) => {
        const targetSocket = net.connect(bridgePort, '127.0.0.1', () => {
          clientSocket.pipe(targetSocket);
          targetSocket.pipe(clientSocket);
        });
        clientSocket.on('error', () => targetSocket.destroy());
        targetSocket.on('error', () => clientSocket.destroy());
      });
      sshTunnelServer.listen(0, '127.0.0.1', () => {
        const addr = sshTunnelServer.address() as net.AddressInfo;
        tunnelPort = addr.port;
        resolve();
      });
    });

    // 3. Start mock Docker Gateway Relay (127.0.0.1:dockerGatewayPort -> 127.0.0.1:tunnelPort)
    // Simulating container reaching host via 172.19.0.1:18765
    await new Promise<void>((resolve) => {
      dockerGatewayServer = net.createServer((containerSocket) => {
        const tunnelSocket = net.connect(tunnelPort, '127.0.0.1', () => {
          containerSocket.pipe(tunnelSocket);
          tunnelSocket.pipe(containerSocket);
        });
        containerSocket.on('error', () => tunnelSocket.destroy());
        tunnelSocket.on('error', () => containerSocket.destroy());
      });
      dockerGatewayServer.listen(0, '127.0.0.1', () => {
        const addr = dockerGatewayServer.address() as net.AddressInfo;
        dockerGatewayPort = addr.port;
        resolve();
      });
    });

    // Gateway config configured as if container connects to host gateway
    config = {
      macserverEndpoint: `http://127.0.0.1:${dockerGatewayPort}`,
      authToken: token,
      timeoutMs: 3000,
      maxResponseSizeBytes: 1048576,
      allowedLists: [
        {
          listId: 'list-bound-01',
          expectedSourceId: 'src-icloud-01',
          expectedSourceName: 'iCloud',
          expectedSourceType: 'calDAV',
        },
      ],
      expectedSourceType: 'calDAV',
      expectedSourceName: 'iCloud',
    };
  });

  after(async () => {
    await fakeBridge.stop();
    await new Promise<void>((resolve) => sshTunnelServer.close(() => resolve()));
    await new Promise<void>((resolve) => dockerGatewayServer.close(() => resolve()));
  });

  test('Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries lists', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({ transport, config });

    const lists = await service.listLists();
    assert.strictEqual(lists.length, 1);
    assert.strictEqual(lists[0]?.list_id, 'list-bound-01');
    assert.strictEqual(lists[0]?.name, '已绑定列表');
    assert.strictEqual(lists[0]?.writable, false);
  });

  test('Container -> Docker Gateway -> SSH Tunnel -> Fake Bridge successfully queries items', async () => {
    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({ transport, config });

    const res = await service.list({ list_ids: ['list-bound-01'] });
    assert.strictEqual(res.reminders.length, 1);
    assert.strictEqual(res.reminders[0]?.reminder_id, 'item-01');
    assert.strictEqual(res.reminders[0]?.title, '容器经宿主隧道读取成功');
    assert.strictEqual(res.reminders[0]?.notes, '多跳链路完整打通');
  });

  test('Loopback boundaries verified: servers listen on 127.0.0.1, not 0.0.0.0', () => {
    const sshAddr = sshTunnelServer.address() as net.AddressInfo;
    const gwAddr = dockerGatewayServer.address() as net.AddressInfo;

    assert.strictEqual(sshAddr.address, '127.0.0.1', 'SSH tunnel listens strictly on 127.0.0.1');
    assert.strictEqual(gwAddr.address, '127.0.0.1', 'Gateway relay listens strictly on 127.0.0.1');
  });

  test('Zero M5 Pro dependency: no M5 Pro IP or port exists in topology', () => {
    assert(!config.macserverEndpoint.includes('100.69.145.3'));
    assert(!config.macserverEndpoint.includes('18443'));
  });

  test('Error propagation across tunnel: Fake Bridge 403 propagates without being masked as empty array', async () => {
    fakeBridge.productionAuthorized = false;
    const transport = new EventKitReadonlyTransport(config);
    const service = createMacServerReminderService({ transport, config });

    try {
      await assert.rejects(
        async () => service.list({ list_ids: ['list-bound-01'] }),
        (err: unknown) => {
          assert(err instanceof AppError);
          assert.strictEqual(err.code, 'PERMISSION_DENIED');
          return true;
        }
      );
    } finally {
      fakeBridge.productionAuthorized = true;
    }
  });
});
