%%%-------------------------------------------------------------------
%%% @doc Some functions that implement the backward (reversible)
%%% semantics for Erlang. These can be divided into functions to get
%%% the evaluation options and functions to perform the evaluation
%%% @end
%%%-------------------------------------------------------------------

-module(bwd_sem).
-export([eval_step/2, eval_sched/2, eval_opts/1,
         eval_procs_opts/1, eval_sched_opts/1]).

-include("cauder.hrl").

%%--------------------------------------------------------------------
%% @doc Performs an evaluation step in process Pid, given System
%% @end
%%--------------------------------------------------------------------
eval_step(System, Pid) ->
  Procs = System#sys.procs,
  Msgs = System#sys.msgs,
  Trace = System#sys.trace,
  Nodes = System#sys.nodes,
  {Proc, RestProcs} = utils:select_proc(Procs, Pid),
  #proc{pid = Pid, node = Node, hist = [CurHist|RestHist]} = Proc,
  case CurHist of
    {tau, OldEnv, OldExp} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      System#sys{msgs = Msgs, procs = [OldProc|RestProcs]};
    {self, OldEnv, OldExp} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      System#sys{msgs = Msgs, procs = [OldProc|RestProcs]};
    {node, OldEnv, OldExp} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      System#sys{procs = [OldProc|RestProcs]};
    {nodes, OldEnv, OldExp, _OldNodes} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      TraceItem = #trace{ type = ?RULE_NODES, from = Pid},
      OldTrace = lists:delete(TraceItem,Trace),
      System#sys{msgs = Msgs, procs = [OldProc|RestProcs], trace = OldTrace};
    {send, OldEnv, OldExp, DestPid, {MsgValue, Time}} ->
      {_Msg, RestMsgs} = utils:select_msg(Msgs, Time),
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      {DestProc, _} = utils:select_proc(Procs, DestPid),
      DestNode = DestProc#proc.node,
      TraceItem = #trace{type = ?RULE_SEND, from = Pid, fromNode = Node, to = DestPid, toNode = DestNode, val = MsgValue, time = Time},
      OldTrace = lists:delete(TraceItem, Trace),
      System#sys{msgs = RestMsgs, procs = [OldProc|RestProcs], trace = OldTrace};
    {start, OldEnv, OldExp, {Result,NodeOrTime}} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
      case Result of
        ok ->
          SpawnNode = NodeOrTime,
          OldNodes = Nodes -- [SpawnNode],
          TraceItem = #trace{type = ?RULE_START, from = Pid, start = SpawnNode},
          OldTrace = lists:delete(TraceItem, Trace),
          System#sys{procs = [OldProc|RestProcs], nodes = OldNodes, trace = OldTrace};
        error ->
          Time = NodeOrTime,
          TraceItem = #trace{type = ?RULE_START, from = Pid, start = error, time = Time},
          OldTrace = lists:delete(TraceItem, Trace),
          System#sys{procs = [OldProc|RestProcs], trace = OldTrace}
      end;
    {spawn , OldEnv, OldExp, SpawnNode, SpawnPid} ->
      case utils:pid_exists(RestProcs, SpawnPid) of
        true ->
          {_SpawnProc, OldRestProcs} = utils:select_proc(RestProcs, SpawnPid),
          OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
          TraceItem = #trace{type = ?RULE_SPAWN, from = Pid, fromNode = Node, to = SpawnPid, toNode = SpawnNode, result = ok},
          OldTrace = lists:delete(TraceItem, Trace),
          System#sys{msgs = Msgs, procs = [OldProc|OldRestProcs], trace = OldTrace};
        false ->
          OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp},
          TraceItem = #trace{type = ?RULE_SPAWN, from = Pid, fromNode = Node, to = SpawnPid, toNode = SpawnNode, result = error},
          OldTrace = lists:delete(TraceItem, Trace),
          System#sys{msgs = Msgs, procs = [OldProc|RestProcs], trace = OldTrace}
      end;
    {rec, OldEnv, OldExp, OldMsg, OldMail} ->
      OldProc = Proc#proc{hist = RestHist, env = OldEnv, exp = OldExp, mail = OldMail},
      {MsgValue, Time} = OldMsg,
      TraceItem = #trace{type = ?RULE_RECEIVE, from = Pid, val = MsgValue, time = Time},
      OldTrace = lists:delete(TraceItem, Trace),
      System#sys{msgs = Msgs, procs = [OldProc|RestProcs], trace = OldTrace}
  end.

%%--------------------------------------------------------------------
%% @doc Performs an evaluation step in message Id, given System
%% @end
%%--------------------------------------------------------------------
eval_sched(System, Id) ->
  Procs = System#sys.procs,
  Msgs = System#sys.msgs,
  Proc = utils:select_proc_with_time(Procs, Id),
  Pid = Proc#proc.pid,
  {_, RestProcs} = utils:select_proc(Procs, Pid),
  Mail = Proc#proc.mail,
  {LastMsg,RestMail} = utils:last_msg_rest(Mail),
  {Value, Id} = LastMsg,
  OldMsg = #msg{dest = Pid, val = Value, time = Id},
  OldProc = Proc#proc{mail = RestMail},
  OldMsgs = [OldMsg|Msgs],
  OldProcs = [OldProc|RestProcs],
  System#sys{msgs = OldMsgs, procs = OldProcs}.

