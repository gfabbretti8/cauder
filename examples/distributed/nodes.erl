-module(nodes).
-export([start/0, child/1]).




start() ->
  Child = spawn(?MODULE, child, [self()]),
  self() ! checkpoint,
  U = nodes(),
  Child ! vai1,
  U.




child(_P) ->
  receive vai1 -> ok end,
  slave:start('mac', 'coolName').
