#!/usr/bin/env node
// Собирает PDF-методичку из SETUP.md.
// Запуск:  node pdf/build.js  (нужен google-chrome или chromium в системе)

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
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

// Веб-версия. Отличается от печатной одним, но важным: все внешние ссылки
// открываются в новой вкладке. В PDF так сделать нельзя — формат этого не умеет,
// а встроенные просмотрщики браузеров скрипты внутри PDF не выполняют, поэтому
// ссылка замещает саму методичку и человек теряет место, на котором читал.
const webBody = body.replace(
  /<a href="(https?:\/\/[^"]+)"/g,
  '<a target="_blank" rel="noopener noreferrer" href="$1"'
);
const webHtml = html
  .replace(`<main>${body}</main>`, `<main>${webBody}</main>`)
  .replace("</head>", `<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="${lead.replace(/\n/g, " ").slice(0, 160)}">
<style>
/* Поля для чтения с экрана. В печатной версии их задаёт @page, но браузер её
   игнорирует, и текст прилипает к краю окна. */
@media screen {
  body { max-width: 900px; margin: 0 auto; padding: 28px 32px 96px; }
  main { padding: 0 }
  .cover { padding: 24px 0 8px }
  img, table, pre { max-width: 100% }
  pre { overflow-x: auto }
}
@media screen and (max-width: 640px) {
  body { padding: 16px 18px 64px }
}
/* Тёмная тема подхватывается из системных настроек: на маке и телефоне лист
   становится тёмным вместе с интерфейсом. Печать это не затрагивает — там
   всегда белый фон, иначе тонер уйдёт впустую. */
@media screen and (prefers-color-scheme: dark) {
  :root {
    --ink: #e6e9ef;
    --muted: #97a1b0;
    --line: #2a323d;
    --accent: #6ea8ff;
    --accent-soft: #17233a;
    --code-bg: #161b22;
  }
  body { background: #0f1419; color: var(--ink); }
  .cover-mark, hr { border-color: var(--line) }
  h1, h2, h3 { color: var(--ink) }
  th { background: var(--code-bg) }
  td, th { border-color: var(--line) }
  blockquote { background: var(--code-bg); border-left-color: var(--accent) }
  img { filter: brightness(.92) }
}
</style>
</head>`);
const webDir = join(ROOT, "web");
if (!existsSync(webDir)) mkdirSync(webDir, { recursive: true });
writeFileSync(join(webDir, "index.html"), webHtml);
console.log(`Веб-версия: ${join(webDir, "index.html")}`);

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
