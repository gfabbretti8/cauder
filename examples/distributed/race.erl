-module(race).
-export([start/0, racer/0]).



start() ->
  R1 = spawn(?MODULE, racer, []),
  R2 = spawn(?MODULE, racer, []),
  R1 ! go,
  R2 ! go.

racer() ->
  Result = receive
             go -> slave:start(another, node)
           end,
  case Result of
    {ok, _} -> winner;
    {error, _} -> loser
  end.
