-module(controller).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

-export([append_backlog/2]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user}).
-record(aurora_message_backlog, {phone_number, messages}).
-record(aurora_chat_messages, {chatroom_id, from_phone_number, message, chat_message_id}).
% -record(aurora_notes, {userID, message}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% This is called when a connection is made to the server
init([]) ->
    State = [],
    {ok, State}.

handle_call({register, ParsedJson, Socket}, _From, State) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    case user_exists(PhoneNumber) of

        user_exists ->
            
            Status = update_user(full_update, ParsedJson, Socket),
            case Status of
                % return value from update_user mnesia database transaction
                ok ->
                    messaging:send_status_queue(Socket, PhoneNumber, 1, <<"AUTH">>),
                    send_backlog(ParsedJson, Socket),
                    {reply, ok, State};
                _ ->
                    messaging:send_status_queue(Socket, PhoneNumber, 3, <<"AUTH">>),
                    {reply, error, State}
            end;

        no_such_user ->
            Status = create_user(ParsedJson, Socket),
            case Status of
                ok ->
                    messaging:send_status_queue(Socket, PhoneNumber, 1, <<"AUTH">>),
                    {reply, ok, State};
                _ ->
                    messaging:send_status_queue(Socket, PhoneNumber, 3, <<"AUTH">>),
                    {reply, error, State}
            end
    end;
    

handle_call({authorize_request, ParsedJson}, _From, State) ->

    TokenToCheck = maps:get(session_token, ParsedJson),
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    case find_user(PhoneNumber) of
        #{username     := _UserName, 
        session_token  := SessionToken, 
        rooms          := _Rooms, 
        current_ip     := _IPaddress, 
        active_socket  := _Socket} ->

            case SessionToken == TokenToCheck of
                true ->
                    {reply, authorized, State};
                false ->
                    {reply, error, State}

            end;

        _ ->
            {reply, no_such_user, State}

    end.

handle_cast({send_chat_message, ParsedJson, FromSocket}, State) ->

    ChatRoomId = maps:get(chatroom_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),

    RoomInfo = find_chatroom(ChatRoomId),
    case RoomInfo of

        no_such_room -> 

            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"CREATE_ROOM">>, <<"No such room.">>);

        _ ->
    
            UserNumbersFound = maps:get(room_users, RoomInfo),

            % write the message to the database
            % note that this chat message is not the same as the message backlog queue system
            case create_chat_message(ParsedJson) of

                {ok, chat_message_created, ChatMessageID} ->

                    F = fun(UserNumber) ->
                        User = find_user(UserNumber),
                        send_chat_message(User, ParsedJson, ChatMessageID, FromSocket)
                    end,

                    lists:foreach(F, UserNumbersFound);

                chat_message_error ->
                    error

            end
    end,
    
    {noreply, State};

% update_socket shouldn't respond, even if it fails

handle_cast({update_socket, ParsedJson, SocketToUpdate}, State) ->

    update_user(socket, ParsedJson, SocketToUpdate),
    send_backlog(ParsedJson, SocketToUpdate),
    {noreply, State};

handle_cast({create_chatroom, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    RawUsers = maps:get(users, ParsedJson),

    ValidateResult = validate_users(RawUsers),

    case ValidateResult of

        {ok, users_validated, UserInfo} ->
    
            DatabaseResult = create_chatroom(ParsedJson),
            case DatabaseResult of
                {ok, room_created, ChatRoomId, ChatRoomName, Users} ->

                    % no need to abtract out yet??
                    messaging:send_message(FromSocket, FromPhoneNumber, 
                    jsx:encode(#{
                        <<"status">>        => 1,
                        <<"chatroom_id">>   => ChatRoomId,
                        <<"type">>          => <<"CREATE_ROOM">>
                    })),

                    % send status to all users
                    F = fun(User) ->
                        send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, maps:get(active_socket, User), maps:get(phone_number, User))
                    end,
                    lists:foreach(F, UserInfo);

                error ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_ROOM">>, <<"Database transaction error">>)
            end;

        error ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"CREATE_ROOM">>, <<"Some users are invalid">>)
    end,

    {noreply, State};

