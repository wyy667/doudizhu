import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { create, getNumericDate, Header, Payload } from 'https://deno.land/x/djwt@v2.8/mod.ts';

const LIVEKIT_API_KEY = Deno.env.get('LIVEKIT_API_KEY')!;
const LIVEKIT_API_SECRET = Deno.env.get('LIVEKIT_API_SECRET')!;
const LIVEKIT_WS_URL = Deno.env.get('LIVEKIT_WS_URL')!;
const LIVEKIT_HOST = LIVEKIT_WS_URL.replace('wss://', 'https://');
const ADMIN_PASSWORD = Deno.env.get('ADMIN_PASSWORD')!;

const ADMIN_ACTIONS = ['list', 'delete', 'delete-all', 'verify-password'] as const;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

async function signAdminToken(videoGrants: Record<string, unknown>): Promise<string> {
  const encoder = new TextEncoder();
  const keyData = encoder.encode(LIVEKIT_API_SECRET);
  const key = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  return await create(
    { alg: 'HS256', typ: 'JWT' },
    {
      iss: LIVEKIT_API_KEY,
      sub: 'admin',
      exp: getNumericDate(60),
      video: videoGrants,
    },
    key,
  );
}

function checkAdminPassword(body: Record<string, unknown>): Response | null {
  if (!ADMIN_PASSWORD) {
    return new Response(
      JSON.stringify({ error: 'ADMIN_PASSWORD not configured' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
  if (body.adminPassword !== ADMIN_PASSWORD) {
    return new Response(
      JSON.stringify({ error: '密码错误' }),
      { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
  return null;
}

async function ensureRoom(roomId: string) {
  const adminToken = await signAdminToken({
    roomCreate: true,
    roomAdmin: true,
    room: roomId,
  });

  const res = await fetch(`${LIVEKIT_HOST}/twirp/livekit.RoomService/CreateRoom`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${adminToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: roomId, empty_timeout: 60, max_participants: 5 }),
  });

  if (!res.ok && res.status !== 409) {
    const text = await res.text();
    console.error(`[LiveKit] CreateRoom failed (${res.status}): ${text}`);
  } else {
    console.log(`[LiveKit] ensureRoom: ${roomId} (status=${res.status})`);
  }
}

async function listRooms(): Promise<Record<string, unknown>[]> {
  const adminToken = await signAdminToken({ roomAdmin: true, roomList: true });
  const res = await fetch(`${LIVEKIT_HOST}/twirp/livekit.RoomService/ListRooms`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${adminToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    const text = await res.text();
    console.error(`[LiveKit] ListRooms failed (${res.status}): ${text}`);
    throw new Error(`ListRooms failed: ${res.status}`);
  }
  const data = await res.json();
  const rooms = data.rooms ?? [];
  console.log(`[LiveKit] ListRooms: ${rooms.length} rooms`);
  return rooms;
}

async function deleteLiveKitRoom(roomId: string): Promise<void> {
  const adminToken = await signAdminToken({ roomCreate: true, roomAdmin: true, room: roomId });
  const res = await fetch(`${LIVEKIT_HOST}/twirp/livekit.RoomService/DeleteRoom`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${adminToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ room: roomId }),
  });
  const body = await res.text();
  if (res.ok) {
    console.log(`[LiveKit] DeleteRoom OK: ${roomId} → "${body}"`);
  } else {
    console.error(`[LiveKit] DeleteRoom failed (${res.status}): ${body}`);
    throw new Error(`DeleteRoom ${res.status}: ${body}`);
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();

    const action = body.action as string | undefined;
    if (action && ADMIN_ACTIONS.includes(action as typeof ADMIN_ACTIONS[number])) {
      const needsPassword = action !== 'delete' || body.adminPassword;
      if (needsPassword) {
        const pwErr = checkAdminPassword(body);
        if (pwErr) return pwErr;
      }

      if (action === 'verify-password') {
        return new Response(JSON.stringify({ ok: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (action === 'list') {
        const rooms = await listRooms();
        return new Response(JSON.stringify({ rooms }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (action === 'delete') {
        if (!body.roomId) {
          return new Response(JSON.stringify({ error: 'roomId is required' }), {
            status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          });
        }
        await deleteLiveKitRoom(body.roomId as string);
        return new Response(JSON.stringify({ ok: true }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }

      if (action === 'delete-all') {
        const rooms = await listRooms();
        let deleted = 0;
        for (const room of rooms) {
          try {
            await deleteLiveKitRoom(room.name as string);
            deleted++;
          } catch (e) {
            console.error(`[LiveKit] delete-all skip ${room.name}: ${e}`);
          }
        }
        return new Response(JSON.stringify({ ok: true, deleted, total: rooms.length }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }

    // ── 签发语音 Token ──
    const { roomId, uid } = body;
    if (!roomId || !uid) {
      return new Response(JSON.stringify({ error: 'roomId and uid are required' }), {
        status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    await ensureRoom(roomId);

    const encoder = new TextEncoder();
    const keyData = encoder.encode(LIVEKIT_API_SECRET);
    const key = await crypto.subtle.importKey(
      'raw', keyData, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );

    const header: Header = { alg: 'HS256', typ: 'JWT' };
    const payload: Payload = {
      iss: LIVEKIT_API_KEY,
      sub: uid,
      exp: getNumericDate(60 * 60),
      nbf: getNumericDate(0),
      video: { room: roomId, roomJoin: true, canPublish: true, canSubscribe: true },
    };

    const token = await create(header, payload, key);
    return new Response(JSON.stringify({ token, url: LIVEKIT_WS_URL }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    console.error(`[Voice] Error: ${(e as Error).message}`);
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
