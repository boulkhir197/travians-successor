import { Server } from 'socket.io'; import { query } from './db.js';
export function setupWS(httpServer: any) {
  const io = new Server(httpServer, { cors: { origin: '*' } });
  io.on('connection', (socket) => {
    socket.on('chat:send', async (p: { channel: string; text: string; userId: string }) => {
      io.emit('chat:message', { ...p, ts: Date.now() });
      try { await query('insert into chat_messages(channel,user_id,text) values($1,$2,$3)', [p.channel||'global', p.userId||null, p.text||'']); } catch {}
    });
  });
  return io;
}