handle_cast({room_invitation, ParsedJson, FromSocket}, State) ->
    
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ToPhoneNumber = maps:get(to_phone_number, ParsedJson),
    ChatRoomId = maps:get(chatroom_id, ParsedJson),


    User = find_user(ToPhoneNumber),
    Room = find_chatroom(ChatRoomId),

    if
        User == no_such_user ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"No such user">>);
        Room == no_such_room ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"No such room">>);
        true ->

            case check_if_user_admin(FromPhoneNumber, ChatRoomId) of

                user_is_admin ->
                    ChatRoomName = maps:get(chatroom_name, Room),
                    UpdatedUsers = add_user_to_room(Room, ToPhoneNumber),
                    send_chatroom_invitation(ChatRoomId, ChatRoomName, UpdatedUsers, maps:get(active_socket, User), maps:get(phone_number, User)),
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"ROOM_INVITATION">>, <<"User invited successfully">>);
                user_not_admin ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 8, <<"ROOM_INVITATION">>, <<"User is not admin of the room">>)
            end
    end,

    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%
%%% Main functions
%%%%%%%%%%%%%%%%%%%%%

send_chat_message(UserFound, ParsedJson, MessageID, FromSocket) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    ChatRoomId      = maps:get(chatroom_id, ParsedJson),

    ToSocket      = maps:get(active_socket, UserFound),
    ToPhoneNumber = maps:get(phone_number, UserFound),

    Status = messaging:send_message(ToSocket, ToPhoneNumber,
        jsx:encode(#{
        <<"message_id">>        => MessageID,
        <<"from_phone_number">> => FromPhoneNumber,
        <<"chatroom_id">>       => ChatRoomId,
        <<"message">>           => Message,
        <<"type">>              => <<"TEXT_RECEIVED">>
        })),

    case Status of
        ok ->
            % message sent successfully
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"TEXT">>, maps:get(phone_number, UserFound));
        error ->
            % socket closed
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 7, <<"TEXT">>, maps:get(phone_number, UserFound))
    end.


send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, Socket, PhoneNumber) ->

    messaging:send_message(Socket, PhoneNumber,
        jsx:encode(#{
            <<"chatroom_id">>   => ChatRoomId,
            <<"chatroom_name">> => ChatRoomName,
            <<"users">>         => Users,
            <<"type">>          => <<"ROOM_INVITATION">>
        })),
    add_room_to_user(ChatRoomId, PhoneNumber).

add_room_to_user(ChatRoomId, PhoneNumber) ->
    User = find_user(PhoneNumber),
    Rooms = maps:get(rooms, User),
    case Rooms of
        undefined -> 
            update_user(rooms, PhoneNumber, [ChatRoomId]);

        ExistingRooms ->
            AppendedRooms = lists:append(ExistingRooms, [ChatRoomId]),
            update_user(rooms, PhoneNumber, AppendedRooms)
    end.

add_user_to_room(Room, PhoneNumber) ->
    AppendedUsers = lists:append(maps:get(room_users, Room), [PhoneNumber]),
    update_chatroom(add_user, maps:get(chatroom_id, Room), AppendedUsers).

validate_users(Users) ->
    
    F = fun(UserPhoneNumber) ->

        DatabaseResult = find_user(UserPhoneNumber),
        io:format("~p~p~n", [UserPhoneNumber, DatabaseResult]),
        case DatabaseResult of
            #{username     := _UserName, 
            session_token  := _SessionToken, 
            rooms          := _Rooms, 
            current_ip     := _IPaddress, 
            active_socket  := Socket} ->

                #{phone_number  => UserPhoneNumber,
                  active_socket => Socket};

            no_such_user -> no_such_user
        end
    end,

    UserSockets = lists:map(F, Users),
    io:format("validate_users debug message: ~p~n", [UserSockets]),

    case lists:member(no_such_user, UserSockets) of
        true ->
            error;
        false ->
            {ok, users_validated, UserSockets}
    end.

