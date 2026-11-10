-- Supabase schema for Landlord (斗地主) online multiplayer
-- Run this in Supabase Dashboard > SQL Editor

-- ============================================================
-- rooms 表：每个房间一行，所有状态以 JSONB 存储
-- ============================================================
CREATE TABLE IF NOT EXISTS rooms (
  room_id       TEXT PRIMARY KEY,
  host_uid      TEXT NOT NULL,
  chat_enabled  BOOLEAN DEFAULT true,
  status        TEXT DEFAULT 'waiting',   -- waiting | playing | settled | closed
  created_at    BIGINT NOT NULL,
  seats         JSONB DEFAULT '[]'::jsonb,  -- [{uid,nick,online}, null, null]
  game_state    JSONB,                       -- 房主广播的公共游戏状态
  pending_action JSONB,                      -- 非房主提交的动作
  ready         JSONB DEFAULT '[false,false,false]'::jsonb,
  hands         JSONB DEFAULT '{}'::jsonb,   -- {"0":[cardIndex,...], "1":[...], "2":[...]}
  updated_at    BIGINT NOT NULL DEFAULT 0
);

-- ============================================================
-- room_chat 表：聊天消息（按时间追加）
-- ============================================================
CREATE TABLE IF NOT EXISTS room_chat (
  id        BIGSERIAL PRIMARY KEY,
  room_id   TEXT NOT NULL REFERENCES rooms(room_id) ON DELETE CASCADE,
  by_seat   INT NOT NULL,
  nick      TEXT NOT NULL,
  text      TEXT NOT NULL,
  ts        BIGINT NOT NULL
);

-- ============================================================
-- RLS 策略：认证用户可读写
-- ============================================================
ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_chat ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rooms_authenticated_all" ON rooms;
CREATE POLICY "rooms_authenticated_all" ON rooms
  FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "chat_authenticated_all" ON room_chat;
CREATE POLICY "chat_authenticated_all" ON room_chat
  FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- ============================================================
-- 启用 Realtime（Postgres Changes）
-- ============================================================
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE rooms;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE room_chat;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

-- ============================================================
-- 索引
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_room_chat_room_id ON room_chat(room_id);
CREATE INDEX IF NOT EXISTS idx_rooms_status ON rooms(status);
