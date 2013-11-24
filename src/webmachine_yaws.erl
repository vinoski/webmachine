%% @author Steve Vinoski <vinoski@ieee.org>
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

%% @doc Yaws interface for webmachine.
-module(webmachine_yaws).
-author('Steve Vinoski <vinoski@ieee.org>').

-ifdef(WEBMACHINE_YAWS).
-behaviour(webmachine_server).
-export([start/1, stop/1, dispatch/1, get_req_info/2]).
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

-include_lib("yaws/include/yaws_api.hrl").
-include_lib("yaws/include/yaws.hrl").
-include("wm_reqdata.hrl").

start(Options0) ->
    {_PName, DGroup, Options} = webmachine_ws:start(Options0, ?MODULE),
    SConf0 = [{dispatchmod, ?MODULE}, {opaque, [{wmname, DGroup}]}],
    {SConf, GConf} = convert_options(Options, SConf0, []),
    DefaultDocroot = "priv/www",
    Docroot = case filelib:is_dir(DefaultDocroot) of
                  true -> DefaultDocroot;
                  false -> "."
              end,
    ok = yaws:start_embedded(Docroot, SConf, GConf, DGroup),
    LoadedInfo = proplists:get_value(loaded, application_controller:info()),
    {yaws, _, Version} = lists:keyfind(yaws, 1, LoadedInfo),
    application:set_env(webmachine, server_version, "Yaws/" ++ Version),
    {ok, whereis(yaws_server)}.

stop(_Name) ->
    %% TODO: stop only the named server
    yaws:stop().

