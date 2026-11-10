/**
 * 管理 LiveKit 房间 —— 查看和删除残留 active 房间
 *
 * 用法（Node.js，零依赖）：
 *   node supabase/scripts/delete_livekit_rooms.cjs list
 *   node supabase/scripts/delete_livekit_rooms.cjs delete <roomId>
 *   node supabase/scripts/delete_livekit_rooms.cjs delete-all
 *
 * 运行前先设置下面的 LIVEKIT_* 常量，或通过环境变量传入。
 */

// ── 手动设置（从 Supabase Dashboard → Project Settings → Edge Functions 获取）──
const LIVEKIT_API_KEY = '';
const LIVEKIT_API_SECRET = '';
const LIVEKIT_WS_URL = 'wss://xxxx.livekit.cloud';

const HOST = (process.env.LIVEKIT_WS_URL || LIVEKIT_WS_URL).replace('wss://', 'https://');
const API_KEY = process.env.LIVEKIT_API_KEY || LIVEKIT_API_KEY;
const SECRET = process.env.LIVEKIT_API_SECRET || LIVEKIT_API_SECRET;

const crypto = require('crypto');

function b64url(buf) {
  return buf.toString('base64').replace(/=+$/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function signToken(payload) {
  const header = b64url(Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const body = b64url(Buffer.from(JSON.stringify(payload)));
  const sig = crypto.createHmac('sha256', SECRET).update(`${header}.${body}`).digest();
  return `${header}.${body}.${b64url(sig)}`;
}

async function apiCall(grants, path, body) {
  const token = signToken({
    iss: API_KEY,
    sub: 'admin',
    exp: Math.floor(Date.now() / 1000) + 60,
    video: grants,
  });

  const res = await fetch(`${HOST}${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${res.status}: ${text}`);
  }
  return res.json();
}

async function main() {
  const [cmd, roomId] = process.argv.slice(2);

  if (!API_KEY || !SECRET) {
    console.error('请设置 LIVEKIT_API_KEY / LIVEKIT_API_SECRET / LIVEKIT_WS_URL');
    process.exit(1);
  }

  const adminGrants = { roomAdmin: true, roomCreate: true, roomList: true };

  if (cmd === 'list') {
    const data = await apiCall(adminGrants, '/twirp/livekit.RoomService/ListRooms', {});
    if (data.rooms?.length) {
      console.log(`${data.rooms.length} 个 active 房间:\n`);
      for (const room of data.rooms) {
        console.log(
          `  ${room.name}  ·  ${room.numParticipants} 人  ·  ${new Date(Number(room.creationTime) * 1000).toLocaleString()}`
        );
      }
    } else {
      console.log('没有 active 房间');
    }
  } else if (cmd === 'delete') {
    if (!roomId) { console.error('用法: node supabase/scripts/delete_livekit_rooms.cjs delete <roomId>'); process.exit(1); }
    const data = await apiCall(adminGrants, '/twirp/livekit.RoomService/DeleteRoom', { room: roomId });
    console.log(`房间 ${roomId} 已删除 ✓`);
  } else if (cmd === 'delete-all') {
    const { rooms } = await apiCall(adminGrants, '/twirp/livekit.RoomService/ListRooms', {});
    if (!rooms?.length) { console.log('没有需要删除的房间'); return; }
    for (const room of rooms) {
      try {
        await apiCall(adminGrants, '/twirp/livekit.RoomService/DeleteRoom', { room: room.name });
        console.log(`  ${room.name} ✓`);
      } catch (e) {
        console.log(`  ${room.name} ✗ (${e.message})`);
      }
    }
    console.log('\n清理完成');
  } else {
    console.log('用法:\n  list        查看所有 active 房间\n  delete <id>  删除指定房间\n  delete-all  删除所有房间');
  }
}

main().catch(e => { console.error(e.message); process.exit(1); });
