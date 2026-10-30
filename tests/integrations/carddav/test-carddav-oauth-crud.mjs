import crypto from 'node:crypto';
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const BASE_URL = process.env.MCP_SERVER_URL || 'https://insurance-carddav-mcp-pilot.onrender.com';
const MCP_ENDPOINT = `${BASE_URL}/mcp`;
const REDIRECT_URI = 'https://httpbin.org/get';

function sha256Base64Url(str) {
  return crypto.createHash('sha256').update(str).digest('base64url');
}

function maskEmail(email) {
  if (!email || typeof email !== 'string') return '[REDACTED]';
  const parts = email.split('@');
  if (parts.length !== 2) return '[REDACTED]';
  const name = parts[0];
  const domain = parts[1];
  const maskedName = name.length > 2 ? `${name[0]}***${name[name.length - 1]}` : `${name[0]}***`;
  return `${maskedName}@${domain}`;
}

function maskId(id) {
  if (!id || typeof id !== 'string') return '[REDACTED]';
  return id.length > 12 ? `${id.substring(0, 6)}...${id.substring(id.length - 4)}` : `${id.substring(0, 4)}...`;
}

/**
 * Loads the MCP Access Key securely in priority order:
 * 1. Environment variable MCP_ACCESS_KEY
 * 2. macOS Keychain service 'insurance-carddav-mcp' (account: 'mcp-agent')
 * 3. Local secure untracked file ~/.config/insurance-carddav-mcp/access_key
 */
function getSecureAccessKey() {
  if (process.env.MCP_ACCESS_KEY && process.env.MCP_ACCESS_KEY.trim()) {
    return { key: process.env.MCP_ACCESS_KEY.trim(), source: 'environment variable ($MCP_ACCESS_KEY)' };
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
        return { key: content, source: 'local file (~/.config/insurance-carddav-mcp/access_key)' };
      }
    } catch {}
  }

  return null;
}

/**
 * Unified tool call wrapper with strict assertion against isError and structured error payloads.
 */
async function callMcpTool(client, toolName, args) {
  const res = await client.callTool({ name: toolName, arguments: args });
  if (res.isError) {
    let errMsg = `Tool '${toolName}' returned isError: true`;
    if (res.content && res.content[0] && res.content[0].text) {
      try {
        const parsed = JSON.parse(res.content[0].text);
        errMsg += ` -> [${parsed.error?.code || 'ERROR'}] ${parsed.error?.message || res.content[0].text}`;
      } catch {
        errMsg += ` -> ${res.content[0].text}`;
      }
    }
    throw new Error(errMsg);
  }

  if (!res.content || !res.content[0] || res.content[0].type !== 'text') {
    throw new Error(`Tool '${toolName}' returned invalid MCP content response`);
  }

  try {
    return JSON.parse(res.content[0].text);
  } catch (err) {
    throw new Error(`Tool '${toolName}' text content is not valid JSON: ${err.message}`);
  }
}

