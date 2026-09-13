#!/usr/bin/env node
// Превращает markdown в самодостаточный HTML-файл для чтения в браузере.
// Ссылки открываются в новой вкладке, стиль тот же, что у веб-версии методички.
// Запуск: node pdf/md2html.js <вход.md> <выход.html> "<заголовок вкладки>"

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { marked } from "marked";

const HERE = dirname(fileURLToPath(import.meta.url));
const [, , inPath, outPath, tabTitle] = process.argv;

let md = readFileSync(inPath, "utf8");
md = md.replace(/^---\n[\s\S]*?\n---\n/, ""); // служебная шапка черновика не нужна

marked.setOptions({ mangle: false, headerIds: true });
const body = marked
  .parse(md)
  .replace(/<a href="(https?:\/\/[^"]+)"/g, '<a target="_blank" rel="noopener noreferrer" href="$1"');

const css = readFileSync(join(HERE, "style.css"), "utf8");

writeFileSync(outPath, `<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${tabTitle || "Черновик"}</title>
<style>${css}
body{max-width:820px;margin:0 auto;padding:32px 20px 80px}
main{padding:0}
pre,code{white-space:pre-wrap;word-break:break-word}
blockquote{border-left:4px solid #c9c9c9;margin:16px 0;padding:4px 16px;background:#f6f6f6}
</style></head>
<body><main>${body}</main></body></html>`);

console.log("готово:", outPath);
