local len = redis.call('LLEN', KEYS[1])
if len >= tonumber(ARGV[1]) then
  return 0
end
redis.call('LPUSH', KEYS[1], ARGV[2])
return 1
