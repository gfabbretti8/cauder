%%%-------------------------------------------------------------------
%%% @doc Rollback operator for the reversible semantics for Erlang
%%% @end
%%%-------------------------------------------------------------------

-module(roll).
-export([can_roll/2, can_roll_send/2, can_roll_spawn/2,
         can_roll_rec/2, can_roll_var/2, can_roll_start/2,
         eval_step/2, eval_roll_send/2, eval_roll_spawn/2,
         eval_roll_start/2, eval_roll_rec/2, eval_roll_var/2]).

-include("cauder.hrl").

can_roll(#sys{procs = Procs}, Pid) ->
  case utils:pid_exists(Procs, Pid) of
    false -> false;
    true ->
      {Proc, _} = utils:select_proc(Procs, Pid),
      Hist = Proc#proc.hist,
      Mail = Proc#proc.mail,
      case {Hist, Mail} of
        {[], []} -> false;
        _ -> true
      end
  end.

eval_step(System, Pid) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {send, _, _, DestPid, {MsgValue, Time}} ->
      {DestProc, _} = utils:select_proc(Procs, DestPid),
      DestNode = DestProc#proc.node,
      NewLog = System#sys.roll ++ utils:gen_log_send(Pid, DestPid, DestNode, MsgValue, Time),
      LogSystem = System#sys{roll = NewLog},
      ?LOG("ROLLing back SEND from " ++ ?TO_STRING(cerl:concrete(Pid)) ++ " to " ++ ?TO_STRING(cerl:concrete(DestPid))),
      roll_send(LogSystem, Pid, DestPid, Time);
    {spawn, _, _, SpawnNode, SpawnPid} ->
      NewLog = System#sys.roll ++ utils:gen_log_spawn(Pid, SpawnNode, SpawnPid),
      LogSystem = System#sys{roll = NewLog},
      ?LOG("ROLLing back SPAWN of " ++ ?TO_STRING(cerl:concrete(SpawnPid))),
      roll_spawn(LogSystem, Pid, SpawnPid, SpawnNode);
    {start, _, _, {ok, SpawnNode}} ->
      NewLog = System#sys.roll ++ utils:gen_log_start(Pid, SpawnNode),
      LogSystem = System#sys{roll = NewLog},
      ?LOG("Rolling back START of " ++ ?TO_STRING(cerl:concrete(SpawnNode))),
      roll_start(LogSystem, Pid, SpawnNode);
    {nodes, _, _, OldNodes} ->
      NewLog = System#sys.roll ++ utils:gen_log_nodes(Pid, OldNodes),
      LogSystem = System#sys{roll = NewLog},
      ?LOG("Rolling back NODES of " ++ ?TO_STRING(cerl:concrete(Pid))),
      roll_nodes(LogSystem, Pid, OldNodes);
    _ ->
      RollOpts = roll_opts(System, Pid),
      cauder:eval_step(System, hd(RollOpts))
  end.

roll_send(System, Pid, OtherPid, Time) ->
  SendOpts = lists:filter(fun (X) -> X#opt.rule == ?RULE_SEND end,
                          roll_opts(System, Pid)),
  case SendOpts of
    [] ->
      SchedOpts = [ X || X <- roll_sched_opts(System, OtherPid),
                              X#opt.id == Time],
      case SchedOpts of
        [] ->
          NewSystem = eval_step(System, OtherPid),
          roll_send(NewSystem, Pid, OtherPid, Time);
        _ ->
          NewSystem = cauder:eval_step(System, hd(SchedOpts)),
          roll_send(NewSystem, Pid, OtherPid, Time)
      end;
    _ ->
      cauder:eval_step(System, hd(SendOpts))
  end.

roll_spawn(System, Pid, OtherPid, SpawnNode) ->
  SpawnOpts = lists:filter(fun (X) -> X#opt.rule == ?RULE_SPAWN end,
                           roll_opts(System, Pid)),
  Procs = System#sys.procs,
  case SpawnOpts of
    [] ->
      case utils:pid_exists(Procs, OtherPid) of
        true ->
          NewSystem = eval_step(System, OtherPid),
          roll_spawn(NewSystem, Pid, OtherPid, SpawnNode);
        false ->
          NodeParentProc = utils:select_proc_with_start(Procs, SpawnNode),
          #proc{pid = NodeParentPid} = NodeParentProc,
          NewSystem = eval_step(System, NodeParentPid),
          roll_spawn(NewSystem, Pid, OtherPid, SpawnNode)
      end;
    _ ->
      cauder:eval_step(System, hd(SpawnOpts))
  end.

roll_start(System, Pid, SpawnNode) ->
  StartOpts = lists:filter(fun (X) -> X#opt.rule == ?RULE_START end,
                           roll_opts(System, Pid)),
  case StartOpts of
    [] ->
      AllProcs = System#sys.procs,
      case utils:select_procs_from_node(AllProcs, SpawnNode) of
        [] ->% start cannot roll either because procs are running or because of nodes or because of a failed start,
          case utils:select_proc_with_failed_start(AllProcs, SpawnNode) of
            [] ->
              OtherProc = hd(utils:select_proc_with_read(AllProcs, SpawnNode)),
              #proc{pid = OtherPid} = OtherProc,
              NewSystem = eval_step(System, OtherPid),
              roll_start(NewSystem, Pid, SpawnNode);
            [OtherProc|_] ->
              #proc{pid = OtherPid} = OtherProc,
              NewSystem = eval_step(System, OtherPid),
              roll_start(NewSystem, Pid, SpawnNode)
          end;
        [OtherProc|_] ->
          #proc{pid = OtherPid} = OtherProc,
          NewSystem = eval_step(System, OtherPid),
          roll_start(NewSystem, Pid, SpawnNode)
      end;
    _ ->
      cauder:eval_step(System, hd(StartOpts))
  end.

roll_nodes(System, Pid, OldNodes) ->
  NodesOpts = lists:filter(fun (X) -> X#opt.rule == ?RULE_NODES end,
                           roll_opts(System, Pid)),
  case NodesOpts of
    [] ->
      #sys{nodes = Nodes, procs = Procs} = System,
      Node = hd(Nodes -- OldNodes),
      OtherProc = hd(utils:select_proc_with_start(Procs, Node)),
      #proc{pid = OtherPid} = OtherProc,
      NewSystem = eval_step(System, OtherPid),
      roll_nodes(NewSystem, Pid, OldNodes);
    _ ->
      cauder:eval_step(System, hd(NodesOpts))
  end.

can_roll_send(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithSend = utils:select_proc_with_send(Procs, Id),
  case length(ProcsWithSend) of
    0 -> false;
    _ -> true
  end.

can_roll_spawn(System, SpawnPid) ->
  Procs = System#sys.procs,
  ProcsWithSpawn = utils:select_proc_with_spawn(Procs, SpawnPid),
  case length(ProcsWithSpawn) of
    0 -> false;
    _ -> true
  end.

can_roll_start(System, SpawnNode) ->
  Procs = System#sys.procs,
  ProcsWithStart = utils:select_proc_with_start(Procs, SpawnNode),
  case length(ProcsWithStart) of
    0 -> false;
    _ -> true
  end.

can_roll_rec(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithRec = utils:select_proc_with_rec(Procs, Id),
  case length(ProcsWithRec) of
    0 -> false;
    _ -> true
  end.

can_roll_var(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithVar = utils:select_proc_with_var(Procs, Id),
  case length(ProcsWithVar) of
    0 -> false;
    _ -> true
  end.

eval_roll_send(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithSend = utils:select_proc_with_send(Procs, Id),
  Proc = hd(ProcsWithSend),
  Pid = Proc#proc.pid,
  eval_roll_until_send(System, Pid, Id).

eval_roll_spawn(System, SpawnPid) ->
  Procs = System#sys.procs,
  ProcsWithSpawn = utils:select_proc_with_spawn(Procs, SpawnPid),
  Proc = hd(ProcsWithSpawn),
  Pid = Proc#proc.pid,
  eval_roll_until_spawn(System, Pid, SpawnPid).

eval_roll_start(System, SpawnNode) ->
  Procs = System#sys.procs,
  ProcsWithStart = utils:select_proc_with_start(Procs, SpawnNode),
  Proc = hd(ProcsWithStart),
  Pid = Proc#proc.pid,
  eval_roll_until_start(System, Pid, SpawnNode, []).

eval_roll_rec(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithRec = utils:select_proc_with_rec(Procs, Id),
  Proc = hd(ProcsWithRec),
  Pid = Proc#proc.pid,
  eval_roll_until_rec(System, Pid, Id).

eval_roll_var(System, Id) ->
  Procs = System#sys.procs,
  ProcsWithVar = utils:select_proc_with_var(Procs, Id),
  Proc = hd(ProcsWithVar),
  Pid = Proc#proc.pid,
  eval_roll_until_var(System, Pid, Id).

eval_roll_until_send(System, Pid, Id) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {send,_,_,_,{_, Id}} ->
      eval_step(System, Pid);
    _ ->
      NewSystem = eval_step(System, Pid),
      eval_roll_until_send(NewSystem, Pid, Id)
  end.

eval_roll_until_spawn(System, Pid, SpawnPid) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {spawn,_,_,_,SpawnPid} ->
      eval_step(System, Pid);
    _ ->
      NewSystem = eval_step(System, Pid),
      eval_roll_until_spawn(NewSystem, Pid, SpawnPid)
  end.

eval_roll_until_start(System, Pid, SpawnNode, []) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {start,_,_,{ok, SpawnNode}} ->
      eval_step(System, Pid);
    _ ->
      NewSystem = eval_step(System, Pid),
      eval_roll_until_start(NewSystem, Pid, SpawnNode, [])
  end.

eval_roll_until_rec(System, Pid, Id) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {rec,_,_, {_, Id},_} ->
      eval_roll_after_rec(System, Pid, Id);
    _ ->
      NewSystem = eval_step(System, Pid),
      eval_roll_until_rec(NewSystem, Pid, Id)
  end.

eval_roll_after_rec(System, Pid, Id) ->
  NewSystem = eval_step(System, Pid),
  Procs = NewSystem#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  [CurHist|_]= Proc#proc.hist,
  case CurHist of
    {rec,_,_, {_, Id},_} ->
      eval_roll_after_rec(NewSystem, Pid, Id);
    _ ->
      NewSystem
  end.

eval_roll_until_var(System, Pid, Id) ->
  Procs = System#sys.procs,
  {Proc, _} = utils:select_proc(Procs, Pid),
  Env = Proc#proc.env,
  case utils:has_var(Env, Id) of
    false ->
      System;
    true ->
      NewSystem = eval_step(System, Pid),
      eval_roll_until_var(NewSystem, Pid, Id)
  end.

roll_opts(System, Pid) ->
  ProcOpts = roll_procs_opts(System, Pid),
  SchedOpts = roll_sched_opts(System, Pid),
  SchedOpts ++ ProcOpts.

roll_procs_opts(System, Pid) ->
  ProcOpts = bwd_sem:eval_procs_opts(System),
  utils:filter_options(ProcOpts, cerl:concrete(Pid)).

roll_sched_opts(System, Pid) ->
  #sys{procs = Procs} = System,
  {Proc, _} = utils:select_proc(Procs, Pid),
  SingleProcSys = #sys{procs = [Proc]},
  bwd_sem:eval_sched_opts(SingleProcSys).
