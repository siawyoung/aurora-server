-module(chat_server).

-export([start/1, pre_connected_loop/1]).
-export([install/1]).
-export([status_reply/2, status_reply/3, status_reply/4]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user}).
-record(aurora_message_backlog, {phone_number, messages}).

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
                         {type, set}]).

pre_connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->
            % server stdout
            % Message = binary_to_list(Data),
            ParsedJson = jsx:decode(Data, [{labels, atom}, return_maps]),
            io:format("Message received by pre_connected_loop:~n~p~n",[ParsedJson]),
            % MessageType = get_message_type(Data),

            % case MessageType of

                % <<"AUTH">> ->

            case validate_auth_message(ParsedJson) of

                valid_auth_message ->

                    Status = register_user(ParsedJson, Socket),

                    case Status of
                        ok ->
                            status_reply(Socket, 1, <<"AUTH">>),
                            connected_loop(Socket);

                        error ->
                            status_reply(Socket, 3, <<"AUTH">>),
                            pre_connected_loop(Socket)
                    end;

                invalid_auth_message ->

                    status_reply(Socket, 2, <<"AUTH">>),
                    pre_connected_loop(Socket)

            end;

                % _ ->
                    % status_reply(Socket, 7)

            % end;

        {error, closed} ->
            ok
    end.



connected_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of

        {ok, Data} ->

            ParsedJson = jsx:decode(Data, [{labels, atom}, return_maps]),
            io:format("Message received by connected_loop:~n~p~n",[ParsedJson]),
            MessageType = get_message_type(ParsedJson),

            case validate_message(MessageType) of

                valid ->

                    AuthorizedStatus = call_authorize_request(ParsedJson),

                    if 
                        AuthorizedStatus =/= authorized ->
                            
                            %% Session tokens don't match
                            status_reply(Socket, 4),
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
                                    connected_loop(Socket)
                            end

                    end;

                not_valid ->
                    status_reply(Socket, 6),
                    connected_loop(Socket)

            end;

        {error, closed} ->
            ok

    end.

register_user(ParsedJson, Socket) ->
    Status = gen_server:call(controller, {register, ParsedJson, Socket}),
    io:format("Message sent by register_user method: ~p~n", [Status]),
    case Status of
        ok    -> ok;
        _     -> error
    end.

get_message_type(ParsedJson) ->
    maps:get(type, ParsedJson, missing_type).

status_reply(Socket, Status) ->
    io:format("Status sent: ~p~n", [Status]),
    % Message = 
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status})).

    % case Status of
    %     ok -> ok;
    %     error ->
    %         append_backlog(Status)
    % end.

status_reply(Socket, Status, Type) ->
    io:format("Status sent: ~p~n", [Status]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type})).

status_reply(Socket, Status, Type, Message) ->
    io:format("Status sent: ~p~n", [Status]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type, <<"message">> => Message})).

validate_auth_message(ParsedJson) ->
    Type         = maps:get(type, ParsedJson, missing_field),
    UserName     = maps:get(username, ParsedJson, missing_field),
    SessionToken = maps:get(session_token, ParsedJson, missing_field),
    PhoneNumber  = maps:get(from_phone_number, ParsedJson, missing_field),
    
    case ((Type =/= <<"AUTH">>) or (UserName == missing_field) or (SessionToken == missing_field) or (PhoneNumber == missing_field)) of
        true ->
            io:format("Message from validate_auth_message: Invalid auth message~n", []),
            invalid_auth_message;
        false ->
            io:format("Message from validate_auth_message: Valid auth message~n", []),
            valid_auth_message
    end.

validate_message(Type) ->
    case Type of
        <<"TEXT">>        -> valid;
        <<"CREATE_ROOM">> -> valid;
        _                 -> not_valid
    end.

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


% find(Name, Socket, NameToFind) ->
%     gen_server:cast(controller, {find, Socket, NameToFind}),
%     connected_loop(Name, Socket).

% talk(OwnName, Socket, PeerName, Message) ->
%     gen_server:cast(controller, {talk, OwnName, Socket, PeerName, Message}),
%     connected_loop(OwnName, Socket).

% clean(Data) ->
%     string:strip(Data, both, $\n).

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