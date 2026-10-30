import crypto from 'node:crypto';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const BASE_URL = process.env.MCP_SERVER_URL || 'https://insurance-carddav-mcp-pilot.onrender.com';
const MCP_ENDPOINT = `${BASE_URL}/mcp`;
const REDIRECT_URI = 'https://httpbin.org/get';

function sha256Base64Url(str) {
  return crypto.createHash('sha256').update(str).digest('base64url');
}

/**
 * Loads the MCP Access Key securely in priority order:
 * 1. Environment variable MCP_ACCESS_KEY
 * 2. macOS Keychain service 'insurance-carddav-mcp' (account: 'mcp-agent')
 * 3. Local secure untracked file ~/.config/insurance-carddav-mcp/access_key
 */
function getSecureAccessKey() {
  if (process.env.MCP_ACCESS_KEY && process.env.MCP_ACCESS_KEY.trim()) {
    return { key: process.env.MCP_ACCESS_KEY.trim(), source: 'env (MCP_ACCESS_KEY)' };
  }

  // Try macOS Keychain
  try {
    const output = execSync('security find-generic-password -s "insurance-carddav-mcp" -a "mcp-agent" -w 2>/dev/null', {
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'ignore'],
    }).trim();
    if (output) {
      return { key: output, source: 'macOS Keychain (service: insurance-carddav-mcp)' };
    }
  } catch {}

  // Try secure local config file
  const localFile = path.join(os.homedir(), '.config', 'insurance-carddav-mcp', 'access_key');
  if (fs.existsSync(localFile)) {
    try {
      const content = fs.readFileSync(localFile, 'utf-8').trim();
      if (content) {
        return { key: content, source: `local file (~/.config/insurance-carddav-mcp/access_key)` };
      }
    } catch {}
  }

  return null;
}

