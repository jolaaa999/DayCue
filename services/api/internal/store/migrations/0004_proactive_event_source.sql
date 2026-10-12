-- 主动候选生产者的读取辅助：把客户端可控的时间文本安全地转成 timestamptz。
--
-- 为什么必须要有它：任务的提醒时刻由客户端写进 sync_record.payload，是**客户端可控文本**。
-- 如果直接写 (payload->>'remind_utc')::timestamptz，那么只要有一台设备推上来一个
-- 畸形字符串（或写了一半的载荷），整个查询就会抛错，导致**所有用户**的提醒都发不出去。
-- 一条坏数据打垮全量，这是不能接受的失败模式。
--
-- 这里把它包成「转不了就返回 NULL」，坏行于是被当成「没有提醒时刻」自然跳过，
-- 只影响它自己那一条。
--
-- 为什么用 STABLE 而不是 IMMUTABLE：带显式偏移量（...Z / +08:00）的输入确实是纯函数，
-- 但不带偏移量的输入会依赖会话的 TimeZone 设置。声明成 IMMUTABLE 会让规划器
-- 在错误的时区下把它常量折叠掉，所以这里保守地用 STABLE。
--
-- 为什么放在 SQL 而不是拿回 Go 里转：过滤与排序要能走索引、LIMIT 才有意义；
-- 拉回 Go 就意味着先把全部 sync_record 读出来。
CREATE OR REPLACE FUNCTION daycue_try_timestamptz(raw TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF raw IS NULL OR btrim(raw) = '' THEN
    RETURN NULL;
  END IF;
  RETURN raw::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;
