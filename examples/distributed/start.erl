-module(start).
-export([start/0, child/1, helloWorld/0]).


start() ->
  Child = spawn(?MODULE, child, [self()]),
  Child ! vai1,
  receive vai2 -> ok end,
  slave:start('coolHost', 'coolName'),
  slave:start('coolHost', 'coolName'),
  U = nodes(),
  Child ! vai3,
  U.

child(Parent) ->
  receive vai1 -> ok end,
  U = nodes(),
  spawn('doesnt@exist', ?MODULE, helloWorld, []),
  Parent ! vai2,
  receive vai3 -> ok end,
  slave:start('anotherCoolHost', 'coolName'),
   U.



helloWorld() ->
  io:format("Hello world.~n").