dispatch(Arg) ->
    erase(yaws_read_body),
    erase(yaws_close_socket),
    Req = webmachine:new_request(yaws, Arg),
    {wmname, Name} = lists:keyfind(wmname, 1, Arg#arg.opaque),
    webmachine_ws:dispatch_request(Name, Req),
    case get(yaws_close_socket) of
        true ->
            do_close(Arg#arg.clisock),
            closed;
        false ->
            case get(yaws_read_body) of
                true ->
                    done;
                undefined ->
                    case req_has_body(Arg) of
                        true ->
                            do_close(Arg#arg.clisock),
                            closed;
                        false ->
                            done
                    end
            end
    end.

get_req_info(Want, Arg) ->
    get_req_info(Want, Arg, []).
get_req_info([socket|T], #arg{clisock=Socket}=Arg, Acc) ->
    get_req_info(T, Arg, [{socket, Socket}|Acc]);
get_req_info([method|T], #arg{req=Req}=Arg, Acc) ->
    Method = Req#http_request.method,
    get_req_info(T, Arg, [{method, Method}|Acc]);
get_req_info([scheme|T], Arg, Acc) ->
    Uri = yaws_api:request_url(Arg),
    Scheme = case Uri#url.scheme of
                 "http" -> http;
                 "https" -> https
             end,
    get_req_info(T, Arg, [{scheme, Scheme}|Acc]);
get_req_info([path|T], #arg{req=Req}=Arg, Acc) ->
    {abs_path, Path} = Req#http_request.path,
    get_req_info(T, Arg, [{path, Path}|Acc]);
get_req_info([version|T], #arg{req=Req}=Arg, Acc) ->
    Version = Req#http_request.version,
    get_req_info(T, Arg, [{version, Version}|Acc]);
get_req_info([headers|T], #arg{headers=Headers0}=Arg, Acc) ->
    Headers = yaws_api:reformat_header(Headers0, fun header_formatter/2),
    get_req_info(T, Arg, [{headers, Headers}|Acc]);
get_req_info([], _Arg, Acc) ->
    lists:reverse(Acc).

convert_options([], SConf, GConf) ->
    {SConf, GConf};
convert_options([{backlog, Backlog}|Opts], SConf, GConf) ->
    convert_options(Opts, [{listen_backlog, Backlog}|SConf], GConf);
convert_options([{log_dir, LogDir}|Opts], SConf, GConf) ->
    convert_options(Opts, SConf, [{logdir, LogDir}|GConf]);
convert_options([{ip, IpAddr0}|Opts], SConf, GConf) ->
    {ok, IpAddr} = inet_parse:address(IpAddr0),
    convert_options(Opts, [{listen, IpAddr}|SConf], GConf);
convert_options([{port, Port}|Opts], SConf, GConf) ->
    convert_options(Opts, [{port, Port}|SConf], GConf);
convert_options([_|Opts], SConf, GConf) ->
    convert_options(Opts, SConf, GConf).

get_header_value(HeaderName, Headers) when is_list(Headers) ->
    get_header_value(HeaderName, headers_from_list(Headers));
get_header_value(HeaderName, Headers) ->
    yaws_api:get_header(Headers, HeaderName).

new_headers() ->
    #headers{}.

make_headers(Headers) when is_list(Headers) ->
    headers_from_list(Headers);
make_headers(Headers) ->
    Headers.

add_header(Header, Value, Headers) ->
    yaws_api:set_header(Headers, Header, Value).

merge_header(Header, Value, Headers) ->
    yaws_api:merge_header(Headers, Header, Value).

header_formatter(H, V) when is_atom(H) ->
    header_formatter(atom_to_list(H), V);
header_formatter(H, {multi, Vals}) ->
    [{H, V} || V <- Vals];
header_formatter(H, V) ->
    {H, V}.

headers_to_list(Headers) when is_list(Headers) ->
    Headers;
headers_to_list(Headers) ->
    Formatted = yaws_api:reformat_header(Headers, fun header_formatter/2),
    lists:foldr(fun({_,_}=HV, Acc) ->
                        [HV|Acc];
                   (HVList, Acc) when is_list(HVList) ->
                        lists:foldl(fun(HV, Acc2) -> [HV|Acc2] end, Acc, HVList)
                end, [], Formatted).

headers_from_list(Headers) ->
    lists:foldl(fun({Hdr,Val}, Hdrs) ->
                        yaws_api:set_header(Hdrs, Hdr, Val);
                   (HdrStr, Hdrs) ->
                        {ok, {http_header, _, Hdr, _, Val}, _} =
                            erlang:decode_packet(
                              httph_bin,
                              list_to_binary([HdrStr, <<"\r\n\r\n">>]),
                              []),
                        yaws_api:set_header(Hdrs, Hdr, Val)
                end, #headers{}, Headers).

get_listen_port(_Server) ->
    {ok, _GC, [[SC]]} = yaws_api:getconf(),
    yaws_api:get_listen_port(SC).

send_reply(Socket, Status, Headers, Body0, #wm_reqdata{wsdata=Arg}=RD) ->
    YawsReq = Arg#arg.req,
    Vsn = YawsReq#http_request.version,
    ok = yaws:gen_tcp_send(Socket,
                           [webmachine_server:make_version(Vsn),
                            Status, <<"\r\n">>,
                            [[H, <<": ">>, V, <<"\r\n">>] || {H,V} <- Headers],
                            <<"\r\n">>]),
    case YawsReq#http_request.method of
        'HEAD' ->
            ok;
        _ ->
            WSMod = wrq:wsmod(RD),
            case Body0 of
                {stream, Body} ->
                    Len = webmachine_server:send_stream_body(Socket, Body, WSMod),
                    put(bytes_written, Len);
                {known_length_stream, _Length, Body} ->
                    ok = webmachine_server:send_stream_body_no_chunk(Socket, Body,
                                                                     WSMod);
                {writer, Body} ->
                    ok = webmachine_server:send_writer_body(Socket, Body, WSMod);
                <<>> ->
                    ok;
                _ ->
                    ok = send(Socket, Body0)
            end
    end,
    check_for_close(Arg, Headers),
    {ok, RD}.

recv_body(Socket, RD) ->
    put(yaws_read_body, true),
    MRH = RD#wm_reqdata.max_recv_hunk,
    MRB = RD#wm_reqdata.max_recv_body,
    Data = webmachine_server:read_whole_stream(
             webmachine_server:recv_str_body(Socket, MRH, RD),
             [], MRB, 0),
    {{ok, Data}, RD}.

recv_stream_body(Socket, MaxHunk, RD) ->
    put(yaws_read_body, true),
    {webmachine_server:recv_str_body(Socket, MaxHunk, RD), RD}.

make_reqdata(Path) ->
    %% Helper function to construct a request and return the ReqData
    %% object. Used only for testing.
    Arg = #arg{clisock=testing,
               headers=new_headers(),
               req=#http_request{method='GET', path={abs_path,Path}, version={1,1}},
               docroot="/tmp"},
    put(sc, #sconf{}),
    Req = webmachine:new_request(yaws, Arg),
    {RD, _} = Req:get_reqdata(),
    RD.

send(Socket, Data) ->
    yaws:gen_tcp_send(Socket, Data).

recv(Socket, Length, Timeout) ->
    SockType = case yaws_api:get_sslsocket(Socket) of
                   undefined -> nossl;
                   {ok, _} -> ssl
               end,
    yaws:do_recv(Socket, Length, SockType, Timeout).

setopts(Socket, Opts) ->
    SockType = case yaws_api:get_sslsocket(Socket) of
                   undefined -> nossl;
                   {ok, _} -> ssl
               end,
    yaws:setopts(Socket, Opts, SockType).

check_for_close(Arg, RespHeaders) ->
    Vsn = (Arg#arg.req)#http_request.version,
    case header_to_lower(connection, Arg#arg.headers) of
        "close" ->
            put(yaws_close_socket, true);
        "keep-alive" ->
            put(yaws_close_socket, Vsn < {1,0});
        _ ->
            case Vsn of
                {1,1} ->
                    case header_to_lower(connection, RespHeaders) of
                        "close" ->
                            put(yaws_close_socket, true);
                        _ ->
                            put(yaws_close_socket, false)
                    end;
                _ ->
                    put(yaws_close_socket, true)
            end
    end.

header_to_lower(Hdr, Hdrs) ->
    case get_header_value(Hdr, Hdrs) of
        undefined ->
            undefined;
        Val ->
            string:to_lower(if
                                is_list(Val) ->
                                    Val;
                                is_binary(Val) ->
                                    binary_to_list(Val)
                            end)
    end.

do_close(Socket) ->
    case yaws_api:get_sslsocket(Socket) of
        undefined -> gen_tcp:close(Socket);
        {ok, SslSocket} -> ssl:close(SslSocket)
    end.

req_has_body(#arg{headers=Hdrs}) ->
    Size = get_header_value(content_length, Hdrs),
    case Size of
        undefined ->
            case header_to_lower(transfer_encoding, Hdrs) of
                "chunked" ->
                    true;
                _ ->
                    false
            end;
        "0" ->
            false;
        _ ->
            true
    end.

-endif. %% WEBMACHINE_YAWS
