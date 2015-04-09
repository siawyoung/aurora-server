-module(chat_server).

-export([start/1, pre_connected_loop/1]).
-export([install/1]).
% -export([status_reply/2, status_reply/3, status_reply/4]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user}).
-record(aurora_message_backlog, {phone_number, messages}).
-record(aurora_chat_messages, {chatroom_id, from_phone_number, timestamp, message, chat_message_id}).

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
                         {type, set}]),
    mnesia:create_table(aurora_chatrooms,
                        [{attributes, record_info(fields, aurora_chatrooms)},
                         {disc_copies, Nodes},
                         {type, set}]),
    mnesia:create_table(aurora_message_backlog,
                        [{attributes, record_info(fields, aurora_message_backlog)},
                         {disc_copies, Nodes},
                         {type, set}]),
    mnesia:create_table(aurora_chat_messages,
                        [{attributes, record_info(fields, aurora_chat_messages)},
                         {disc_copies, Nodes},
                         {type, bag}]).

pre_connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->

            case validation:validate_and_parse_auth(Socket, Data) of

                invalid_auth_message -> pre_connected_loop(Socket);

                ParsedJson ->
                    Status = gen_server:call(controller, {register, ParsedJson, Socket}),
                    case Status of
                        ok    -> connected_loop(Socket);
                        error -> pre_connected_loop(Socket)
                    end
            end;

        {error, closed} ->
            ok
    end.

connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->

            case validation:validate_and_parse_request(Data) of

                invalid_json ->
                    % status_reply(Socket, 0),
                    messaging:send_status(Socket, 0),
                    connected_loop(Socket);

                missing_fields ->
                    messaging:send_status(Socket, 2),
                    connected_loop(Socket);

                {missing_fields, MessageType} ->
                    messaging:send_status(Socket, 2, MessageType),
                    connected_loop(Socket);

                wrong_message_type ->
                    messaging:send_status(Socket, 6),
                    connected_loop(Socket);

                %% whatever type of message it was, it has been checked for correctness of payload so we can proceed safely from here onwards
                %% We also convert lists to the correct format
                ParsedJson ->

                    AuthorizedStatus = call_authorize_request(ParsedJson),
                    MessageType = maps:get(type, ParsedJson),
                    PhoneNumber = maps:get(from_phone_number, ParsedJson),

                    if 
                        AuthorizedStatus =/= authorized ->
                            
                            %% Session tokens don't match
                            messaging:send_status_queue(Socket, PhoneNumber, 4, MessageType),
                            connected_loop(Socket);

                        true ->

                            % we update the socket upon auth, but in case it changes
                            % we update the socket in every message, after successful authorization
                            % TODO: after updating, send all backdated messages to this socket
                            cast_update_socket(ParsedJson, Socket),
                        
                            case MessageType of

                                <<"TEXT">> ->
                                    io:format("TEXT MESSAGE SENT~n",[]),
                                    gen_server:cast(controller, {send_chat_message, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"CREATE_ROOM">> ->
                                    io:format("CREATE_ROOM MESSAGE SENT~n",[]),
                                    gen_server:cast(controller, {create_chatroom, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"ROOM_INVITATION">> ->
                                    io:format("ROOM INVITATION MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {room_invitation, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"LEAVE_ROOM">> ->
                                    io:format("LEAVE ROOM MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {leave_room, ParsedJson, Socket}),
                                    connected_loop(Socket)
                            end

                    end

            end;

        {error, closed} ->
            ok

    end.

% status_reply(Socket, Status) ->
%     io:format("Status sent: ~p~n", [Status]),
%     gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status})).

% status_reply(Socket, Status, Type) ->
%     io:format("Status sent: ~p~n", [Status]),
%     gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type})).

% status_reply(Socket, Status, Type, Message) ->
%     io:format("Status sent: ~p~n", [Status]),
%     gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type, <<"message">> => Message})).

cast_update_socket(ParsedJson, Socket) ->
    gen_server:cast(controller, {update_socket, ParsedJson, Socket}).

call_authorize_request(ParsedJson) ->
    Status = gen_server:call(controller, {authorize_request, ParsedJson}),
    io:format("Message from authorize_request method: ~p~n", [Status]),
    case Status of
        authorized   -> authorized;
        no_such_user -> no_such_user;
        _            -> error
    end.