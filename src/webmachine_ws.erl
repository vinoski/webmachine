%% @author Steve Vinoski <vinoski@ieee.org>
%% @copyright 2012 Basho Technologies
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

%% @doc General web server utilities for webmachine.
-module(webmachine_ws).
-author('Steve Vinoski <vinoski@ieee.org>').

-export([start/1, start/2, dispatch_request/2, get_webserver_mod/0]).

%% The `log_dir' option is deprecated, but remove it from the
%% options list if it is present
-define(WM_OPTIONS, [error_handler,
                     log_dir,
                     rewrite_module,
                     resource_module_option]).

-define (WM_OPTION_DEFAULTS, [{error_handler, webmachine_error_handler}]).

start(Options) ->
    WSMod = get_webserver_mod(),
    WSMod:start(Options).

start(Options, _WSMod) ->
    {DispatchList, PName, DGroup, WMOptions, OtherOptions} = get_wm_options(Options),
    webmachine_router:init_routes(DGroup, DispatchList),
    [application_set_unless_env_or_undef(K, V) || {K, V} <- WMOptions],
    {PName, DGroup, OtherOptions}.

dispatch_request(Name, Req) ->
    DispatchList = webmachine_router:get_routes(Name),
    Host = case host_headers(Req) of
               [H|_] -> H;
               [] -> []
           end,
    {Path, _} = Req:path(),
    {RD, _} = Req:get_reqdata(),

    %% Run the dispatch code, catch any errors...
    try webmachine_dispatcher:dispatch(Host, Path, DispatchList, RD) of
        {error, invalid_host} ->
            handle_error(400, "Invalid Host", Req);
        {no_dispatch_match, _UnmatchedHost, _UnmatchedPathTokens} ->
            handle_error(404, {none, none, []}, Req);
        {Mod, ModOpts, HostTokens, Port, PathTokens, Bindings,
         AppRoot, StringPath} ->
            BootstrapResource = webmachine_resource:new(x,x,x,x),
            {ok,RS1} = Req:load_dispatch_data(Bindings,HostTokens,Port,
                                              PathTokens,AppRoot,StringPath),
            XReq1 = {webmachine_request,RS1},
            try
                {ok, Resource} = BootstrapResource:wrap(Mod, ModOpts),
                {ok,RS2} = XReq1:set_metadata('resource_module',
                                              resource_module(Mod, ModOpts)),
                webmachine_decision_core:handle_request(Resource, RS2)
            catch
                error:Error ->
                    handle_error(500, {error, Error}, Req)
            end
    catch
        Type:Error ->
            handle_error(500, {Type, Error}, Req)
    end.

get_webserver_mod() ->
    case application:get_env(webmachine, webserver) of
        undefined ->
            WS = case os:getenv("WEBMACHINE_SERVER") of
                     false ->
                         mochiweb;
                     "mochiweb" ->
                         mochiweb;
                     "yaws" ->
                         yaws;
                     "cowboy" ->
                         cowboy
                 end,
            ok = application:set_env(webmachine, webserver, WS),
            get_webserver_mod();
        {ok, mochiweb} ->
            webmachine_mochiweb;
        {ok, yaws} ->
            webmachine_yaws;
        {ok, cowboy} ->
            webmachine_cowboy
    end.

handle_error(Code, Error, Req) ->
    {ok, ErrorHandler} = application:get_env(webmachine, error_handler),
    {ErrorHTML,ReqState1} =
        ErrorHandler:render_error(Code, Req, Error),
    Req1 = {webmachine_request,ReqState1},
    {ok,ReqState2} = Req1:append_to_response_body(ErrorHTML),
    Req2 = {webmachine_request,ReqState2},
    {ok,ReqState3} = Req2:send_response(Code),
    Req3 = {webmachine_request,ReqState3},
    {LogData,_ReqState4} = Req3:log_data(),
    spawn(webmachine_log, log_access, [LogData]).

get_wm_option(OptName, {WMOptions, OtherOptions}) ->
    {Value, UpdOtherOptions} =
        handle_get_option_result(get_option(OptName, OtherOptions), OptName),
    {[{OptName, Value} | WMOptions], UpdOtherOptions}.

handle_get_option_result({undefined, Options}, Name) ->
    {proplists:get_value(Name, ?WM_OPTION_DEFAULTS), Options};
handle_get_option_result(GetOptRes, _) ->
    GetOptRes.

get_wm_options(Options) ->
    {DispatchList, Options1} = get_option(dispatch, Options),
    {Name, Options2} =
        case get_option(name, Options1) of
            {undefined, Opts2} ->
                {webmachine, Opts2};
            NRes -> NRes
        end,
    {DGroup, Options3} =
        case get_option(dispatch_group, Options2) of
            {undefined, Opts3} ->
                {default, Opts3};
            RRes -> RRes
        end,
    {WMOptions, RestOptions} = lists:foldl(fun get_wm_option/2, {[], Options3}, ?WM_OPTIONS),
    {DispatchList, Name, DGroup, WMOptions, RestOptions}.

get_option(Option, Options) ->
    case lists:keytake(Option, 1, Options) of
        false -> {undefined, Options};
        {value, {Option, Value}, NewOptions} -> {Value, NewOptions}
    end.

application_set_unless_env_or_undef(_Var, undefined) ->
    ok;
application_set_unless_env_or_undef(Var, Value) ->
    application_set_unless_env(webmachine, Var, Value).

application_set_unless_env(App, Var, Value) ->
    Current = application:get_all_env(App),
    CurrentKeys = proplists:get_keys(Current),
    case lists:member(Var, CurrentKeys) of
        true ->
            ok;
        false ->
            application:set_env(App, Var, Value)
    end.

host_headers(Req) ->
    [ V || {V,_ReqState} <- [Req:get_header_value(H)
                             || H <- ["x-forwarded-host",
                                      "x-forwarded-server",
                                      "host"]],
           V /= undefined].

get_app_env(Key) ->
    application:get_env(webmachine, Key).

%% @private
%% @doc This function is used for cases where it may be desirable to
%% override the value that is set in the request metadata under the
%% `resource_module' key. An example would be a pattern where a set of
%% resource modules shares a lot of common functionality that is
%% contained in a single module and is used as the resource in all
%% dispatch rules and the `ModOpts' are used to specify a smaller
%% set of callbacks for resource specialization.
resource_module(Mod, ModOpts) ->
    resource_module(Mod, ModOpts, get_app_env(resource_module_option)).

resource_module(Mod, _, undefined) ->
    Mod;
resource_module(Mod, ModOpts, {ok, OptionVal}) ->
    proplists:get_value(OptionVal, ModOpts, Mod).
