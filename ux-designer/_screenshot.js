const puppeteer = require('/opt/homebrew/lib/node_modules/fast-cli/node_modules/puppeteer');
const path = require('path');

async function main() {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('Usage: node screenshot.js <html1> <html2> ...');
    process.exit(1);
  }
  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 900, deviceScaleFactor: 2 });

  for (const file of files) {
    const absPath = path.resolve(file);
    console.log(`Screenshotting: ${absPath}`);
    await page.goto('file://' + absPath, { waitUntil: 'networkidle0', timeout: 15000 });
    await new Promise(r => setTimeout(r, 500));
    const outPath = absPath.replace(/\.html$/, '.png');
    await page.screenshot({ path: outPath, fullPage: false });
    console.log(`  → ${outPath}`);
  }

  await browser.close();
  console.log('Done.');
}

main().catch(err => { console.error(err); process.exit(1); });
