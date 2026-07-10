require('dotenv').config();
const express = require('express');
const http = require('http');
const { WebSocketServer, OPEN } = require('ws');
const { AccessToken } = require('livekit-server-sdk');
const crypto = require('crypto');
const os = require('os');
const path = require('path');
const url = require('url');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, '../app')));
app.use('/landing', express.static(path.join(__dirname, '../landing')));
app.use('/guide', express.static(path.join(__dirname, '../guide')));

const LIVEKIT_API_KEY    = process.env.LIVEKIT_API_KEY    || 'devkey';
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET || 'devsecret000000000000000000000000';
const LIVEKIT_URL        = process.env.LIVEKIT_URL        || `ws://localhost:7880`;
const PORT               = process.env.PORT               || 4300;

// rooms: code → { mode: 'webrtc'|'jpeg', broadcaster: ws|null, viewers: Set<ws> }
const rooms = new Map();

function generateCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i++) code += chars[Math.floor(Math.random() * chars.length)];
  return code;
}

app.post('/api/create-room', async (req, res) => {
  try {
    const mode = req.body?.mode === 'jpeg' ? 'jpeg' : 'webrtc';
    const code = generateCode();
    rooms.set(code, { mode, broadcaster: null, viewers: new Set() });
    setTimeout(() => rooms.delete(code), 8 * 60 * 60 * 1000);

    if (mode === 'webrtc') {
      const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
        identity: 'broadcaster', name: 'Broadcaster', ttl: '8h',
      });
      at.addGrant({ room: code, roomJoin: true, roomCreate: true, canPublish: true, canSubscribe: false });
      const token = await at.toJwt();
      res.json({ code, token, livekitUrl: LIVEKIT_URL, mode });
    } else {
      res.json({ code, mode });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/join-room', async (req, res) => {
  try {
    const code = (req.body.code || '').toUpperCase().trim();
    if (!code || code.length !== 6) return res.status(400).json({ error: 'Invalid room code' });
    const room = rooms.get(code);
    const mode = room?.mode || 'webrtc';

    if (mode === 'webrtc') {
      const viewerId = 'viewer-' + crypto.randomBytes(4).toString('hex');
      const at = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
        identity: viewerId, name: 'Viewer', ttl: '8h',
      });
      at.addGrant({ room: code, roomJoin: true, canPublish: false, canSubscribe: true });
      const token = await at.toJwt();
      res.json({ token, livekitUrl: LIVEKIT_URL, mode });
    } else {
      res.json({ mode });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Short URL: beamo.imazyn.com/KWQ4ML → viewer page
app.get('/:code([A-Z0-9]{6})', (req, res) => {
  res.redirect(302, `/viewer.html?code=${req.params.code}`);
});

app.get('/api/info', (req, res) => {
  const host = req.hostname;
  const proto = req.secure || req.headers['x-forwarded-proto'] === 'https' ? 'https' : 'http';
  const port = (proto === 'https' || req.headers['x-forwarded-proto'] === 'https') ? '' : `:${PORT}`;
  res.json({ host, proto, port, url: `${proto}://${host}${port}` });
});

const server = http.createServer(app);

// WebSocket server for JPEG frame relay
const wss = new WebSocketServer({ noServer: true });

server.on('upgrade', (req, socket, head) => {
  const { pathname } = url.parse(req.url);
  if (pathname === '/ws') {
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
  } else {
    socket.destroy();
  }
});

wss.on('connection', (ws, req) => {
  const q = url.parse(req.url, true).query;
  const code = (q.code || '').toUpperCase();
  const role = q.role;

  if (!code || !rooms.has(code)) { ws.close(1008, 'Room not found'); return; }
  const room = rooms.get(code);

  if (role === 'broadcaster') {
    room.broadcaster = ws;
    ws.on('message', data => {
      for (const viewer of room.viewers) {
        if (viewer.readyState === OPEN && !viewer._framePending) {
          viewer._framePending = true;
          viewer.send(data, { binary: true });
        }
      }
    });
    ws.on('close', () => {
      room.broadcaster = null;
      for (const viewer of room.viewers) {
        if (viewer.readyState === OPEN)
          viewer.send(JSON.stringify({ type: 'broadcaster-disconnected' }));
      }
    });
  } else if (role === 'viewer') {
    ws._framePending = false;
    room.viewers.add(ws);
    ws.on('message', () => { ws._framePending = false; });
    ws.on('close', () => room.viewers.delete(ws));
  } else {
    ws.close(1008, 'Invalid role');
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n  Beamo server`);
  console.log(`  Local:       http://localhost:${PORT}`);
  console.log(`  LiveKit URL: ${LIVEKIT_URL}\n`);
});
