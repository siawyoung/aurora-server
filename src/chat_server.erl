-module(chat_server).

-export([start/1, pre_connected_loop/1]).
-export([install/1]).
-include_lib("stdlib/include/qlc.hrl").

-record(aurora_users, {name, location, rooms = []}).
-record(aurora_rooms, {id, users = [], messages = []}).

start(Port) ->
    mnesia:wait_for_tables([aurora_users, aurora_rooms], 5000),
    controller:start(),
    tcp_server:start(?MODULE, Port, {?MODULE, pre_connected_loop}).

install(Nodes) ->
    ok = mnesia:create_schema(Nodes),
    rpc:multicall(Nodes, application, start, [mnesia]),
    mnesia:create_table(aurora_users,
                        [{attributes, record_info(fields, aurora_users)},
                         {index, [#aurora_users.location]},
                         {disc_copies, Nodes},
                         {type, set}]),
    mnesia:create_table(aurora_rooms,
                        [{attributes, record_info(fields, aurora_rooms)},
                         {disc_copies, Nodes},
                         {type, set}]).
    % rpc:multicall(Nodes, application, stop, [mnesia]).


% this function is run at the start, and looks for messages of the form
% CONNECT:______
% if doesn't it just sends Unknown command and quits
% Shouldn't be an issue, since the server is going to be interfaced by the app anyway, the app can prepend the TCP message with CONNECT: before attempting to connect

pre_connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            io:format("Data: ~p~n", [binary_to_list(Data)]),
            Message = binary_to_list(Data),
            {Command, [_|Nick]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Message),
            io:format("Nick: ~p~n", [Nick]),
            case Command of
                "CONNECT" ->
                    try_connection(clean(Nick), Socket);
                _ ->
                    gen_tcp:send(Socket, "Unknown command!\n"),
                    pre_connected_loop(Socket)
            end;
        {error, closed} ->
            ok
    end.

try_connection(Nick, Socket) ->
    Response = gen_server:call(controller, {connect, Nick, Socket}),
    case Response of
        {ok, UserType, List} ->

            case UserType of
                new_user ->
                    gen_tcp:send(Socket, "You are connected as " ++ Nick ++ ".\nThe other users in the room are " ++ List ++ "\n");
                existing_user ->
                    gen_tcp:send(Socket, "Welcome back, " ++ Nick ++ ".\nThe other users in the room are " ++ List ++ "\n")
            end,

            gen_server:cast(controller, {join, Nick}),
            connected_loop(Nick, Socket);

        % if the response isn't what we want, we keep looping
        _ ->
            gen_tcp:send(Socket, "Connection Error. Please try again!\n"),
            pre_connected_loop(Socket)
    end.

connected_loop(Nick, Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->
            
            % server log (should replace with a better logging system)
            Message = binary_to_list(Data),
            io:format("Data: ~p~n", [Message]),

            {Command, [_|Content]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Message),
            case Command of
                "SAY" ->
                    say(Nick, Socket, clean(Content));

                "PVT" ->
                    {ReceiverNick, [_|Msg]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Content),
                    private_message(Nick, Socket, ReceiverNick, clean(Msg));

                "QUIT" ->
                    quit(Nick, Socket);
                _ ->
                    connected_loop(Nick, Socket)
            end;

        {error, closed} ->
            ok

    end.

say(Nick, Socket, Content) ->
    gen_server:cast(controller, {say, Nick, Content}),
    connected_loop(Nick, Socket).

private_message(Nick, Socket, ReceiverNick, Msg) ->
     gen_server:cast(controller, {private_message, Nick, ReceiverNick, Msg}),
     connected_loop(Nick, Socket).

quit(Nick, Socket) ->
    Response = gen_server:call(controller, {disconnect, Nick}),
    case Response of
        ok ->
            gen_tcp:send(Socket, "Bye.\n"),
            gen_server:cast(controller, {left, Nick}),
            ok;
        user_not_found ->
            gen_tcp:send(Socket, "Bye with errors.\n"),
            ok
    end.

clean(Data) ->
    string:strip(Data, both, $\n).
