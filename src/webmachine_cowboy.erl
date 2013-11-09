%% @copyright 2012-2013 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc Cowboy interface for webmachine.
-module(webmachine_cowboy).

-ifdef(WEBMACHINE_COWBOY).
-behaviour(webmachine_server).
-export([start/1, stop/1]).
-export([init/3, handle/2, terminate/3]).
-export([get_header_value/2,
         new_headers/0,
         make_headers/1,
         add_header/3,
         merge_header/3,
         headers_to_list/1,
         headers_from_list/1,
         get_listen_port/1,
         send_reply/5,
         recv_body/2,
         recv_stream_body/3,
         make_reqdata/1,
         send/2,
         recv/3,
         setopts/2
        ]).

-include("wm_reqdata.hrl").

start(Options0) ->
    {PName, DGroup, Options} = webmachine_ws:start(Options0, ?MODULE),
    {ok, _Apps} = application:ensure_all_started(cowboy),
    Name = list_to_atom(atom_to_list(PName) ++ "_cowboy"),
    LoadedInfo = proplists:get_value(loaded, application_controller:info()),
    {cowboy, _, Version} = lists:keyfind(cowboy, 1, LoadedInfo),
    ok = application:set_env(webmachine, server_version, "Cowboy/" ++ Version),
    Conf = convert_options(Options, []),
    Dispatch = cowboy_router:compile([{'_', [{'_', ?MODULE, [{dispatch, DGroup}]}]}]),
    Env = [{env, [{dispatch, Dispatch}]}],
    {ok, Pid} = cowboy:start_http(Name, 100, Conf, Env),
    register(Name, Pid),
    {ok, Pid}.

stop(Name) when is_atom(Name) ->
    cowboy:stop_listener(Name);
stop(Pid) ->
    {registered_name, Name} = process_info(Pid, registered_name),
    stop(Name).

init({_, Scheme}, Req, [{dispatch, DGroup}]) ->
    {ok, Req, {DGroup, Scheme}}.

handle(CowboyReq, {DGroup, Scheme}=State) ->
    Req = webmachine:new_request(cowboy, {CowboyReq, Scheme}),
    webmachine_ws:dispatch_request(DGroup, Req),
    NewCowboyReq = erase(wsdata),
    true = (NewCowboyReq /= undefined),
    {ok, NewCowboyReq, State}.

terminate(_Reason, _Req, _State) ->
    ok.

get_header_value(HeaderName, Headers) ->
    Fold = fun({H0, V}, undefined) ->
                   {HN, H1} = {to_binary(HeaderName), to_binary(H0)},
                   case H1 == HN of
                       true ->
                           case is_binary(V) of
                               true ->
                                   throw(binary_to_list(V));
                               false ->
                                   throw(V)
                           end;
                       false ->
                           undefined
                   end;
              (_, Acc) ->
                   Acc
           end,
    try lists:foldl(Fold, undefined, Headers)
    catch throw:V -> V
    end.

new_headers() ->
    [].

make_headers(Headers) ->
    Headers.

add_header(Header, Value, Headers) ->
    [{Header, Value} | Headers].

merge_header(Header, Value, Headers) ->
    case lists:keytake(Header, 1, Headers) of
        {value, {Header, OldValue}, Rest} ->
            [{Header, OldValue ++ ", " ++ Value} | Rest];
        false ->
            [{Header, Value} | Headers]
    end.

headers_to_list(Headers) ->
    Headers.

headers_from_list(Headers) ->
    [{to_binary(H), to_binary_preserve_case(V)} || {H,V} <- Headers].

get_listen_port(Server) ->
    {registered_name, Name} = process_info(Server, registered_name),
    ranch:get_port(Name).

send_reply(S, Status, Headers, Body, RD) when is_list(Status) ->
    send_reply(S, iolist_to_binary(Status), Headers, Body, RD);