send_backlog(ParsedJson, Socket) ->

    PhoneNumber = maps:get(from_phone_number, ParsedJson),
    io:format("Sending backlog messages..~n",[]),
    LeftoverMessages = [],

    case find_backlog(PhoneNumber) of

        undefined ->
            io:format("There are no backlog messages.~n",[]),
            no_backlog_messages;

        no_such_user ->
            error;

        [] ->
            io:format("There are no backlog messages.~n",[]),
            no_backlog_messages;

        Messages ->

            F = fun(Message) ->
                io:format("Backlog message:~n~p~n",[Message]),
                Status = gen_tcp:send(Socket, Message),

                case Status of
                    ok ->
                        great;
                    _  ->
                        lists:append(LeftoverMessages, [Message])
                end

            end,

            lists:foreach(F, [Messages]),
            update_backlog(PhoneNumber, LeftoverMessages)


    end.

% send_client_message(Socket, PhoneNumber, Message) ->
%     Status = gen_tcp:send(Socket, Message),
%     case Status of
%         ok -> ok;
%         _  -> 
%             append_backlog(PhoneNumber, Message),
%             error
%     end.

check_if_user_admin(PhoneNumber, ChatRoomId) ->

    Room = find_chatroom(ChatRoomId),
    RoomAdmin = maps:get(admin_user, Room),

    case RoomAdmin == PhoneNumber of
        true -> user_is_admin;
        false -> user_not_admin
    end.

%%%%%%%%%%%%%%%%%%%%
%%% Mnesia interface
%%%%%%%%%%%%%%%%%%%%

user_exists(PhoneNumber) ->
    F = fun() ->
        case mnesia:read({aurora_users, PhoneNumber}) of
            [#aurora_users{}] ->
                user_exists;
            _ ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

find_user(PhoneNumber) ->
    F = fun() ->
        case mnesia:read({aurora_users, PhoneNumber}) of
            [#aurora_users{username      = UserName, 
                           session_token = SessionToken,
                           rooms         = Rooms,
                           current_ip    = IPaddress,
                           active_socket = Socket}] ->

                #{phone_number => PhoneNumber,
                username       => UserName, 
                session_token  => SessionToken, 
                rooms          => Rooms, 
                current_ip     => IPaddress, 
                active_socket  => Socket};
            _ ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

update_user(full_update, ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),

    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{username      = UserName, 
                                                session_token = SessionToken,
                                                current_ip    = IPaddress,
                                                active_socket = Socket},
        mnesia:write(UpdatedUser)
        
    end,
    mnesia:activity(transaction, F);

update_user(socket, ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),
    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{current_ip    = IPaddress,
                                                active_socket = Socket},
        mnesia:write(UpdatedUser)
        
    end,
    mnesia:activity(transaction, F);

update_user(rooms, PhoneNumber, Rooms) ->
    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{rooms = Rooms},
        mnesia:write(UpdatedUser)
    end,
    mnesia:activity(transaction, F).

