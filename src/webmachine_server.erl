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

%% @doc Behaviour for webmachine web servers.
-module(webmachine_server).
-author('Steve Vinoski <vinoski@ieee.org>').
-export([send_stream_body/3,
         send_stream_body_no_chunk/3,
         send_writer_body/3,
         read_whole_stream/4,
         recv_str_body/3,
         make_version/1]).

-include("wm_reqdata.hrl").

-define(IDLE_TIMEOUT, infinity).

-type options() :: [{atom(), term()}].
-type header_name() :: atom() | string() | binary().
-type header_value() :: atom() | string() | binary().
-type header() :: {header_name(), header_value()}.
-type headers() :: term().
-type header_list() :: [{header_name(), header_value()}].
-type path() :: string() | binary().
-type ws_data() :: term().
-type socket() :: term().

-export_type([options/0, header_name/0, header_value/0, header/0, headers/0,
              path/0, ws_data/0]).

-callback start(Options::options()) ->
    {ok, pid()} | {error, term()}.

-callback stop(Name::atom()) ->
    ok | {error, term()}.

-callback get_header_value(HdrName::header_name(), Headers::headers()) ->
    header_value() | undefined.

-callback new_headers() ->
    headers().

-callback make_headers(Headers::headers()) ->
    headers().

-callback add_header(HdrName::header_name(), Value::header_value(),
                     Headers::headers()) ->
    headers().

-callback headers_to_list(Headers::headers()) ->
    header_list().

-callback headers_from_list(Headers::header_list()) ->
    headers().

-callback get_listen_port(Server::pid()) ->
    inet:port_number().

