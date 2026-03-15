#!/usr/bin/env node
// pw-saml.mjs — Playwright-based SAML auth for AWS VPN
// Usage:
//   node pw-saml.mjs login  <saml-url> <state-file>   Interactive login + SAML capture
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

async function login(samlUrl, stateFile) {
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

  // Now capture SAML in the same browser session (no second Chromium launch)
  const interceptor = setupSamlInterceptor(page);
  try {
    await page.goto(samlUrl, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  } catch { /* navigation to 127.0.0.1 may fail */ }

  await interceptor.waitForCapture(5000);
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
  await login(process.argv[3], process.argv[4]);
} else if (cmd === 'saml') {
  await saml(process.argv[3], process.argv[4]);
} else {
  console.error('Usage: pw-saml.mjs login <saml-url> <state-file>');
  console.error('       pw-saml.mjs saml  <saml-url> <state-file>');
  process.exit(1);
}