create_user(ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),

    F = fun() ->
        mnesia:write(#aurora_users{phone_number = PhoneNumber, 
                                   username = UserName, 
                                   session_token = SessionToken,
                                   current_ip = IPaddress, 
                                   active_socket = Socket}),
        mnesia:write(#aurora_message_backlog{phone_number = PhoneNumber})
    end,
    mnesia:activity(transaction, F).

% delete_user(ParsedJson) ->
%     PhoneNumber  = maps:get(from_phone_number, ParsedJson),

%     F = fun() ->
%         mnesia:delete(aurora_users, PhoneNumber)
%     end,
%     mnesia:activity(transaction, F).

create_chatroom(ParsedJson) ->

    AdminUser    = maps:get(from_phone_number, ParsedJson),
    ChatRoomName = maps:get(chatroom_name, ParsedJson),
    Users        = maps:get(users, ParsedJson),

    ChatRoomId   = timestamp_now(),

    F = fun() ->
        Status = mnesia:write(#aurora_chatrooms{chatroom_id   = ChatRoomId,
                                                admin_user    = AdminUser,
                                                chatroom_name = ChatRoomName,
                                                room_users    = Users}),
        case Status of
            ok -> {ok, room_created, ChatRoomId, ChatRoomName, Users};
            _  -> error
        end

    end,
    mnesia:activity(transaction, F).

find_chatroom(ChatRoomId) ->

    F = fun() ->
        case mnesia:read({aurora_chatrooms, ChatRoomId}) of
            [#aurora_chatrooms{chatroom_name = ChatRoomName,
                               room_users    = RoomUsers,
                               admin_user    = AdminUser}] ->

                #{chatroom_id   => ChatRoomId,
                  chatroom_name => ChatRoomName,
                  room_users    => RoomUsers,
                  admin_user    => AdminUser};

            _ ->
                no_such_room
        end
    end,
    mnesia:activity(transaction, F).

update_chatroom(add_user, ChatRoomId, Users) ->
    F = fun() ->
        [ExistingRoom] = mnesia:wread({aurora_chatrooms, ChatRoomId}),
        UpdatedRoom = ExistingRoom#aurora_chatrooms{room_users = Users},
        mnesia:write(UpdatedRoom)
    end,
    mnesia:activity(transaction, F).

find_backlog(PhoneNumber) ->
    
    F = fun() ->
        case mnesia:read({aurora_message_backlog, PhoneNumber}) of
            [#aurora_message_backlog{messages = Messages}] ->
                Messages;
            [] ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

update_backlog(PhoneNumber, Messages) ->

    F = fun() ->

        [ExistingUser] = mnesia:wread({aurora_message_backlog, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_message_backlog{messages = Messages},
        mnesia:write(UpdatedUser)

    end,
    mnesia:activity(transaction, F).

append_backlog(PhoneNumber, Message) ->

    Backlog = find_backlog(PhoneNumber),

    case Backlog of

        undefined ->  update_backlog(PhoneNumber, [Message]);
        no_such_user -> no_such_user;

        Messages ->

            AppendedMessages = lists:append(Messages, [Message]),
            update_backlog(PhoneNumber, AppendedMessages)

    end.

create_chat_message(ParsedJson) ->
    
    ChatRoomId = maps:get(chatroom_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message = maps:get(message, ParsedJson),
    ChatMessageID = timestamp_now(),

    F = fun() ->
        Status = mnesia:write(#aurora_chat_messages{chatroom_id       = ChatRoomId,
                                                    from_phone_number = FromPhoneNumber,
                                                    message           = Message,
                                                    chat_message_id   = ChatMessageID}),
        case Status of
            ok -> {ok, chat_message_created, ChatMessageID};
            _  -> chat_message_error
        end
    end,
    mnesia:activity(transaction, F).

% create_user_to_room(Name, RoomId)
% leave_room(Name, RoomId)
% delete_room(Name, RoomId) % to verify that he's indeed the admin of the room

%%%%%%%%%%%%%%%%%%%%%%%%
%%% Auxilliary functions
%%%%%%%%%%%%%%%%%%%%%%%%

% random_id_generator() -> 
%     <<I:160/integer>> = crypto:hash(sha,term_to_binary({make_ref(), now()})), 
%     erlang:integer_to_list(I, 16).

timestamp_now() ->
    list_to_binary(integer_to_list(timestamp(now()))).

timestamp({Mega, Secs, Micro}) ->
    Mega*1000*1000*1000*1000 + Secs*1000*1000 + Micro.

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.