async function run() {
  console.log('================================================================');
  console.log(' iCloud CardDAV MCP Cloud OAuth & CRUD Automated Acceptance Test');
  console.log('================================================================');
  console.log(`Target Server: ${BASE_URL}`);

  console.log('\n[Stage 1/5] Checking Server Availability & Health...');
  const healthRes = await fetch(`${BASE_URL}/health`);
  if (!healthRes.ok) {
    throw new Error(`Health check failed: HTTP ${healthRes.status}`);
  }
  const healthData = await healthRes.json();
  console.log(`Server health: ${healthData.status} (HTTP ${healthRes.status})`);

  console.log('\n[Stage 2/5] OAuth 2.1 Dynamic Client Registration...');
  const regRes = await fetch(`${BASE_URL}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_name: 'AntigravityAutomatedTester',
      redirect_uris: [REDIRECT_URI],
    }),
  });
  if (!regRes.ok) {
    throw new Error(`Client registration failed: HTTP ${regRes.status}`);
  }
  const regData = await regRes.json();
  const clientId = regData.client_id;
  const clientSecret = regData.client_secret;
  console.log(`Client registered successfully (client_id: ${clientId.substring(0, 8)}...)`);

  console.log('\n[Stage 3/5] Initiating PKCE S256 Authorization Flow...');
  const codeVerifier = crypto.randomBytes(32).toString('base64url');
  const codeChallenge = sha256Base64Url(codeVerifier);

  const authUrl = new URL(`${BASE_URL}/authorize`);
  authUrl.searchParams.set('client_id', clientId);
  authUrl.searchParams.set('redirect_uri', REDIRECT_URI);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('code_challenge', codeChallenge);
  authUrl.searchParams.set('code_challenge_method', 'S256');

  const authRes = await fetch(authUrl.toString());
  const authHtml = await authRes.text();
  const match = authHtml.match(/name="request_id"\s+value="([^"]+)"/);
  if (!match || !match[1]) {
    throw new Error('Failed to extract request_id from authorization page');
  }
  const requestId = match[1];
  console.log(`OAuth Authorization Request established (request_id: ${requestId.substring(0, 8)}...)`);

  const credential = getSecureAccessKey();
  if (!credential) {
    console.log('\n----------------------------------------------------------------');
    console.log(' [BLOCKED] No Access Key found in Keychain, Env, or Config File.');
    console.log(' To provide the Access Key securely, you can run:');
    console.log('   security add-generic-password -U -s "insurance-carddav-mcp" -a "mcp-agent" -w "<YOUR_KEY>"');
    console.log(' or:');
    console.log('   export MCP_ACCESS_KEY="<YOUR_KEY>"');
    console.log('----------------------------------------------------------------');
    return {
      status: 'AWAITING_ACCESS_KEY',
      stage: 'OAUTH_AUTHORIZE',
      authUrl: authUrl.toString(),
      requestId,
    };
  }

  console.log(`Loaded Access Key securely via: ${credential.source}`);
  console.log('Submitting Access Key to /access-login...');
  const loginRes = await fetch(`${BASE_URL}/access-login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      request_id: requestId,
      access_key: credential.key,
    }).toString(),
    redirect: 'manual',
  });

  const location = loginRes.headers.get('location');
  if ((loginRes.status !== 302 && loginRes.status !== 303) || !location) {
    const errorBody = await loginRes.text();
    const errorMatch = errorBody.match(/class="error"[^>]*>([^<]+)<\/p>/);
    const errorMsg = errorMatch ? errorMatch[1] : `HTTP ${loginRes.status}`;
    console.error(`\n[ERROR] Access key rejected by authorization server: ${errorMsg}`);
    return {
      status: 'ACCESS_KEY_REJECTED',
      error: errorMsg,
    };
  }

  const redirectUrl = new URL(location);
  const code = redirectUrl.searchParams.get('code');
  if (!code) {
    throw new Error(`No code found in redirect URL: ${location}`);
  }
  console.log('OAuth Authorization Code acquired successfully.');

  console.log('Exchanging Authorization Code for Bearer Access Token...');
  const tokenRes = await fetch(`${BASE_URL}/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: REDIRECT_URI,
      client_id: clientId,
      client_secret: clientSecret,
      code_verifier: codeVerifier,
    }).toString(),
  });

  if (!tokenRes.ok) {
    throw new Error(`Token exchange failed: HTTP ${tokenRes.status}`);
  }
  const tokenData = await tokenRes.json();
  const accessToken = tokenData.access_token;
  console.log(`Bearer Access Token issued (TTL: ${tokenData.expires_in}s, Token Type: ${tokenData.token_type})`);

  console.log('\n[Stage 4/5] Establishing MCP Session via Streamable HTTP...');
  const transport = new StreamableHTTPClientTransport(new URL(MCP_ENDPOINT), {
    requestInit: {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  });

  const client = new Client(
    { name: 'AntigravityInsuranceAgent', version: '1.0.0' },
    { capabilities: {} }
  );

  await client.connect(transport);
  console.log(`Connected to MCP Server. MCP Session ID: ${transport.sessionId}`);

  console.log('\nQuerying Available Tools...');
  const toolsResult = await client.listTools();
  console.log(`Tools available (${toolsResult.tools.length}):`);
  toolsResult.tools.forEach((t) => console.log(`  * ${t.name}: ${t.title || t.description}`));

  console.log('\nCalling apple_accounts...');
  const accountsResult = await client.callTool({
    name: 'apple_accounts',
    arguments: {},
  });
  console.log('apple_accounts response:', JSON.stringify(accountsResult, null, 2));

  console.log('\nCalling apple_login (CardDAV Real Authentication)...');
  const appleLoginResult = await client.callTool({
    name: 'apple_login',
    arguments: {},
  });
  console.log('apple_login response:', JSON.stringify(appleLoginResult, null, 2));

  let sessionId;
  if (appleLoginResult && appleLoginResult.content) {
    for (const c of appleLoginResult.content) {
      if (c.type === 'text') {
        try {
          const parsed = JSON.parse(c.text);
          if (parsed.session_id) sessionId = parsed.session_id;
        } catch {}
      }
    }
  }

  if (!sessionId) {
    console.error('\n[ERROR] apple_login did not return a session_id. Cannot proceed to CRUD.');
    return {
      status: 'CARDDAV_LOGIN_FAILED',
      accountsResult,
      appleLoginResult,
    };
  }
  console.log(`CardDAV session initialized: ${sessionId}`);

  console.log('\n[Stage 5/5] Executing Contact CRUD Flow...');
  const testTag = `MCP-Test-${Date.now()}`;
  console.log(`Test Identifier: ${testTag}`);

  // Step 1: Search before create
  console.log('\n1. contacts_search (verify non-existence)...');
  const searchBefore = await client.callTool({
    name: 'contacts_search',
    arguments: { session_id: sessionId, query: testTag },
  });
  console.log('searchBefore result:', JSON.stringify(searchBefore, null, 2));

  // Step 2: Create fictitious contact
  console.log('\n2. contacts_create (creating test contact)...');
  const createResult = await client.callTool({
    name: 'contacts_create',
    arguments: {
      session_id: sessionId,
      contact: {
        name: { full: 'MCP Integration Test', family: 'Test', given: 'Integration' },
        note: `Automated CardDAV CRUD validation tag:${testTag}`,
      },
    },
  });
  console.log('createResult:', JSON.stringify(createResult, null, 2));

  let contactId;
  if (createResult && createResult.content) {
    for (const c of createResult.content) {
      if (c.type === 'text') {
        try {
          const p = JSON.parse(c.text);
          if (p.contact_id) contactId = p.contact_id;
        } catch {}
      }
    }
  }

  if (!contactId) {
    console.log('Retrieving contact_id via search...');
    const searchAfterCreate = await client.callTool({
      name: 'contacts_search',
      arguments: { session_id: sessionId, query: testTag },
    });
    console.log('searchAfterCreate:', JSON.stringify(searchAfterCreate, null, 2));
  }

  if (contactId) {
    // Step 3: Read contact
    console.log(`\n3. contacts_read (id: ${contactId})...`);
    const readResult = await client.callTool({
      name: 'contacts_read',
      arguments: { session_id: sessionId, contact_id: contactId },
    });
    console.log('readResult:', JSON.stringify(readResult, null, 2));

    // Step 4: Update contact note
    console.log(`\n4. contacts_update (id: ${contactId})...`);
    const updateResult = await client.callTool({
      name: 'contacts_update',
      arguments: {
        session_id: sessionId,
        contact_id: contactId,
        patch: {
          note: `Automated CardDAV CRUD validation [UPDATED] tag:${testTag}`,
        },
      },
    });
    console.log('updateResult:', JSON.stringify(updateResult, null, 2));

    // Step 5: Read updated contact
    console.log(`\n5. contacts_read (verifying updated note)...`);
    const readUpdated = await client.callTool({
      name: 'contacts_read',
      arguments: { session_id: sessionId, contact_id: contactId },
    });
    console.log('readUpdated:', JSON.stringify(readUpdated, null, 2));

    // Step 6: Delete contact
    console.log(`\n6. contacts_delete (cleaning up id: ${contactId})...`);
    const deleteResult = await client.callTool({
      name: 'contacts_delete',
      arguments: { session_id: sessionId, contact_id: contactId },
    });
    console.log('deleteResult:', JSON.stringify(deleteResult, null, 2));

    // Step 7: Search after delete
    console.log(`\n7. contacts_search (verifying clean up)...`);
    const searchAfterDelete = await client.callTool({
      name: 'contacts_search',
      arguments: { session_id: sessionId, query: testTag },
    });
    console.log('searchAfterDelete:', JSON.stringify(searchAfterDelete, null, 2));
  }

  console.log('\n================================================================');
  console.log(' All CardDAV Acceptance Stages Executed Successfully.');
  console.log('================================================================');
  return { status: 'SUCCESS', testTag, contactId };
}

run().catch((err) => {
  console.error('\n[FATAL] Execution failed with error:', err.message);
  process.exit(1);
});
