#!/usr/bin/env node
// Собирает PDF-методичку из SETUP.md.
// Запуск:  node pdf/build.js  (нужен google-chrome или chromium в системе)

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const md0 = readFileSync(join(ROOT, "SETUP.md"), "utf8");
let md = md0;

// Заголовок первого уровня выносим на обложку, из документа убираем.
const title = md.match(/^#\s+(.+)$/m)?.[1] ?? "Свой Джарвис за час";
md = md.replace(/^#\s+.+\n/, "");
const lead = md.match(/^\n*([\s\S]*?)\n\n---/)?.[1]?.trim() ?? "";
md = md.replace(/^\n*[\s\S]*?\n\n---\n/, "");

marked.setOptions({ mangle: false, headerIds: true });
const body = marked.parse(md);
const css = readFileSync(join(HERE, "style.css"), "utf8");

const html = `<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>${title}</title>
<style>${css}</style></head>
<body>

<section class="cover">
  <div class="cover-mark">JARVI START</div>
  <h1>${title}</h1>
  <p class="cover-lead">${lead.replace(/\n/g, " ")}</p>
  <ul class="cover-facts">
    <li><b>Час времени.</b> Программировать не нужно</li>
    <li><b>Свой сервер.</b> Данные остаются у вас</li>
    <li><b>Телеграм и панель в браузере.</b> Помощник всегда на связи</li>
    <li><b>Настоящая память.</b> Помнит вас, проекты и договорённости</li>
  </ul>
  <div class="cover-foot">
    <div>Инструкция и скрипты: github.com/kotov67/jarvis-start</div>
    <div>Настройка под ключ: Телеграм @AndreyKotov</div>
  </div>
</section>

<main>${body}</main>

</body></html>`;

const htmlPath = join(HERE, "jarvis-start.html");
writeFileSync(htmlPath, html);

const chrome = ["google-chrome", "chromium", "chromium-browser", "google-chrome-stable"]
  .find((bin) => { try { execFileSync("command", ["-v", bin], { shell: "/bin/bash" }); return true; } catch { return false; } });

if (!chrome) {
  console.log(`HTML собран: ${htmlPath}\nБраузер для печати не найден, PDF пропущен.`);
  process.exit(0);
}

const pdfPath = join(ROOT, "Джарви-Старт.pdf");
execFileSync(chrome, [
  "--headless", "--disable-gpu", "--no-sandbox",
  "--no-pdf-header-footer",
  `--print-to-pdf=${pdfPath}`,
  `file://${htmlPath}`,
], { stdio: "ignore" });

console.log(existsSync(pdfPath) ? `Готово: ${pdfPath}` : "PDF не создался");