send_reply(S, Status, Headers, {stream, Body}, #wm_reqdata{wsdata=CowboyReq}=RD) ->
    erase(bytes_written),
    Streamer = fun(IoFun) ->
                       F = fun({<<>>, done}, Len, _Fn) ->
                                   put(bytes_written, Len);
                              ({[], done}, Len, _Fn) ->
                                   put(bytes_written, Len);
                              ({Data, done}, Len, _Fn) ->
                                   IoFun(Data),
                                   put(bytes_written, Len+iolist_size(Data));
                              ({Data, Next}, Len, Fn) ->
                                   case iolist_size(Data) of
                                       0 ->
                                           ok;
                                       _ ->
                                           IoFun(Data)
                                   end,
                                   Fn(Next(), Len+iolist_size(Data), Fn)
                           end,
                       F(Body, 0, F)
               end,
    Stream = {chunked, Streamer},
    send_reply(S, Status, Headers, Stream, CowboyReq, RD);
send_reply(S, Status, Headers, {known_length_stream, Length, Body}, RD) ->
    Streamer = fun(Socket, Transport) ->
                       F = fun({Data, done}, _Fn) ->
                                   ok = Transport:send(Socket, Data);
                              ({Data, Next}, Fn) ->
                                   ok = Transport:send(Socket, Data),
                                   Fn(Next(), Fn)
                           end,
                       F(Body, F)
               end,
    Stream = {Length, Streamer},
    #wm_reqdata{wsdata=CowboyReq} = RD,
    send_reply(S, Status, Headers, Stream, CowboyReq, RD);
send_reply(S, Status, Headers, {writer, Body}, RD) ->
    put(bytes_written, 0),
    Streamer = fun(IoFun) ->
                       F = fun({Encoder, Charsetter, BodyFun}) ->
                                   W = fun(Data) ->
                                               case iolist_size(Data) of
                                                   0 -> ok;
                                                   _ ->
                                                       Sz = get(bytes_written),
                                                       Dsz = iolist_size(Data),
                                                       put(bytes_written, Sz+Dsz),
                                                       IoFun(Encoder(Charsetter(Data)))
                                               end
                                       end,
                                   BodyFun(W)
                           end,
                       F(Body)
               end,
    Stream = {chunked, Streamer},
    #wm_reqdata{wsdata=CowboyReq} = RD,
    send_reply(S, Status, Headers, Stream, CowboyReq, RD);
send_reply(S, Status, Headers, Body, #wm_reqdata{wsdata=CowboyReq}=RD) ->
    send_reply(S, Status, Headers, Body, CowboyReq, RD).
send_reply(_Socket, Status, Headers, Body, CowboyReq, RD) ->
    {ok, CReq} = cowboy_req:reply(Status, headers_from_list(Headers), Body, CowboyReq),
    put(wsdata, CReq),
    {ok, wrq:set_wsdata(CReq, RD)}.

recv_body(S, #wm_reqdata{wsdata=CowboyReq}=RD) ->
    recv_body(S, RD, cowboy_req:has_body(CowboyReq)).
recv_body(_S, RD, false) ->
    {{error, badarg}, RD};
recv_body(_S, #wm_reqdata{wsdata=CowboyReq, max_recv_body=MaxRecv}=RD, true) ->
    {Recv, CReq1} = case cowboy_req:body_length(CowboyReq) of
                        {undefined, C1} ->
                            {fun cowboy_req:stream_body/2, C1};
                        {_, C1} ->
                            {fun cowboy_req:body/2, C1}
                    end,
    case Recv(MaxRecv, CReq1) of
        {ok, Bin, CReq2} ->
            {{ok, Bin}, wrq:set_wsdata(CReq2, RD)};
        {error, Reason, CReq2} ->
            {{error, Reason}, wrq:set_wsdata(CReq2, RD)}
    end.

recv_stream_body(S, MaxHunk, #wm_reqdata{wsdata=CowboyReq}=RD) ->
    recv_stream_body(S, MaxHunk, RD, cowboy_req:has_body(CowboyReq)).
recv_stream_body(_S, _MaxHunk, RD, false) ->
    {{<<>>, done}, RD};
recv_stream_body(S, MaxHunk, #wm_reqdata{wsdata=CowboyReq}=RD, true) ->
    case cowboy_req:stream_body(MaxHunk, CowboyReq) of
        {ok, Data, CReq} ->
            NRD = wrq:set_wsdata(CReq, RD),
            put(wsdata, CReq),
            Next = fun() ->
                           RD2 = wrq:set_wsdata(get(wsdata), NRD),
                           {Res, RD3} = recv_stream_body(S, MaxHunk, RD2),
                           put(wsdata, wrq:wsdata(RD3)),
                           Res
                   end,
            {{Data, Next}, NRD};
        {done, CReq} ->
            {{<<>>, done}, wrq:set_wsdata(CReq, RD)};
        {error, Error} ->
            {{error, Error}, RD}
    end.

make_reqdata(Path) ->
    %% Helper function to construct a request and return the ReqData
    %% object. Used only for testing.
    CowboyReq = cowboy_req:new(undefined, cowboy_tcp_transport, undefined, <<"GET">>, list_to_binary(Path),
                               undefined, {1,1}, [], undefined, 0, undefined, false, false, undefined),
    Req = webmachine:new_request(cowboy, {CowboyReq, http}),
    {RD, _} = Req:get_reqdata(),
    RD.

send(_Socket, _Data) -> error({error, enotsup}).
recv(_Socket, _Length, _Timeout) -> error({error, enotsup}).
setopts(_Socket, _Opts) -> error({error, enotsup}).

%% internal functions
convert_options([], Conf) ->
    Conf;
convert_options([{ip, IpAddr0}|Opts], Conf) ->
    {ok, IpAddr} = inet_parse:address(IpAddr0),
    convert_options(Opts, [{ip, IpAddr}|Conf]);
convert_options([{port, Port}|Opts], Conf) ->
    convert_options(Opts, [{port, Port}|Conf]);
convert_options([_|Opts], Conf) ->
    convert_options(Opts, Conf).

to_binary(H) ->
    if
        is_atom(H) -> list_to_binary(string:to_lower(atom_to_list(H)));
        is_binary(H) -> H;
        is_list(H) -> list_to_binary(string:to_lower(H))
    end.

to_binary_preserve_case(V) ->
    if
        is_atom(V) -> list_to_binary(atom_to_list(V));
        is_binary(V) -> V;
        is_list(V) -> list_to_binary(V)
    end.

-endif. %% WEBMACHINE_COWBOY
