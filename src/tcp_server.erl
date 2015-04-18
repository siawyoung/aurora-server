-module(tcp_server).

-behavior(gen_server).

-export([init/1, code_change/3, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([accept_loop/1]).
-export([start/3]).

% We define the options for the listening socket here
% binary - binary data only
% {packet, 0} - no buffering, all data is sent immediately as it is received
% {active, false} - the listening socket is set to passive mode
% {reuseaddr, true} - allow the socket to reuse the port
% {keepalive, true} - set the listening socket to keepalive
-define(TCP_OPTIONS, [binary, {packet, 0}, {active, false}, {reuseaddr, true}, {keepalive, true}]).

% the tcp_server state consists of:
% port - The port number (8091)
% loop - The module and the specific loop function that should be spawned and set to run. In this case, loop is set to {chat_server, pre_connected_loop}
% lsocket - the listening socket object
-record(server_state, {
        port,
        loop,
        lsocket=null}).

% this function is called when the main initialization function in chat_server.erl is called.
% We set the port number (8091) and the loop ({chat_server, pre_connected_loop}) into the state,
% then we start an instance of tcp_server with the state
start(Name, Port, Loop) ->
    State = #server_state{port = Port, loop = Loop},
    gen_server:start_link({local, Name}, ?MODULE, State, []).


% this init function is called whenever this module, tcp_server, is instantiated
% we call the gen_tcp:listen function with the port in the state and with the TCP options
% which returns us a socket object if successful. We then set the socket object into the state
% and call the accept function with the updated state (which now contains the socket object)
init(State = #server_state{port=Port}) ->
    case gen_tcp:listen(Port, ?TCP_OPTIONS) of
        {ok, LSocket} ->
            NewState = State#server_state{lsocket = LSocket},
            {ok, accept(NewState)};
        {error, Reason} ->
            {stop, Reason}
    end.

% In this accept function, we spawn a new process that runs the accept_loop function with the
% array of arguments
accept(State = #server_state{lsocket=LSocket, loop = Loop}) ->
    proc_lib:spawn(?MODULE, accept_loop, [{self(), LSocket, Loop}]),
    State.

% This is the main accept loop run by the spawned process. gen_tcp:accept is a blocking call,
% so this is where the process will wait for a new connection to come in
% once a new socket connection is received, we immediately call ourselves asynchronously with
% gen_server:cast to call the accept function so that we can spawn a new process
% then we pass the socket object returned by the gen_tcp:accept function into chat_server's pre_connected_loop
% function
accept_loop({Server, LSocket, {Module, LoopFunction}}) ->
    {ok, Socket} = gen_tcp:accept(LSocket), %% this is the part where it blocks
    gen_server:cast(Server, {accepted, self()}),
    Module:LoopFunction(Socket). %% Module here is chat_server, and LoopFunction is pre_connected_loop

% handle_cast accepts the self-asynchronous call to run the accept function so that
% a new process is spawned
handle_cast({accepted, _Pid}, State=#server_state{}) ->
    {noreply, accept(State)}.

% These are just here to suppress warnings.
handle_call(_Msg, _Caller, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.
