// 连接注册中心：token -> 该设备的活跃 socket 集合
const clients = new Map();

function register(token, ws) {
  if (!clients.has(token)) clients.set(token, new Set());
  clients.get(token).add(ws);
}

function unregister(token, ws) {
  const set = clients.get(token);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) clients.delete(token);
}

// 向某 token 的所有活跃 socket 推送；返回实际送达数（无连接则返回 0）
function pushToToken(token, payload) {
  const set = clients.get(token);
  if (!set || set.size === 0) return 0;
  const data = JSON.stringify(payload);
  let n = 0;
  for (const ws of set) {
    // WebSocket 规范：OPEN 状态的 readyState === 1
    if (ws.readyState === 1) {
      ws.send(data);
      n++;
    }
  }
  return n;
}

module.exports = { register, unregister, pushToToken };
