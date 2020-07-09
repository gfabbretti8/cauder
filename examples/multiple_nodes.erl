-module(multiple_nodes).

-export([start/0, main/1, ack/1]).

ack(Pid)->
  Pid ! ok.

node(MainPid, Node) ->
  {ok, SpawnedNode} = slave:start('mac',Node),
  spawn(SpawnedNode,?MODULE, ack, [MainPid]).


main(0) -> ok;
main(N) ->
  Pid = self(),
  Node = list_to_atom("node"++ integer_to_list(N)),
  node(Pid, Node),
  receive ok ->
      io:format("Node ~p has been spawned~n",[N])
  end,
  main(N-1).


start() ->
  main(40).