async function run() {
  console.log('================================================================');
  console.log(' iCloud CardDAV MCP Cloud OAuth & CRUD Automated Acceptance Test');
  console.log('================================================================');
  console.log(`Target Server: ${BASE_URL}`);

  // 1. Health check
  console.log('\n[Stage 1/5] Checking Server Availability & Health...');
  const healthRes = await fetch(`${BASE_URL}/health`);
  if (!healthRes.ok) {
    throw new Error(`Health check failed with status: HTTP ${healthRes.status}`);
  }
  const healthData = await healthRes.json();
  if (healthData.status !== 'ok') {
    throw new Error(`Health check returned unexpected body: ${JSON.stringify(healthData)}`);
  }
  console.log(`✓ Server health confirmed: status='${healthData.status}'`);

  // 2. Dynamic Client Registration
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
    throw new Error(`Dynamic client registration failed with status: HTTP ${regRes.status}`);
  }
  const regData = await regRes.json();
  const clientId = regData.client_id;
  const clientSecret = regData.client_secret;
  if (!clientId) {
    throw new Error('Registration response missing client_id');
  }
  console.log(`✓ Dynamic client registered (client_id: ${maskId(clientId)})`);

  // 3. Initiate PKCE
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
    throw new Error('Failed to extract request_id from authorization page HTML');
  }
  const requestId = match[1];
  console.log(`✓ OAuth authorization request active (request_id: ${maskId(requestId)})`);

  let credential = getSecureAccessKey();
  if (!credential) {
    console.log('\n----------------------------------------------------------------');
    console.log(' [BLOCKED] No Access Key found in Keychain, Env, or Config File.');
    console.log(' Please configure your MCP Access Key using one of the safe methods:');
    console.log('   1. macOS Keychain (Silent Interactive Prompt):');
    console.log('      read -s -p "Enter MCP Access Key: " KEY && security add-generic-password -U -s "insurance-carddav-mcp" -a "mcp-agent" -w "$KEY" && unset KEY');
    console.log('   2. Temporary Session Environment:');
    console.log('      export MCP_ACCESS_KEY="<YOUR_KEY>"');
    console.log('   3. Local Secure File (0600):');
    console.log('      mkdir -p ~/.config/insurance-carddav-mcp && echo "<YOUR_KEY>" > ~/.config/insurance-carddav-mcp/access_key && chmod 600 ~/.config/insurance-carddav-mcp/access_key');
    console.log('----------------------------------------------------------------');
    return {
      status: 'AWAITING_ACCESS_KEY',
      stage: 'OAUTH_AUTHORIZE',
      authUrl: authUrl.toString(),
      requestId,
    };
  }

  console.log(`✓ Access Key acquired via: ${credential.source}`);
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
    throw new Error(`Access key rejected: ${errorMsg}`);
  }

  const redirectUrl = new URL(location);
  const code = redirectUrl.searchParams.get('code');
  if (!code) {
    throw new Error(`Redirect URL missing authorization code: ${location}`);
  }
  console.log('✓ OAuth authorization code exchanged successfully.');

  console.log('Exchanging authorization code for Bearer Access Token...');
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
    throw new Error(`Token exchange failed: HTTP ${tokenRes.status} -> ${await tokenRes.text()}`);
  }
  const tokenData = await tokenRes.json();
  const accessToken = tokenData.access_token;
  if (!accessToken) {
    throw new Error('Token endpoint response missing access_token');
  }
  console.log(`✓ Bearer Token obtained (TTL: ${tokenData.expires_in}s, Type: ${tokenData.token_type})`);

  // 4. Establish MCP session
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
  console.log(`✓ MCP session established (Transport Session ID: ${maskId(transport.sessionId)})`);

  console.log('Querying available tools on MCP server...');
  const toolsResult = await client.listTools();
  console.log(`✓ Registered tools count: ${toolsResult.tools.length}`);
  const toolNames = new Set(toolsResult.tools.map((t) => t.name));
  console.log(`  Tools: ${Array.from(toolNames).join(', ')}`);

  ['apple_accounts', 'apple_login', 'contacts_search', 'contacts_create', 'contacts_read', 'contacts_update', 'contacts_delete'].forEach((name) => {
    if (!toolNames.has(name)) {
      throw new Error(`Expected essential tool '${name}' is missing from MCP tool registry`);
    }
  });

  console.log('\nInvoking apple_accounts...');
  const accountsData = await callMcpTool(client, 'apple_accounts', {});
  if (!Array.isArray(accountsData)) {
    throw new Error(`apple_accounts returned unexpected non-array shape: ${typeof accountsData}`);
  }
  if (accountsData.length === 0) {
    throw new Error('apple_accounts returned 0 accounts. (.env accounts switch is likely DISABLED in /admin)');
  }
  console.log(`✓ apple_accounts returned ${accountsData.length} enabled account(s):`);
  accountsData.forEach((acc, i) => {
    console.log(`  Account ${i + 1}: ${maskEmail(acc.email)} (Capabilities: contactsRead=${Boolean(acc.capabilities?.contactsRead)}, contactsWrite=${Boolean(acc.capabilities?.contactsWrite)})`);
    if (!acc.capabilities?.contactsRead || !acc.capabilities?.contactsWrite) {
      throw new Error(`Account ${maskEmail(acc.email)} lacks contactsRead or contactsWrite capability!`);
    }
  });

  console.log('\nInvoking apple_login (CardDAV Real Authentication)...');
  const loginData = await callMcpTool(client, 'apple_login', {});
  const sessionId = loginData.session_id;
  if (!sessionId || typeof sessionId !== 'string') {
    throw new Error(`apple_login succeeded but returned no valid session_id: ${JSON.stringify(loginData)}`);
  }
  console.log(`✓ Apple CardDAV authenticated successfully! (Session ID: ${maskId(sessionId)})`);

  // 5. Contact CRUD with rigorous assertions & compensation cleanup
  console.log('\n[Stage 5/5] Executing Fictitious Contact CRUD Workflow...');
  const testTag = `MCP-Test-${Date.now()}`;
  console.log(`Test Identifier: ${testTag}`);

  let createdContactId = null;

  try {
    // 5.1 Search before create
    console.log('\n1. contacts_search: verifying test tag does not exist...');
    const searchBefore = await callMcpTool(client, 'contacts_search', { session_id: sessionId, query: testTag });
    if (!searchBefore || !Array.isArray(searchBefore.contacts)) {
      throw new Error(`contacts_search returned malformed result: ${JSON.stringify(searchBefore)}`);
    }
    if (searchBefore.contacts.length > 0) {
      throw new Error(`Precondition violation: testTag '${testTag}' already exists with ${searchBefore.contacts.length} records!`);
    }
    console.log(`✓ Pre-check confirmed: 0 matches for tag '${testTag}'`);

    // 5.2 Create fictitious contact
    console.log('\n2. contacts_create: creating fictitious contact...');
    const createData = await callMcpTool(client, 'contacts_create', {
      session_id: sessionId,
      contact: {
        name: { full: 'MCP Integration Test', family: 'Test', given: 'Integration' },
        note: `Automated CardDAV CRUD validation tag:${testTag}`,
      },
    });

    if (createData && createData.contact_id) {
      createdContactId = createData.contact_id;
    } else {
      // Fallback search to locate contact_id
      const searchAfterCreate = await callMcpTool(client, 'contacts_search', { session_id: sessionId, query: testTag });
      const found = searchAfterCreate.contacts?.find((c) => c.note?.includes(testTag) || c.name?.full?.includes('MCP Integration Test'));
      if (found && found.contact_id) {
        createdContactId = found.contact_id;
      }
    }

    if (!createdContactId) {
      throw new Error(`contacts_create failed to return or locate contact_id for tag '${testTag}'!`);
    }
    console.log(`✓ Contact created successfully (ID: ${maskId(createdContactId)})`);

    // 5.3 Read contact
    console.log('\n3. contacts_read: validating created contact fields...');
    const readData = await callMcpTool(client, 'contacts_read', { session_id: sessionId, contact_id: createdContactId });
    if (readData.contact_id !== createdContactId) {
      throw new Error(`contacts_read contact_id mismatch: expected ${createdContactId}, got ${readData.contact_id}`);
    }
    if (readData.name?.full !== 'MCP Integration Test') {
      throw new Error(`contacts_read name mismatch: expected 'MCP Integration Test', got '${readData.name?.full}'`);
    }
    if (!readData.note || !readData.note.includes(testTag)) {
      throw new Error(`contacts_read note missing testTag '${testTag}': got '${readData.note}'`);
    }
    console.log(`✓ Field verification passed (Name: '${readData.name.full}', Note verified with tag)`);

    // 5.4 Update contact
    console.log('\n4. contacts_update: updating note with [UPDATED] marker...');
    const updatedNote = `Automated CardDAV CRUD validation [UPDATED] tag:${testTag}`;
    const updateData = await callMcpTool(client, 'contacts_update', {
      session_id: sessionId,
      contact_id: createdContactId,
      patch: { note: updatedNote },
    });
    console.log(`✓ contacts_update acknowledged by server`);

    // 5.5 Read updated contact
    console.log('\n5. contacts_read: verifying updated note field...');
    const readUpdated = await callMcpTool(client, 'contacts_read', { session_id: sessionId, contact_id: createdContactId });
    if (!readUpdated.note || !readUpdated.note.includes('[UPDATED]') || !readUpdated.note.includes(testTag)) {
      throw new Error(`Updated note assertion failed: expected '[UPDATED]' and '${testTag}', got '${readUpdated.note}'`);
    }
    console.log(`✓ Update verified: Note updated successfully with [UPDATED] marker`);

    // 5.6 Delete contact
    console.log('\n6. contacts_delete: deleting test contact...');
    const deleteData = await callMcpTool(client, 'contacts_delete', { session_id: sessionId, contact_id: createdContactId });
    console.log(`✓ contacts_delete acknowledged by server`);

    // 5.7 Search after delete to verify removal
    console.log('\n7. contacts_search: confirming contact is completely purged...');
    const searchAfterDelete = await callMcpTool(client, 'contacts_search', { session_id: sessionId, query: testTag });
    if (!searchAfterDelete || !Array.isArray(searchAfterDelete.contacts)) {
      throw new Error(`Post-deletion search returned malformed response: ${JSON.stringify(searchAfterDelete)}`);
    }
    if (searchAfterDelete.contacts.length !== 0) {
      throw new Error(`Post-deletion assertion failed: expected 0 contacts for '${testTag}', but found ${searchAfterDelete.contacts.length}!`);
    }
    console.log(`✓ Deletion confirmed: 0 contacts found for tag '${testTag}'`);
    createdContactId = null; // Successfully cleaned up
  } finally {
    // Compensation cleanup if contact was created but not deleted due to error
    if (createdContactId) {
      console.warn(`\n[CLEANUP] Exception occurred with active test contact ${maskId(createdContactId)}. Executing compensation deletion...`);
      try {
        await callMcpTool(client, 'contacts_delete', { session_id: sessionId, contact_id: createdContactId });
        console.log(`[CLEANUP] Compensation deletion succeeded for ${maskId(createdContactId)}`);
      } catch (cleanupErr) {
        console.error(`[CLEANUP ERROR] Failed to clean up contact ${maskId(createdContactId)}: ${cleanupErr.message}`);
      }
    }

    // Call work_done if available to gracefully close session
    if (toolNames.has('work_done') && sessionId) {
      console.log('\n[TEARDOWN] Invoking work_done to gracefully terminate CardDAV session...');
      try {
        await callMcpTool(client, 'work_done', { session_id: sessionId });
        console.log('✓ work_done executed: session destroyed cleanly.');
      } catch (teardownErr) {
        console.warn(`[TEARDOWN WARNING] work_done returned: ${teardownErr.message}`);
      }
    }
  }

  console.log('\n================================================================');
  console.log(' ALL CardDAV Acceptance Tests Passed with Complete Assertion.');
  console.log('================================================================');
  return { status: 'SUCCESS', testTag };
}

run().catch((err) => {
  console.error('\n[FATAL] Acceptance Test Failed:', err.message);
  process.exit(1);
});
