-- 定时清理超过 30 分钟未更新的房间
-- 在 Supabase Dashboard → SQL Editor 中执行此文件
--
-- 设计意图：
--   updated_at 在加入房间、状态改变、出牌等所有操作时都会更新。
--   30 分钟无任何操作 = 废弃房间（异常退出/关机/强杀），直接清理。
--
-- 关键设计：
--   1. room_chat.room_id 有 ON DELETE CASCADE 外键（见下方 ALTER），
--      删 rooms 行时自动级联删 room_chat，无需手动清理
--   2. SECURITY DEFINER — 绕过 RLS
--   3. SET search_path = public — 防注入

-- ============================================================
-- 1. 外键级联（只需执行一次，重复执行报错可忽略）
-- ============================================================
-- 先清理孤儿聊天记录（room 已不存在但 chat 还在）
DELETE FROM public.room_chat
WHERE room_id NOT IN (SELECT room_id FROM public.rooms);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'fk_room_chat_room'
  ) THEN
    ALTER TABLE public.room_chat
    ADD CONSTRAINT fk_room_chat_room
    FOREIGN KEY (room_id) REFERENCES public.rooms(room_id)
    ON DELETE CASCADE;
  END IF;
END $$;

-- ============================================================
-- 2. 清理函数
-- ============================================================
CREATE OR REPLACE FUNCTION public.cleanup_stale_rooms()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  room_deleted int;
  cutoff bigint;
BEGIN
  cutoff := (EXTRACT(EPOCH FROM now()) * 1000)::bigint - 30 * 60 * 1000;

  -- room_chat 由 ON DELETE CASCADE 自动清理，无需手动 DELETE
  DELETE FROM public.rooms
  WHERE updated_at < cutoff;
  GET DIAGNOSTICS room_deleted = ROW_COUNT;

  RETURN 'Cleaned ' || room_deleted || ' rooms (cutoff=' || cutoff || ')';
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_stale_rooms() TO postgres;

-- ============================================================
-- 3. Cron 调度（每 30 分钟）
-- ============================================================
DO $$
BEGIN
  PERFORM cron.unschedule('cleanup-stale-rooms');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

SELECT cron.schedule(
  'cleanup-stale-rooms',
  '*/30 * * * *',
  $$SELECT public.cleanup_stale_rooms();$$
);
