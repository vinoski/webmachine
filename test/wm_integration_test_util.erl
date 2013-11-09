%% @author Macneil Shonle <mshonle@basho.com>
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

%% These utility functions can be used to set up Webmachine on an ephemeral
%% port that can be interacted with over HTTP requests. These utilities are
%% useful for writing integration tests, which test all of the Webmachine
%% stack, as a complement to the unit-testing and mocking strategies.
-module(wm_integration_test_util).

-ifdef(TEST).
-export([start/3, stop/1]).
-export([url/1, url/2]).

-export([init/1, service_available/2]).

-include("webmachine.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(integration_state, {
          webmachine_sup,
          web_serv,
          port,
          resource_name
         }).

%% Returns an integration_state record that should be passed to
%% stop/1. Starts up webmachine and the web server with the given name, ip,
%% and dispatch list. Communication is set up on an ephemeral port.
start(Name, IP, DispatchList) ->
    cleanup_previous_runs(),
    error_logger:tty(false),
    application:start(inets),
    {ok, WebmachineSup} = webmachine_sup:start_link(),
    WebConfig = [{name, Name}, {ip, IP}, {port, 0},
                 {dispatch, DispatchList}],
    {ok, WebServ} = webmachine_ws:start(WebConfig),
    link(WebServ),
    Port = webmachine_ws:get_listen_port(WebServ),
    #integration_state{webmachine_sup=WebmachineSup,
                       web_serv=WebServ,
                       port=Port,
                       resource_name=Name}.

%% Receives the integration_state record returned by start/3
stop(Context) ->
    #integration_state{web_serv=WebServ, webmachine_sup=Sup} = Context,
    {registered_name, Name} = process_info(WebServ, registered_name),
    unlink(WebServ),
    webmachine_ws:stop(Name),
    wait_for_pid(WebServ),
    unlink(Sup),
    stop_supervisor(Sup),
    application:stop(inets),
    wait_for_pid(inets_sup).

%% Returns a URL to use for an HTTP request to communicate with Webmachine.
url(#integration_state{port=Port, resource_name=Name}) ->
    Chars = io_lib:format("http://localhost:~b/~s", [Port, Name]),
    lists:flatten(Chars).

%% Returns a URL extended with the given path to use for an HTTP request to
%% communicate with Webmachine
url(Context, Path) ->
    url(Context) ++ "/" ++ Path.

stop_supervisor(Sup) ->
    case is_process_alive(Sup) of
        true ->
            exit(Sup, kill),
            wait_for_pid(Sup);
        false ->
            ok
    end.

%% Wait for a pid to exit -- Copied from riak_kv_test_util.erl
wait_for_pid(Nm) when is_atom(Nm) ->
    case whereis(Nm) of
        undefined -> ok;
        Pid -> wait_for_pid(Pid)
    end;
wait_for_pid(Pid) ->
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, _, _} ->
            ok
    after
        5000 ->
            {error, {didnotexit, Pid, erlang:process_info(Pid)}}
    end.

%% Sometimes the previous clean up didn't work, so we try again
cleanup_previous_runs() ->
    RegNames = [webmachine_sup, webmachine_router, webmachine_logger,
                webmachine_log_event, webmachine_logger_watcher_sup],
    [wait_for_pid(RegName) || RegName <- RegNames].


%%
%% EXAMPLE TEST CASE
%%
%% init and service_available are simple resource functions for a service that
%% is unavailable (a 503 error)
init([]) ->
    {ok, undefined}.

service_available(ReqData, Context) ->
    {false, ReqData, Context}.

integration_tests() ->
    [fun service_unavailable_test/1].

integration_test_() ->
    {foreach,
     %% Setup
     fun() ->
             DL = [{[atom_to_list(?MODULE), '*'], ?MODULE, []}],
             Ctx = wm_integration_test_util:start(?MODULE, "0.0.0.0", DL),
             Ctx
     end,
     %% Cleanup
     fun(Ctx) ->
             wm_integration_test_util:stop(Ctx)
     end,
     %% Test functions provided with context from setup
     [fun(Ctx) ->
              {spawn, {with, Ctx, integration_tests()}}
      end]}.

service_unavailable_test(Ctx) ->
    URL = wm_integration_test_util:url(Ctx, "foo"),
    {ok, Result} = httpc:request(head, {URL, []}, [], []),
    ?assertMatch({{"HTTP/1.1", 503, "Service Unavailable"}, _, []}, Result),
    ok.

-endif.
