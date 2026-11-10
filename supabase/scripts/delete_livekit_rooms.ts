/**
 * 管理 LiveKit 房间 —— 查看和删除残留的 active 房间
 *
 * 用法（需要 Deno）：
 *   deno run --allow-net --allow-env supabase/scripts/delete_livekit_rooms.ts list
 *   deno run --allow-net --allow-env supabase/scripts/delete_livekit_rooms.ts delete <roomId>
 *   deno run --allow-net --allow-env supabase/scripts/delete_livekit_rooms.ts delete-all
 *
 * 环境变量（从 Supabase Dashboard → Project Settings → Edge Functions 获取）：
 *   LIVEKIT_API_KEY
 *   LIVEKIT_API_SECRET
 *   LIVEKIT_WS_URL     e.g. wss://xxxx.livekit.cloud
 */

/**
 * 手动设置（若没有配置环境变量）：
 */
//  const LIVEKIT_API_KEY = '';
//  const LIVEKIT_API_SECRET = '';
//  const LIVEKIT_WS_URL = '';

async function signToken(
  secret: string,
  apiKey: string,
  subject: string,
  ttlSec: number,
  grants: Record<string, unknown>,
): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(secret);
  const key = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    iss: apiKey,
    sub: subject,
    exp: Math.floor(Date.now() / 1000) + ttlSec,
    video: grants,
  };

  const headerB64 = btoa(JSON.stringify(header)).replace(/=+$/, '');
  const payloadB64 = btoa(JSON.stringify(payload)).replace(/=+$/, '');
  const sigBuf = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(`${headerB64}.${payloadB64}`),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=+$/, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');

  return `${headerB64}.${payloadB64}.${sigB64}`;
}

async function main() {
  const apiKey = Deno.env.get('LIVEKIT_API_KEY')!;
  const secret = Deno.env.get('LIVEKIT_API_SECRET')!;
  const host = Deno.env.get('LIVEKIT_WS_URL')!.replace('wss://', 'https://');

  //  若没配环境变量，取消上面的注释，注释掉上面三行，用下面的：
  //  const apiKey = LIVEKIT_API_KEY;
  //  const secret = LIVEKIT_API_SECRET;
  //  const host = LIVEKIT_WS_URL.replace('wss://', 'https://');

  const cmd = Deno.args[0];
  const roomId = Deno.args[1];

  const adminToken = await signToken(secret, apiKey, 'admin', 60, {
    roomAdmin: true,
    roomCreate: true,
    roomList: true,
  });

  const headers = {
    Authorization: `Bearer ${adminToken}`,
    'Content-Type': 'application/json',
  };

  if (cmd === 'list') {
    const res = await fetch(`${host}/twirp/livekit.RoomService/ListRooms`, {
      method: 'POST',
      headers,
      body: JSON.stringify({}),
    });
    const data = await res.json();
    if (data.rooms?.length) {
      console.log(`${data.rooms.length} 个 active 房间:\n`);
      for (const room of data.rooms) {
        console.log(
          `  ${room.name}  ·  ${room.numParticipants} 人  ·  created ${new Date(Number(room.creationTime) * 1000).toLocaleString()}`,
        );
      }
    } else {
      console.log('没有 active 房间');
    }
  } else if (cmd === 'delete') {
    if (!roomId) {
      console.error('用法: deno run ... delete <roomId>');
      Deno.exit(1);
    }
    const res = await fetch(
      `${host}/twirp/livekit.RoomService/DeleteRoom`,
      {
        method: 'POST',
        headers,
        body: JSON.stringify({ room: roomId }),
      },
    );
    if (res.ok) {
      console.log(`房间 ${roomId} 已删除 ✓`);
    } else {
      console.error(`删除失败: ${res.status} ${await res.text()}`);
    }
  } else if (cmd === 'delete-all') {
    const listRes = await fetch(
      `${host}/twirp/livekit.RoomService/ListRooms`,
      { method: 'POST', headers, body: JSON.stringify({}) },
    );
    const data = await listRes.json();
    if (!data.rooms?.length) {
      console.log('没有需要删除的房间');
      return;
    }
    for (const room of data.rooms) {
      const delRes = await fetch(
        `${host}/twirp/livekit.RoomService/DeleteRoom`,
        {
          method: 'POST',
          headers,
          body: JSON.stringify({ room: room.name }),
        },
      );
      if (delRes.ok) {
        console.log(`  ${room.name} ✓`);
      } else {
        console.log(`  ${room.name} ✗`);
      }
    }
    console.log('\n清理完成');
  } else {
    console.log(
      '用法:\n  list       查看所有 active 房间\n  delete <id>  删除指定房间\n  delete-all  删除所有房间',
    );
  }
}

main();