%%--------------------------------------------------------------------
%% @doc Gets the evaluation options for a given System
%% @end
%%--------------------------------------------------------------------
eval_opts(System) ->
  SchedOpts = eval_sched_opts(System),
  ProcsOpts = eval_procs_opts(System),
  SchedOpts ++ ProcsOpts.

eval_sched_opts(#sys{procs = Procs}) ->
  Opts = [eval_sched_opt(Proc) || Proc <- Procs],
  lists:filter(fun (X) ->
                  case X of
                    ?NULL_OPT -> false;
                    _ -> true
                  end
                end, Opts).

eval_procs_opts(System) ->
  Procs = System#sys.procs,
  Msgs = System#sys.msgs,
  Nodes = System#sys.nodes,
  ProcPairs = [utils:select_proc(Procs, Proc#proc.pid) || Proc <- Procs ],
  Opts = [eval_proc_opt(#sys{msgs = Msgs, procs = RestProcs}, Nodes, Proc) ||  {Proc, RestProcs} <- ProcPairs],
  lists:filter( fun (X) ->
                  case X of
                    ?NULL_OPT -> false;
                    _Other -> true
                  end
                end, Opts).

eval_proc_opt(RestSystem, Nodes, CurProc) ->
  RestProcs = RestSystem#sys.procs,
  Msgs = RestSystem#sys.msgs,
  Hist = CurProc#proc.hist,
  Rule =
    case Hist of
      [] ->
        ?NULL_RULE;
      [CurHist|_RestHist] ->
        case CurHist of
          {tau,_,_} ->  ?RULE_SEQ;
          {self,_,_} -> ?RULE_SELF;
          {node,_,_} -> ?RULE_NODE;
          {nodes,_,_,OldNodes} ->
            case Nodes -- OldNodes of
              [] -> ?RULE_NODES;
              _ -> ?NULL_RULE
            end;
          {send,_,_, DestPid, {MsgValue, Time}} ->
            MsgList = [ M || M <- Msgs, M#msg.time == Time,
                             M#msg.dest == DestPid,
                             M#msg.val == MsgValue ],
            case MsgList of
              [] -> ?NULL_RULE;
              _ -> ?RULE_SEND
            end;
          {start,_,_,{ok,StartedNode}} ->
            case utils:select_procs_from_node(RestProcs, StartedNode) of
              [] ->
                case utils:select_proc_with_read(RestProcs, StartedNode) of
                  [] -> ?RULE_START;
                  _ -> ?NULL_RULE
                  end;
              _ -> ?NULL_RULE
            end;
          {start,_,_,{error,_}} -> ?RULE_START;
          {spawn,_,_,SpawnNode,SpawnPid} ->
            case utils:pid_exists(RestProcs, SpawnPid) of 
              true -> {SpawnProc, _RestProcs} = utils:select_proc(RestProcs, SpawnPid),
                      #proc{hist = SpawnHist, mail = SpawnMail} = SpawnProc,
                      case {SpawnHist, SpawnMail} of
                        {[], []} -> ?RULE_SPAWN;
                        _ -> ?NULL_RULE
                      end;
              false ->
                case utils:node_exists(SpawnNode, Nodes) of
                  true -> ?NULL_RULE;
                  false -> ?RULE_SPAWN
                end
              end;
              {rec,_,_, ConsMsg, OldMail} ->
                Mail = CurProc#proc.mail,
                case utils:is_queue_minus_msg(OldMail, ConsMsg, Mail) of
                  true -> ?RULE_RECEIVE;
                  false -> ?NULL_RULE
                end
            end
    end,
  case Rule of
    ?NULL_RULE -> ?NULL_OPT;
    OtherRule ->
      Pid = CurProc#proc.pid,
      #opt{sem = ?MODULE, type = ?TYPE_PROC, id = cerl:concrete(Pid), rule = OtherRule}
  end.

eval_sched_opt(Proc) ->
  #proc{hist = Hist, mail = Mail} = Proc,
  Rule =
    case Mail of
      [] -> ?NULL_RULE;
      _ ->
        {LastMsg,_} = utils:last_msg_rest(Mail),
        {_,Time} = LastMsg,
        TopRec = utils:topmost_rec(Hist),
        case TopRec of
          no_rec -> {?RULE_SCHED, Time};
          {rec,_,_,OldMsg,OldMail} ->
            case utils:is_queue_minus_msg(OldMail, OldMsg, Mail) of
              false -> {?RULE_SCHED, Time};
              true -> ?NULL_RULE
            end
        end
    end,
  case Rule of
    ?NULL_RULE -> ?NULL_OPT;
    {OtherRule, Id} ->
      #opt{sem = ?MODULE, type = ?TYPE_MSG, id = Id, rule = OtherRule}
  end.
