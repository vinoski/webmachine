%% @author Justin Sheehy <justin@basho.com>
%% @author Andy Gross <andy@basho.com>
%% @copyright 2007-2013 Basho Technologies
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

%% @doc Mochiweb interface for webmachine.
-module(webmachine_mochiweb).
-behaviour(webmachine_server).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-author('Steve Vinoski <vinoski@ieee.org>').
-export([start/1, stop/1, loop/2]).
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
    Name = list_to_atom(to_list(PName) ++ "_mochiweb"),
    LoopFun = fun(X) -> loop(DGroup, X) end,
    LoadRes = application:load(mochiweb),
    true = (LoadRes =:= ok orelse LoadRes =:= {error,{already_loaded,mochiweb}}),
    {ok,_} = Res = mochiweb_http:start([{name, Name}, {loop, LoopFun} | Options]),
    LoadedInfo = proplists:get_value(loaded, application_controller:info()),
    {mochiweb, _, Version} = lists:keyfind(mochiweb, 1, LoadedInfo),
    application:set_env(webmachine, server_version, "MochiWeb/" ++ Version),
    Res.

stop(Name) ->
    mochiweb_http:stop(Name).

loop(Name, MochiReq) ->
    Req = webmachine:new_request(mochiweb, MochiReq),
    webmachine_ws:dispatch_request(Name, Req).

get_header_value(HeaderName, Headers) ->
    mochiweb_headers:get_value(HeaderName, Headers).

new_headers() ->
    mochiweb_headers:empty().

make_headers(Headers) ->
    mochiweb_headers:make(Headers).

add_header(Header, Value, Headers) ->
    mochiweb_headers:enter(Header, Value, Headers).

merge_header(Header, Value, Headers) ->
    mochiweb_headers:insert(Header, Value, Headers).

headers_to_list(Headers) when is_list(Headers) ->
    Headers;
headers_to_list(Headers) ->
    mochiweb_headers:to_list(Headers).

headers_from_list(Headers) when not is_list(Headers) ->
    Headers;
headers_from_list(Headers) ->
    mochiweb_headers:from_list(Headers).

get_listen_port(Server) ->
    mochiweb_socket_server:get(Server, port).

send_reply(Socket, Status, Headers, Body0, #wm_reqdata{wsmod=WSMod}=RD) ->
    ok = send(Socket, [webmachine_server:make_version(wrq:version(RD)),
                       Status, <<"\r\n">> | headers_to_data(Headers)]),
    case wrq:method(RD) of
        'HEAD' ->
            ok;
        _ ->
            case Body0 of
                {stream, Body} ->
                    Len = webmachine_server:send_stream_body(Socket, Body, WSMod),
                    put(bytes_written, Len);
                {known_length_stream, _Length, Body} ->
                    ok = webmachine_server:send_stream_body_no_chunk(Socket, Body,
                                                                     WSMod);
                {writer, Body} ->
                    ok = webmachine_server:send_writer_body(Socket, Body, WSMod);
                _ ->
                    ok = send(Socket, Body0)
            end
    end,
    {ok, RD}.

recv_body(Socket, RD) ->
    MRH = RD#wm_reqdata.max_recv_hunk,
    MRB = RD#wm_reqdata.max_recv_body,
    Data = webmachine_server:read_whole_stream(
             webmachine_server:recv_str_body(Socket, MRH, RD),
             [], MRB, 0),
    {{ok, Data}, RD}.

recv_stream_body(Socket, MaxHunk, RD) ->
    {webmachine_server:recv_str_body(Socket, MaxHunk, RD), RD}.

make_reqdata(Path) ->
    %% Helper function to construct a request and return the ReqData
    %% object. Used only for testing.
    MochiReq = mochiweb_request:new(testing, 'GET', Path, {1, 1},
                                    mochiweb_headers:make([])),
    Req = webmachine:new_request(mochiweb, MochiReq),
    {RD, _} = Req:get_reqdata(),
    RD.

%% internal functions
send(Socket, Data) ->
    case mochiweb_socket:send(Socket, Data) of
        ok -> ok;
        {error,closed} -> ok;
        _ -> exit(normal)
    end.

recv(Socket, Length, Timeout) ->
    mochiweb_socket:recv(Socket, Length, Timeout).

setopts(Socket, Opts) ->
    mochiweb_socket:setopts(Socket, Opts).

to_list(L) when is_list(L) ->
    L;
to_list(A) when is_atom(A) ->
    atom_to_list(A).

headers_to_data(Hdrs) ->
    F = fun({K, V}, Acc) ->
                [mochiweb_util:make_io(K), <<": ">>, V, <<"\r\n">> | Acc]
        end,
    lists:foldl(F, [<<"\r\n">>], headers_to_list(Hdrs)).
