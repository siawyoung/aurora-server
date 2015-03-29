-module(chat_server).

-export([start/1, pre_connected_loop/1]).
-export([install/1]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).

start(Port) ->
    mnesia:wait_for_tables([aurora_users], 5000),
    controller:start(),
    tcp_server:start(?MODULE, Port, {?MODULE, pre_connected_loop}).

install(Nodes) ->
    ok = mnesia:create_schema(Nodes),
    rpc:multicall(Nodes, application, start, [mnesia]),
    mnesia:create_table(aurora_users,
                        [{attributes, record_info(fields, aurora_users)},
                         {disc_copies, Nodes},
                         {type, set}]).


% this function is run at the start, and looks for messages of the form
% CONNECT:______
% if doesn't it just sends Unknown command and quits
% Shouldn't be an issue, since the server is going to be interfaced by the app anyway, the app can prepend the TCP message with CONNECT: before attempting to connect

register_user(Data, Socket) ->
    Status = gen_server:call(controller, {register, Data, Socket}),
    io:format("~p~n", [Status]),
    case Status of
        ok    -> ok;
        _     -> error
    end.

pre_connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->
            % server stdout
            % Message = binary_to_list(Data),
            Haha = jsx:decode(Data, [{labels, atom}, return_maps]),
            io:format("~p~n",[Haha]),
            Blah = maps:get(username, Haha),
            io:format("~p~n",[Blah]),
            MessageType = getMessageType(Data),
            io:format("~p~n",[MessageType]),

            case MessageType of

                <<"AUTH">> ->
                    Status = register_user(Data, Socket),

                    case Status of
                        ok ->
                            status_reply(Socket, 1);
                            % connected_loop(Socket);
                        error ->
                            status_reply(Socket, 0),
                            pre_connected_loop(Socket)
                    end;

                _ ->
                    status_reply(Socket, 0),
                    pre_connected_loop(Socket)
                
            end;


            % io:format("Data: ~p~n", [Test]),
            % io:format("Thing: ~p~n", [maps:get(fromID,Test)]),
            % io:format("Thing: ~p~n", [maps:get(name,maps:get(type,Test))]),
            
            % Haha = jsx:encode(find_user("sy")),
            % Haha = jsx:encode(#{<<"name">> => list_to_binary(Qs), <<"location">> => "asdasd", <<"socket">> => "qdwd"}),

            % io:format("Data: ~p~n", [Haha]),

            % gen_tcp:send(Socket, Haha),

            % {Command, [_|Name]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Message),
            % io:format("Command: ~p~n", [Command]),
            % case Command of
            %     "CONNECT" ->
            %         try_connection(clean(Name), Socket);
            %     _ ->
            %         gen_tcp:send(Socket, "TCP_CONNECTION_ERROR: Unknown command.\n"),
            %         pre_connected_loop(Socket)
            % end;

        {error, closed} ->
            ok
    end.



connected_loop(Name, Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->
            
            % server stdout
            Message = binary_to_list(Data),
            % Test = jsx:decode(Data),
            % io:format("Data: ~p~n", [Test]),
            io:format("Data: ~p~n", [Message]),

            {Command, [_|Content]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Message),
            case Command of
                "FIND" ->
                    find(Name, Socket, clean(Content));

                "SAY" ->
                    {PeerName, [_|Text]} = lists:splitwith(fun(T) -> [T] =/= ":" end, Content),
                    io:format("~p, and message is ~p~n", [PeerName, Text]),
                    talk(Name, Socket, PeerName, clean(Text));

                "QUIT" ->
                    quit(Name, Socket);
                _ ->
                    connected_loop(Name, Socket)
            end;

        {error, closed} ->
            ok

    end.

find(Name, Socket, NameToFind) ->
    gen_server:cast(controller, {find, Socket, NameToFind}),
    connected_loop(Name, Socket).

talk(OwnName, Socket, PeerName, Message) ->
    gen_server:cast(controller, {talk, OwnName, Socket, PeerName, Message}),
    connected_loop(OwnName, Socket).


quit(Name, Socket) ->
    Response = gen_server:call(controller, {disconnect, Name}),
    case Response of
        ok ->
            gen_tcp:send(Socket, "TCP_CONNECTION_TERMINATED: Bye.\n"),
            gen_server:cast(controller, {left, Name}),
            ok;
        user_not_found ->
            gen_tcp:send(Socket, "TCP_CONNECTION_TERMINATED: Bye with errors.\n"),
            ok
    end.

clean(Data) ->
    string:strip(Data, both, $\n).

getMessageType(Data) ->
    maps:get(name, maps:get(type, jsx:decode(Data, [{labels, atom}, return_maps]))).



status_reply(Socket, Status) ->
    % Haha = jsx:encode(#{<<"status">> => Status}),
    % io:format("Data: ~p~n", [Haha]),
    % Haha = jsx:encode(#{<<"library">> => <<"jsx">>, <<"awesome">> => true}),
    % io:format("Data: ~p~n", [Haha]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status})).


% try_connection(Name, Socket) ->
%     Response = gen_server:call(controller, {connect, Name, Socket}),
%     case Response of
%         ok ->
%             gen_tcp:send(Socket, "TCP_CONNECTION_SUCCESS: You are now connected as " ++ Name ++ "\n"),
%             % gen_server:cast(controller, {join, Name}),
%             connected_loop(Name, Socket);

%         % if the response isn't what we want, we keep looping
%         _ ->
%             gen_tcp:send(Socket, "TCP_CONNECTION_ERROR: Internal service error.\n"),
%             ok
%     end.