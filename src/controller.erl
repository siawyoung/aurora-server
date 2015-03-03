-module(controller).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

-record(aurora_users, {name, location}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% This is called when a connection is made to the server
init([]) ->
    State = [],
    {ok, State}.

% handle_call is invoked in response to gen_server:call


% Handles calls with 'connect' atom
% if we can find an existing user, we assume that he's the correct person
% authentication should be handled at the interface
handle_call(Message, _From, State) ->

    case Message of
        {connect, Name, Socket} ->
            case add_user(Name, Socket) of
                ok ->
                    {reply, ok, State};
                _ ->
                    {reply, error, State}
            end;

        {disconnect, Name} ->
            {reply, ok, State};

        _ ->
            {reply, error, State}

    end.

handle_cast({find, Socket, NameToFind}, State) ->
    case find_user(NameToFind) of
        {Name, Location} ->
            FlattenLocation = lists:flatten(io_lib:format("~p", [Location])),
            gen_tcp:send(Socket, "USER_FOUND: " ++ Name ++ " " ++ FlattenLocation ++ "\n");
        no_such_user ->
            gen_tcp:send(Socket, "USER_NOT_FOUND: " ++ NameToFind)
    end,
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%
%%% Mnesia interface
%%%%%%%%%%%%%%%%%%%%

find_user(Name) ->
    F = fun() ->
        case mnesia:read({aurora_users, Name}) of
            [#aurora_users{location = Location}] ->
                {Name, Location};
            [] ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

add_user(Name, Socket) ->
    {ok, {IPaddress, Port}} = inet:peername(Socket),
    F = fun() ->
        mnesia:write(#aurora_users{name = Name, location = {IPaddress, Port}})
    end,
    mnesia:activity(transaction, F).

delete_user(Name) ->
    F = fun() ->
        mnesia:delete(aurora_users, Name)
    end,
    mnesia:activity(transaction, F).

% create_room(Name, RoomName) ->
    

% add_user_to_room(Name, RoomId)
% leave_room(Name, RoomId)
% delete_room(Name, RoomId) % to verify that he's indeed the admin of the room

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.