#!/usr/bin/env node
// pw-saml.mjs — Playwright-based SAML auth for AWS VPN
// Usage:
//   node pw-saml.mjs login  <state-file>              Interactive login, saves session
//   node pw-saml.mjs saml   <saml-url> <state-file>   Headless SAML capture, outputs token

import { chromium } from 'playwright';

const cmd = process.argv[2];
const TIMEOUT = 120_000;

async function login(stateFile) {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext();
  const page = await context.newPage();

  await page.goto('https://login.microsoftonline.com');

  // Wait until redirected away from login page (successful login)
  try {
    await page.waitForURL(
      url => !url.toString().includes('login.microsoftonline.com') || url.toString().includes('kmsi'),
      { timeout: TIMEOUT }
    );
    await page.waitForTimeout(3000);
  } catch {
    // Save state anyway — partial login may still have useful cookies
  }

  await context.storageState({ path: stateFile });
  await browser.close();
}

async function saml(samlUrl, stateFile) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ storageState: stateFile });
  const page = await context.newPage();

  let samlResponse = null;

  // Intercept the SAML POST to 127.0.0.1:35001
  page.on('request', req => {
    if (req.url().includes('127.0.0.1:35001')) {
      const postData = req.postData();
      if (postData) {
        const match = postData.match(/SAMLResponse=([^&]+)/);
        if (match) samlResponse = decodeURIComponent(match[1]);
      }
    }
  });

  try {
    await page.goto(samlUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  } catch {
    // Navigation to 127.0.0.1:35001 may fail — that's OK, we captured the request
  }

  // Wait for potential JS redirects
  await page.waitForTimeout(5000);

  // Fallback: extract from page HTML
  if (!samlResponse) {
    try {
      samlResponse = await page.evaluate(() => {
        const input = document.querySelector('input[name="SAMLResponse"]');
        return input ? input.value : null;
      });
    } catch { /* page may have navigated away */ }
  }

  // Save updated state (refreshed cookies)
  await context.storageState({ path: stateFile });
  await browser.close();

  if (samlResponse) {
    process.stdout.write(samlResponse);
  } else {
    process.exit(1);
  }
}

if (cmd === 'login') {
  await login(process.argv[3]);
} else if (cmd === 'saml') {
  await saml(process.argv[3], process.argv[4]);
} else {
  console.error('Usage: pw-saml.mjs login <state-file>');
  console.error('       pw-saml.mjs saml <saml-url> <state-file>');
  process.exit(1);
}
