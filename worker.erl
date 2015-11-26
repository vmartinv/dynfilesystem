-module(worker).
-include("logging.hrl").
-include("workerstate.hrl").
-export([start/0, start/1, start/2]).

-define(UDPPORT,41581).
-define(MULTICAST,{224, 0, 0, 251}).
-define(DEFPORT,41581).
-define(BROADCAST_INTERVAL, 1000).
-define(SETUP_TIME, 1000).
-define(PACKET_TYPE, {packet, 4}).
-define(DEFFOLDER, "server").

-define(DOCONTINUE, handler(St) ).
-define(DORESET, restart_worker(St) ).

%prepara/reinicia el worker
restart_worker(St) ->
    [Client!reset || Client <- St#wstate.clients],%avisa a los clientes que se reinicio el anillo
    cache!cleanup,
    {ok, Prv, Nxt}=ring:create(St#wstate.port),
    ?INFO("Ring created"), 
	filesystem!dosanitycheck,
    handler(workerstate:reset_start_time(workerstate:set_prv(Prv, workerstate:set_nxt(Nxt, workerstate:set_leader(St))))).
    
%recibe todos los mensajes del worker
handler(St) ->
    {MyId, Prv, Nxt} = {St#wstate.id, St#wstate.prv, St#wstate.nxt},
    receive
    {udp,_,_,_,B} ->
        %~ ?DF("UDP~p", [B]),
        %~ spawn(fun() -> ?DF("~p workers.", [fs:count()]) end),
        case cmd:parse(B) of
        ["SERVER", Id, Ip, Port] when St#wstate.isleader, Id>MyId ->
            case ring:join(Ip, Port, Prv, Nxt, St#wstate.port) of
            continue -> ?DOCONTINUE;
            {ok, PrvN, NxtN} ->
				?INFO("Joined to server ~p at port ~p", [Id, Port]),
                handler(workerstate:reset_start_time(workerstate:set_prv(PrvN, workerstate:set_nxt(NxtN, workerstate:unset_leader(St)))))
            end;
        _ -> ?DOCONTINUE
        end;
    {tcp, Prv, B} ->
        %~ ?DF("TCP~p", [cmd:parse(B)]),
        case cmd:parse(B) of
        ["SETPRV",Ip,Port] ->
            case ring:setPrv(Ip, Port, Prv) of
                continue -> ?DOCONTINUE;
                {ok,PrvN} ->  handler(workerstate:reset_start_time(workerstate:set_prv(PrvN, St)))
            end;
        ["FS", MyId, _, Cmd, {Client, Args}] ->
            spawn(fun() ->
                filesystem!{ring, self(), Cmd, Args},
                receive NArgs -> Client!{ans, NArgs} end
            end), ?DOCONTINUE;
        ["FS", Id, N, Cmd, {Client, Args}] -> %se recibio un mensaje del fs
            spawn(fun() -> %procesarlo y volverlo a mandar
                cache!{get, self(), Id, N},
                receive
                {ok, Ans} -> worker!{send, Ans};
                nocached ->
                    filesystem!{ring, self(), Cmd, Args},
                    receive NArgs ->
                        NAns=cmd:make(["FS", Id, N, Cmd, {Client, NArgs}]),
                        cache!{put, Id, N, NAns},
                        worker!{send, NAns}
                    end
                end
            end), ?DOCONTINUE;
        _ -> exit(?ERROR("Unhandled TCP-MSG: ~p", [B]))
        end;
    {makepaq, Client, Cmd, Args} ->
        Client!cmd:make(["FS", MyId, St#wstate.numpaq, Cmd, {Client, Args}]),
        handler(workerstate:increment_numpaq(St));
    {send, Data} ->
        TimeElapsed=erlang:convert_time_unit(erlang:monotonic_time()-St#wstate.start_time, native, milli_seconds),
        case TimeElapsed>=?SETUP_TIME of
        true ->
            case gen_tcp:send(Nxt, Data) of
            ok -> ok;
            _ -> worker!{send, Data}
            end, ?DOCONTINUE;
        false ->
            spawn(fun () ->
                receive after max(?SETUP_TIME-TimeElapsed+10, 0) ->
                    worker!{send, Data}
                end
            end), ?DOCONTINUE
        end;
    {tcp, Nxt, _} -> ?ERROR("Received msg from Nxt"), halt(1);
    {tcp, S, B} -> % sender desconocido
        case cmd:parse(B) of
        ["WORK", Port] ->%es un worker que quiere unirse
            case ring:addWorker(S, Port, Prv, Nxt) of
                continue -> ?DOCONTINUE;
                reset -> ?DORESET;
                {ok, PrvN, NxtN} -> 
                    ?INFO("Worker accepted"),
                    handler(workerstate:reset_start_time(workerstate:set_prv(PrvN, workerstate:set_nxt(NxtN, St))))
            end;
        ["CON"] ->%es un cliente
            Pid=spawn(fun() -> cliente:handler(clientstate:create(S)) end),
            gen_tcp:controlling_process(S, Pid),
            ?INFO("Accepted client"),
            handler(workerstate:add_client(Pid, St));
        %aqui llegan los mensajes de anillos ya destruidos(descartados):
        _ -> gen_tcp:close(S), ?DOCONTINUE
        end;
    {client_closed, Pid} -> ?INFO("Client disconnected"), handler(workerstate:remove_client(Pid, St));
    {tcp_closed, Nxt} -> gen_tcp:close(Prv), ?DORESET;
    {tcp_closed, Prv} -> gen_tcp:close(Nxt), ?DORESET;
    {tcp_closed, _} -> ?DOCONTINUE;
    {'EXIT',_,Reason} -> exit(?ERROR("~p", [Reason]));
    Msg -> exit(?ERROR("Unhandled MSG: ~p", [Msg]))
    end.

%retorna la ip de la primer interfaz encontrada
getip() -> {ok,[{Ip,_,_}|_]}=inet:getif(), Ip.

%anuncia al worker
announce(UDP, MyId, MyPort, Enabled) ->
    receive
    enable -> announce(UDP, MyId, MyPort, true);
    disable -> announce(UDP, MyId, MyPort, false)
    after ?BROADCAST_INTERVAL ->
        case Enabled of
        true -> gen_udp:send(UDP, ?MULTICAST, ?UDPPORT,  cmd:make(["SERVER", MyId, getip(), MyPort]));
        false -> ok
        end,
        announce(UDP, MyId, MyPort, Enabled)
    end.

%acepta todas las conexiones y las manda al worker
acceptAll(LS) ->
    case gen_tcp:accept(LS) of
    {ok, NS} -> gen_udp:controlling_process(NS,whereis(worker)); 
    {error, Reason} -> ?INFO("Can't accept client: ~p", [Reason])
    end,
    acceptAll(LS).

%formas alternativas de invocar el programa
start() -> start(0, ?DEFFOLDER).
start([MyPortS]) -> start(MyPortS, ?DEFFOLDER);
start([MyPortS, Folder]) -> start(MyPortS, Folder).
start(MyPortS, Folder) when is_list(MyPortS) ->
    MyPort = try list_to_integer(MyPortS) catch _:_ -> usage() end,
    start(MyPort, Folder);
    
%main entry: inicia todo los subsistemas
start(MyPort, Folder) when is_integer(MyPort)->
    register(worker, self()),
    register(cache, spawn_link(fun() -> cache:server() end)),
    {ok, LS} = gen_tcp:listen(MyPort,[binary, ?PACKET_TYPE]),
    {ok, Port} = inet:port(LS),
    MyId=erlang:phash2({Port, Folder, os:system_time(milli_seconds)})+1,
    register(filesystem, spawn_link(fun() -> fs:server(fsstate:create(MyId, Folder)) end)),
    spawn_link(fun() -> acceptAll(LS) end),
    {ok,UDP} = gen_udp:open(?UDPPORT, [binary, {reuseaddr,true}, {active,true},  {ip, ?MULTICAST}, {add_membership, {?MULTICAST, {0,0,0,0}}}]),
    register(announcer, spawn_link(fun() -> announce(UDP, MyId, Port, false) end)),
    ?INFO("Starting worker at port ~p with id ~p, using storage folder ~p", [Port, MyId, Folder]),
    restart_worker(workerstate:create(MyId, Port)).

usage() ->
    io:format(
"usage: worker [Folder] [Port]
(default Folder is "++?DEFFOLDER++")
"), exit(1).
