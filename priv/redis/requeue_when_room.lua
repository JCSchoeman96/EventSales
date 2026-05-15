local pending_len = redis.call('LLEN', KEYS[1])
if pending_len >= tonumber(ARGV[1]) then
  return 0
end
local removed = redis.call('LREM', KEYS[2], 1, ARGV[2])
if removed == 0 then
  return -1
end
redis.call('RPUSH', KEYS[1], ARGV[2])
return 1