-callback send_reply(Socket::socket(), Status::non_neg_integer(),
                     Headers::headers(), Body::term(), RD::#wm_reqdata{}) ->
    {ok | {error, term()}, #wm_reqdata{}}.

-callback recv_body(Socket::socket(), RD::#wm_reqdata{}) ->
    {{ok, binary()} | {error, term()}, #wm_reqdata{}}.

-callback recv_stream_body(Socket::socket(), MaxHunk::non_neg_integer(),
                           RD::#wm_reqdata{}) ->
    {{ok, done | binary()} | {error, term()}, #wm_reqdata{}}.

%% Helper function to construct a request and return the ReqData
%% object. Used only for testing.
-callback make_reqdata(Path::path()) ->
    #wm_reqdata{}.

%% These three callbacks are "optional" in the sense that they're not
%% called unless the web server callback module uses the export helper
%% functions below.
-callback send(Socket::socket(), Data::iolist()) ->
    ok | {error, term()}.

-callback recv(Socket::socket(), Length::non_neg_integer(), timeout()) ->
    {ok, iolist()} | {error, term()}.

-callback setopts(Socket::socket(), Opts::inet:socket_setopts()) ->
    ok | {error, term()}.

%% Helper functions for web servers
send_stream_body(Socket, Body, WSMod) ->
    send_stream_body(Socket, Body, 0, WSMod).
send_stream_body(Socket, {<<>>, done}, SoFar, WSMod) ->
    send_chunk(Socket, <<>>, WSMod),
    SoFar;
send_stream_body(Socket, {Data, done}, SoFar, WSMod) ->
    Size = send_chunk(Socket, Data, WSMod),
    send_chunk(Socket, <<>>, WSMod),
    Size + SoFar;
send_stream_body(Socket, {<<>>, Next}, SoFar, WSMod) ->
    send_stream_body(Socket, Next(), SoFar, WSMod);
send_stream_body(Socket, {[], Next}, SoFar, WSMod) ->
    send_stream_body(Socket, Next(), SoFar, WSMod);
send_stream_body(Socket, {Data, Next}, SoFar, WSMod) ->
    Size = send_chunk(Socket, Data, WSMod),
    send_stream_body(Socket, Next(), Size+SoFar, WSMod).

send_chunk(Socket, Data, WSMod) ->
    Size = iolist_size(Data),
    Chunk = [mochihex:to_hex(Size), <<"\r\n">>, Data, <<"\r\n">>],
    ok = WSMod:send(Socket, Chunk),
    Size.

send_stream_body_no_chunk(Socket, {Data, done}, WSMod) ->
    ok = WSMod:send(Socket, Data);
send_stream_body_no_chunk(Socket, {Data, Next}, WSMod) ->
    ok = WSMod:send(Socket, Data),
    send_stream_body_no_chunk(Socket, Next(), WSMod).

send_writer_body(Socket, {Encoder, Charsetter, BodyFun}, WSMod) ->
    put(bytes_written, 0),
    Writer = fun(Data) ->
        Size = send_chunk(Socket, Encoder(Charsetter(Data)), WSMod),
        put(bytes_written, get(bytes_written)+Size),
        Size
    end,
    BodyFun(Writer),
    0 = send_chunk(Socket, <<>>, WSMod),
    ok.

read_whole_stream({Hunk,_}, _, MaxRecvBody, SizeAcc)
  when SizeAcc + byte_size(Hunk) > MaxRecvBody ->
    {error, req_body_too_large};
read_whole_stream({Hunk,Next}, Acc0, MaxRecvBody, SizeAcc) ->
    HunkSize = byte_size(Hunk),
    Acc = [Hunk|Acc0],
    case Next of
        done -> iolist_to_binary(lists:reverse(Acc));
        _ -> read_whole_stream(Next(), Acc,
                               MaxRecvBody, SizeAcc + HunkSize)
    end.

recv_str_body(Socket, MaxHunkSize, #wm_reqdata{wsmod=WSMod}=RD) ->
    put(mochiweb_request_recv, true),
    Hdrs = wrq:req_headers(RD),
    case WSMod:get_header_value("expect", Hdrs) of
        "100-continue" ->
            WSMod:send(Socket,
                       [make_version(wrq:version(RD)),
                        webmachine_request:make_code(100), <<"\r\n\r\n">>]);
        _Else ->
            ok
    end,
    case body_length(Hdrs, WSMod) of
        {unknown_transfer_encoding, X} -> exit({unknown_transfer_encoding, X});
        undefined -> {<<>>, done};
        0 -> {<<>>, done};
        chunked -> recv_chunked_body(Socket, MaxHunkSize, WSMod);
        Length -> recv_unchunked_body(Socket, MaxHunkSize, Length, WSMod)
    end.

%% @doc  Infer body length from transfer-encoding and content-length headers.
body_length(Headers, WSMod) ->
    case WSMod:get_header_value("transfer-encoding", Headers) of
        undefined ->
            case WSMod:get_header_value("content-length", Headers) of
                undefined -> undefined;
                Length -> list_to_integer(Length)
            end;
        "chunked" -> chunked;
        Unknown -> {unknown_transfer_encoding, Unknown}
    end.

recv_unchunked_body(Socket, MaxHunk, DataLeft, WSMod) ->
    case MaxHunk >= DataLeft of
        true ->
            {ok,Data1} = WSMod:recv(Socket,DataLeft,?IDLE_TIMEOUT),
            {Data1, done};
        false ->
            {ok,Data2} = WSMod:recv(Socket,MaxHunk,?IDLE_TIMEOUT),
            {Data2,
             fun() -> recv_unchunked_body(Socket, MaxHunk,
                                          DataLeft-MaxHunk, WSMod)
             end}
    end.

recv_chunked_body(Socket, MaxHunk, WSMod) ->
    case read_chunk_length(Socket, false, WSMod) of
        0 -> {<<>>, done};
        ChunkLength -> recv_chunked_body(Socket,MaxHunk,ChunkLength,WSMod)
    end.
recv_chunked_body(Socket, MaxHunk, LeftInChunk, WSMod) ->
    case MaxHunk >= LeftInChunk of
        true ->
            {ok,Data1} = WSMod:recv(Socket,LeftInChunk,?IDLE_TIMEOUT),
            {Data1,
             fun() -> recv_chunked_body(Socket, MaxHunk, WSMod) end};
        false ->
            {ok,Data2} = WSMod:recv(Socket,MaxHunk,?IDLE_TIMEOUT),
            {Data2,
             fun() -> recv_chunked_body(Socket, MaxHunk,
                                        LeftInChunk-MaxHunk, WSMod)
             end}
    end.

read_chunk_length(Socket, MaybeLastChunk, WSMod) ->
    ok = WSMod:setopts(Socket, [{packet, line}]),
    case WSMod:recv(Socket, 0, ?IDLE_TIMEOUT) of
        {ok, Header} ->
            ok = WSMod:setopts(Socket, [{packet, raw}]),
            Splitter = fun (C) ->
                               C =/= $\r andalso C =/= $\n andalso C =/= $
                                   andalso C =/= 59 % semicolon
                       end,
            {Hex, _Rest} = lists:splitwith(Splitter, binary_to_list(Header)),
            case Hex of
                [] ->
                    %% skip the \r\n at the end of a chunk, or
                    %% allow [badly formed] last chunk header to be
                    %% empty instead of '0' explicitly
                    if MaybeLastChunk -> 0;
                       true -> read_chunk_length(Socket, true, WSMod)
                    end;
                _ ->
                    erlang:list_to_integer(Hex, 16)
            end;
        _ ->
            exit(normal)
    end.

make_version({1, 0}) ->
    <<"HTTP/1.0 ">>;
make_version(_) ->
    <<"HTTP/1.1 ">>.
