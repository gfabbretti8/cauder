-module(test_node).
-export([main/0]).




main() ->
  io:format("I'm ~p~n", [nodes()]).
