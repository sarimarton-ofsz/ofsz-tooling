#!/usr/bin/env node
// pw-saml.mjs — Playwright-based SAML auth for AWS VPN
// Usage:
//   node pw-saml.mjs login  <saml-url> <state-file> [email] [password]
//       Visible-browser login + SAML capture. Credentials are pre-filled
//       when given; the user completes the 2FA prompt in the window.
//   node pw-saml.mjs saml   <saml-url> <state-file>   Headless SAML capture, outputs token

import { chromium } from 'playwright';

const cmd = process.argv[2];
const TIMEOUT = 120_000;

function setupSamlInterceptor(page) {
  let samlResponse = null;
  let resolve;
  const captured = new Promise(r => { resolve = r; });

  page.on('request', req => {
    if (req.url().includes('127.0.0.1:35001')) {
      const postData = req.postData();
      if (postData) {
        const match = postData.match(/SAMLResponse=([^&]+)/);
        if (match) {
          samlResponse = decodeURIComponent(match[1]);
          resolve();
        }
      }
    }
  });

  return {
    get response() { return samlResponse; },
    waitForCapture: (timeoutMs) => Promise.race([captured, new Promise(r => setTimeout(r, timeoutMs))]),
  };
}

async function extractSamlFromPage(page) {
  try {
    return await page.evaluate(() => {
      const input = document.querySelector('input[name="SAMLResponse"]');
      return input ? input.value : null;
    });
  } catch { return null; }
}

async function login(samlUrl, stateFile, email, password) {
  // Always headful: the tenant enforces 2FA, which a headless login can't
  // complete. Credentials (if given) are pre-filled so the user only has to
  // confirm the 2FA prompt. KMSI ("Stay signed in?") is auto-answered Yes —
  // that's what yields the persistent cookie for later headless captures.
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  await page.goto('https://login.microsoftonline.com');

  if (email) {
    try {
      await page.waitForSelector('input[type="email"]', { timeout: 15_000 });
      await page.fill('input[type="email"]', email);
      await page.click('input[type="submit"]');
    } catch { /* screen skipped (SSO / account picker) — user takes over */ }
  }
  if (password) {
    try {
      await page.waitForSelector('input[type="password"]:visible', { timeout: 15_000 });
      await page.fill('input[type="password"]', password);
      await page.click('input[type="submit"]');
    } catch { /* password screen skipped — user takes over */ }
  }

  // Wait out the 2FA dance in the visible window; auto-click KMSI Yes.
  // The KMSI screen is the only login screen with a #idBtn_Back ("No").
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    if (!page.url().includes('login.microsoftonline.com')) break;
    try {
      if (await page.$('#idBtn_Back')) {
        const yesBtn = await page.$('#idSIButton9');
        if (yesBtn) await yesBtn.click();
      }
    } catch { /* DOM churn mid-navigation — retry next tick */ }
    await page.waitForTimeout(1000);
  }
  await page.waitForTimeout(2000);

  await context.storageState({ path: stateFile });

  // Now capture SAML in the same browser session (no second Chromium launch).
  // Generous timeout: a Conditional Access policy may demand another
  // interaction here; resolves immediately once the POST is seen.
  const interceptor = setupSamlInterceptor(page);
  try {
    await page.goto(samlUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  } catch { /* navigation to 127.0.0.1 may fail */ }

  await interceptor.waitForCapture(60_000);
  const token = interceptor.response || await extractSamlFromPage(page);

  await browser.close();

  if (token) {
    process.stdout.write(token);
  } else {
    process.exit(1);
  }
}

async function saml(samlUrl, stateFile) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: stateFile });
  const page = await context.newPage();

  const interceptor = setupSamlInterceptor(page);

  try {
    await page.goto(samlUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  } catch { /* navigation to 127.0.0.1 may fail */ }

  await interceptor.waitForCapture(5000);
  const token = interceptor.response || await extractSamlFromPage(page);

  // Save updated state (refreshed cookies)
  await context.storageState({ path: stateFile });
  await browser.close();

  if (token) {
    process.stdout.write(token);
  } else {
    process.exit(1);
  }
}

if (cmd === 'login') {
  await login(process.argv[3], process.argv[4], process.argv[5], process.argv[6]);
} else if (cmd === 'saml') {
  await saml(process.argv[3], process.argv[4]);
} else {
  console.error('Usage: pw-saml.mjs login <saml-url> <state-file> [email] [password]');
  console.error('       pw-saml.mjs saml  <saml-url> <state-file>');
  process.exit(1);
}
