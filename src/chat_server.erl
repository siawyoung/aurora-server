-module(chat_server).

-export([start/1, pre_connected_loop/1]).
-export([install/1]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user, expiry, group}).
-record(aurora_message_backlog, {phone_number, messages}).
-record(aurora_chat_messages, {chat_message_id, chatroom_id, from_phone_number, timestamp, message, tags}).
-record(aurora_events, {event_id, chatroom_id, event_name, event_datetime, votes}).
-record(aurora_notes, {note_id, chatroom_id, note_title, note_text, from_phone_number}).

start(Port) ->
    mnesia:wait_for_tables([aurora_users, aurora_chatrooms, aurora_message_backlog, aurora_chat_messages, aurora_events, aurora_notes], 5000),
    controller:start(),
    tcp_server:start(?MODULE, Port, {?MODULE, pre_connected_loop}).

% This function creates a new local Mnesia database with the following tables
% {type, set} - the records are of type "set", meaning that all records must be unique
% this helps to improve search performance drastically
% {disc_copies, Nodes} - Write operations to a table replica of type disc_copies will write data to the disc copy as well as to the RAM copy of the table
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
                         {type, set}]),
    mnesia:create_table(aurora_events,
                        [{attributes, record_info(fields, aurora_events)},
                         {disc_copies, Nodes},
                         {type, set}]),
    mnesia:create_table(aurora_notes,
                        [{attributes, record_info(fields, aurora_notes)},
                         {disc_copies, Nodes},
                         {type, set}]).


%% validation
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
                %% all of the fields have been checked to be present
                %% So we can avoid having to write our code in a more cumbersome manner
                %% to handle missing fields
                ParsedJson ->

                    AuthorizedStatus = call_authorize_request(ParsedJson),
                    MessageType = maps:get(type, ParsedJson),
                    PhoneNumber = maps:get(from_phone_number, ParsedJson),

                    if 
                        % AuthorizedStatus =/= authorized ->
                            
                        %     %% Session tokens don't match
                        %     messaging:send_status_queue(Socket, PhoneNumber, 4, MessageType),
                        %     connected_loop(Socket);

                        true ->

                            % we update the socket upon auth, but in case it changes
                            % we update the socket in every message, after successful authorization
                            cast_update_socket(ParsedJson, Socket),
                        
                            case MessageType of

                                <<"TEXT">> ->
                                    io:format("TEXT MESSAGE SENT~n",[]), % server console logging for debugging
                                    gen_server:cast(controller, {send_chat_message, ParsedJson, Socket}),
                                    connected_loop(Socket); % after the asynchronous cast is sent, continue looping

                                <<"GET_USERS">> ->
                                    io:format("GET USERS MESSAGE SENT~n",[]),
                                    gen_server:cast(controller, {get_users, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"CREATE_SINGLE_ROOM">> ->
                                    io:format("CREATE_SINGLE_ROOM MESSAGE SENT~n",[]),
                                    gen_server:cast(controller, {create_single_chatroom, ParsedJson, Socket}),
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
                                    connected_loop(Socket);

                                <<"TRANSFER_ADMIN">> ->
                                    io:format("TRASNFER ADMIN MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {transfer_admin, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"GET_ROOMS">> ->
                                    io:format("GET ROOMS MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {get_rooms, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"CREATE_NOTE">> ->
                                    io:format("CREATE NOTE MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {create_note, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"GET_NOTES">> ->
                                    io:format("GET NOTES MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {get_notes, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"EDIT_NOTE">> ->
                                    io:format("EDIT NOTE MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {edit_note, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"DELETE_NOTE">> ->
                                    io:format("DELETE NOTE MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {delete_note, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"CREATE_EVENT">> ->
                                    io:format("CREATE EVENT MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {create_event, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"GET_EVENTS">> ->
                                    io:format("GET EVENTS MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {get_events, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"EVENT_VOTE">> ->
                                    io:format("EVENT VOTE MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {vote_event, ParsedJson, Socket}),
                                    connected_loop(Socket);

                                <<"EVENT_UNVOTE">> ->
                                    io:format("EVENT UNVOTE MESSAGE SENT~n", []),
                                    gen_server:cast(controller, {unvote_event, ParsedJson, Socket}),
                                    connected_loop(Socket)

                            end

                    end

            end;

        {error, closed} ->
            ok

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