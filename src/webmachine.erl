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

-module(webmachine).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').
-export([start/0, stop/0]).
-export([new_request/2]).

-include("webmachine_logger.hrl").
-include("wm_reqstate.hrl").
-include("wm_reqdata.hrl").

%% @spec start() -> ok
%% @doc Start the webmachine server.
start() ->
    webmachine_deps:ensure(),
    application:start(crypto),
    application:start(webmachine).

%% @spec stop() -> ok
%% @doc Stop the webmachine server.
stop() ->
    application:stop(webmachine).

new_request(mochiweb, Request) ->
    Method = Request:get(method),
    Scheme = Request:get(scheme),
    Version = Request:get(version),
    Socket = Request:get(socket),
    RawPath = Request:get(raw_path),
    Headers = Request:get(headers),
    new_request_common(Socket, Method, Scheme, RawPath, Version, Headers, webmachine_mochiweb, undefined);

new_request(yaws, Data) ->
    Props = [socket, method, scheme, path, version, headers],
    PList = webmachine_yaws:get_req_info(Props, Data),
    {_, [Socket, Method, Scheme, RawPath, Version, Headers]} = lists:unzip(PList),
    new_request_common(Socket, Method, Scheme, RawPath, Version, Headers, webmachine_yaws, Data);

new_request(cowboy, {CowboyReq, Scheme}) ->
    {Method0, Req1} = cowboy_req:method(CowboyReq),
    Method = list_to_existing_atom(binary_to_list(Method0)),
    {Path, Req2} = cowboy_req:path(Req1),
    {Version, Req3} = case cowboy_req:version(Req2) of
                          {Vsn, R3} when is_atom(Vsn) ->
                              [_, Major, Minor] = string:tokens(atom_to_list(Vsn), "/."),
                              {{list_to_integer(Major), list_to_integer(Minor)}, R3};
                          Else ->
                              Else
                      end,
    {Headers, Req4} = cowboy_req:headers(Req3),
    new_request_common(undefined, Method, Scheme, binary_to_list(Path), Version, Headers,
                       webmachine_cowboy, Req4).


new_request_common(Socket, Method, Scheme, RawPath0, Version, Headers0, WSMod, WSData) ->
    {Headers, RawPath} = case application:get_env(webmachine, rewrite_module) of
                             {ok, RewriteMod} ->
                                 do_rewrite(RewriteMod,
                                            Method,
                                            Scheme,
                                            Version,
                                            Headers0,
                                            RawPath0);
                             undefined ->
                                 {Headers0, RawPath0}
                         end,
    InitState = #wm_reqstate{socket=Socket,
                             reqdata=wrq:create(Method,Scheme,Version,RawPath,Headers,WSMod,WSData)},
    {ReqState, Peer, Sock} =
        case Socket of
            Socket when is_port(Socket) ->
                InitReq = {webmachine_request,InitState},
                {Peer0, _ReqState} = InitReq:get_peer(),
                {Sock0, RS} = InitReq:get_sock(),
                RD = wrq:set_sock(Sock0, wrq:set_peer(Peer0, RS#wm_reqstate.reqdata)),
                {RS#wm_reqstate{reqdata=RD}, Peer0, Sock0};
            _ ->
                {InitState, undefined, Socket}
        end,
    LogData = #wm_log_data{start_time=now(),
                           method=Method,
                           headers=Headers,
                           peer=Peer,
                           sock=Sock,
                           path=RawPath,
                           version=Version,
                           response_code=404,
                           response_length=0},
    webmachine_request:new(ReqState#wm_reqstate{log_data=LogData}).

do_rewrite(RewriteMod, Method, Scheme, Version, Headers, RawPath) ->
    case RewriteMod:rewrite(Method, Scheme, Version, Headers, RawPath) of
        %% only raw path has been rewritten (older style rewriting)
        NewPath when is_list(NewPath) ->
            {Headers, NewPath};
        %% headers and raw path rewritten (new style rewriting)
        {NewHeaders, NewPath} ->
            {NewHeaders,NewPath}
    end.

%%
%% TEST
%%
-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

start_stop_test() ->
    start_apps([inets, crypto, mochiweb]),
    WSstr = os:getenv("WEBMACHINE_SERVER"),
    {WS, Deps} = case WSstr of
                     false ->
                         {false,[]};
                     _ ->
                         Nm = list_to_atom(WSstr),
                         case Nm of
                             mochiweb ->
                                 {false,[]};
                             yaws ->
                                 ok = start_apps([Nm]),
                                 {Nm,[]};
                             cowboy ->
                                 ok = start_apps([ranch, cowboy]),
                                 {Nm,[ranch]}
                         end
                 end,
    ?assertEqual(ok, webmachine:start()),
    ?assertEqual(ok, webmachine:stop()),
    case WS of
        false ->
            ok;
        _ ->
            ok = application:stop(WS),
            lists:map(fun(Dep) ->
                              ok = application:stop(Dep)
                      end, Deps)
    end,
    ok = application:stop(mochiweb),
    ok = application:stop(crypto),
    ok = application:stop(inets),
    ok.

start_apps([App|Rest]=AppList) ->
    Apps = application:which_applications(),
    case lists:keymember(App,1,Apps) of
        true ->
            application:stop(App),
            timer:sleep(100),
            start_apps(AppList);
        false ->
            ok
    end,
    application:start(App),
    start_apps(Rest);
start_apps([]) ->
    ok.

-endif.
