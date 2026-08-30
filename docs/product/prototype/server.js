const http = require('http');
const fs = require('fs');
const path = require('path');

// 紫夜可交互原型的**本地预览**服务器：只给设计对照用，不在发布链路里，
// Release 门禁不依赖 Node/npm。根目录取仓库根，这样页面引用的入库背景图
// （`apps/qiyu_flutter/assets/images/…`）与页面自身都过得了下面那条 root 检查。
const root = path.resolve(__dirname, '..', '..', '..');
const entry = 'docs/product/prototype/index.html';
const port = 4765;
const types = {
  '.html': 'text/html; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.png': 'image/png',
  '.css': 'text/css',
  '.js': 'text/javascript',
};

http.createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = path.join(root, urlPath === '/' ? entry : urlPath);
  if (!file.startsWith(root)) { res.writeHead(403); res.end(); return; }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(port, '127.0.0.1', () => console.log('http://127.0.0.1:' + port + '/'));
